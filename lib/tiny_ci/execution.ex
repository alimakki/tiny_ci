defmodule TinyCI.Execution do
  @moduledoc """
  The execution seam: *where a step runs*.

  Every pipeline process the runner starts — shell steps, shell hooks, and the
  sandbox launchers — goes through this module. (Internal helpers such as git and
  the cache still use `System.cmd/3` directly.) The executor does not know whether
  it is running on a laptop or a server; mode selects defaults and policy, never a
  separate code path (invariant I1 in `M1.5-00`).

  ## Trust

  A pipeline file is controlled by whoever can open a pull request, so it cannot
  declare itself trusted. Trust belongs to the invocation and is carried on the
  run context as `ctx.trust`:

    * `:local` mode defaults to `:trusted`;
    * `:server` mode defaults to `:untrusted`;
    * an explicit `trust:` on the context wins.

  A trusted run uses `TinyCI.Execution.Backend.Local` unless an explicit
  `backend:` is supplied. An untrusted run has no backend yet: M1.5-02 adds the
  container backend and the policy that selects it, so until then an untrusted
  run fails closed instead of silently falling back to the host.

  ## Sessions

  A backend is opened once per stage, per matrix combination, and per shell hook
  (`with_session/3`). The session is put on the executor's context and read by
  each step; `close/1` is always called from an `after` path.
  """

  alias TinyCI.Execution.{Backend, Command, Session, SessionSpec}
  alias TinyCI.Execution.Backend.Local

  defmodule Error do
    @moduledoc """
    Raised when a run has no permitted execution backend or a session cannot be
    opened.

    `:reason` carries the tagged cause for callers that need to distinguish an
    unavailable isolation backend from a backend-specific open failure.
    """

    defexception [:message, :reason]
  end

  @typedoc "The invocation's trust level."
  @type trust :: :trusted | :untrusted

  @doc """
  Maps the runner's mode to the default trust level for a new run.

  Mode changes policy, not plumbing: both values run through the same backend
  contract.

  ## Examples

      iex> TinyCI.Execution.trust_for_mode(:local)
      :trusted

      iex> TinyCI.Execution.trust_for_mode(:server)
      :untrusted
  """
  @spec trust_for_mode(atom()) :: trust()
  def trust_for_mode(:local), do: :trusted
  def trust_for_mode(:server), do: :untrusted

  def trust_for_mode(mode) do
    raise ArgumentError,
          "unknown tiny_ci mode #{inspect(mode)}: expected :local or :server"
  end

  @doc """
  Returns the default trust for a run started in this VM.

  Reads `config :tiny_ci, :mode` (default `:local`). Entrypoints set an explicit
  `trust:` on the context when they know better, e.g. a pull request from a fork.
  """
  @spec default_trust() :: trust()
  def default_trust do
    trust_for_mode(Application.get_env(:tiny_ci, :mode, :local))
  end

  @doc """
  Adds the default trust to a context that does not already carry one.

  ## Examples

      iex> TinyCI.Execution.put_default_trust(%{}).trust in [:trusted, :untrusted]
      true
  """
  @spec put_default_trust(map()) :: map()
  def put_default_trust(ctx), do: Map.put_new(ctx, :trust, default_trust())

  @doc """
  Returns a context's trust, defaulting to the current mode when absent.

  Raises `TinyCI.Execution.Error` for a value other than `:trusted` or
  `:untrusted`, so a typo cannot silently become a trusted run.
  """
  @spec trust(map()) :: trust()
  def trust(ctx) do
    case Map.get(ctx, :trust) do
      nil ->
        default_trust()

      :trusted ->
        :trusted

      :untrusted ->
        :untrusted

      other ->
        raise Error,
          message: "invalid trust level #{inspect(other)}: expected :trusted or :untrusted",
          reason: {:invalid_trust, other}
    end
  end

  @doc """
  Selects the backend for a run.

  An explicit `:backend` option wins (it is how tests inject a backend and how a
  future policy can pass its choice through). Otherwise a trusted run gets the
  host (`Backend.Local`) and an untrusted run is refused until M1.5-02 provides
  the container backend.

  ## Examples

      iex> {:ok, TinyCI.Execution.Backend.Local} = TinyCI.Execution.resolve_backend(%{trust: :trusted})
      iex> TinyCI.Execution.resolve_backend(%{trust: :untrusted})
      {:error, {:isolation_unavailable, :untrusted}}
  """
  @spec resolve_backend(map(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve_backend(ctx, opts \\ []) do
    case Keyword.fetch(opts, :backend) do
      {:ok, Local} ->
        if trust(ctx) == :trusted,
          do: {:ok, Local},
          else: {:error, {:isolation_unavailable, :untrusted}}

      {:ok, backend} ->
        {:ok, backend}

      :error ->
        case trust(ctx) do
          :trusted -> {:ok, Local}
          :untrusted -> {:error, {:isolation_unavailable, :untrusted}}
        end
    end
  end

  @doc """
  Ensures a context carries a resolved backend, raising when none is permitted.

  Used by the standalone `TinyCI.Executor.execute/4` entrypoint, which has no
  run-level error tuple to return.
  """
  @spec ensure_backend!(map(), keyword()) :: map()
  def ensure_backend!(ctx, opts \\ []) do
    opts =
      case {Keyword.fetch(opts, :backend), Map.get(ctx, :execution_backend)} do
        {{:ok, _explicit}, _stored} -> opts
        {:error, nil} -> []
        {:error, stored} -> [backend: stored]
      end

    case resolve_backend(ctx, opts) do
      {:ok, backend} ->
        Map.put(ctx, :execution_backend, backend)

      {:error, reason} ->
        raise Error, message: error_message(reason), reason: reason
    end
  end

  @doc """
  Returns the run's backend, resolving and validating it when necessary.

  An explicit `:backend` option wins. Otherwise a previously stored backend is
  re-checked against the current trust level, so a context that carries Local
  cannot smuggle an untrusted run onto the host. Raises
  `TinyCI.Execution.Error` when no permitted backend exists.

  Callers that start stages, matrix combinations, or hooks use this rather than
  reading `:execution_backend` directly.
  """
  @spec backend(map(), keyword()) :: module()
  def backend(ctx, opts \\ []) do
    ctx |> ensure_backend!(opts) |> Map.fetch!(:execution_backend)
  end

  @doc """
  Builds the session spec for a run: the project root and the run id.

  A step's own working directory belongs on its `Command`, not here, because the
  container backend maps it under the workspace it mounts.
  """
  @spec session_spec(map()) :: SessionSpec.t()
  def session_spec(ctx) do
    %SessionSpec{
      workspace: Map.get(ctx, :root) || File.cwd!(),
      run_id: Map.get(ctx, :run_id)
    }
  end

  @doc """
  Opens a backend session, yields it, and closes it no matter how the block exits.

  `close/1` runs after a normal return, a raise, or an exit. An `open/1` error is
  raised as `TinyCI.Execution.Error`; nothing is closed because nothing opened.

  ## Options

    * `:backend` — the backend module (default `Backend.Local`)
  """
  @spec with_session(SessionSpec.t(), (Session.t() -> any()), keyword()) :: any()
  def with_session(%SessionSpec{} = spec, fun, opts \\ []) when is_function(fun, 1) do
    backend = Keyword.get(opts, :backend, Local)

    case backend.open(spec) do
      {:ok, ref} ->
        session = %Session{backend: backend, ref: ref, spec: spec}

        try do
          fun.(session)
        after
          backend.close(ref)
        end

      {:error, reason} ->
        tagged = {:session_open_failed, backend, reason}

        raise Error,
          message: error_message(tagged),
          reason: tagged
    end
  end

  @doc """
  Runs a command in an open session through its backend.

  `on_line` receives every complete output line exactly as the process produced
  it. Redaction and rendering happen above this boundary.
  """
  @spec exec(Session.t(), Command.t(), (String.t() -> any())) :: Backend.outcome()
  def exec(%Session{backend: backend, ref: ref}, %Command{} = command, on_line)
      when is_function(on_line, 1) do
    backend.exec(ref, command, on_line)
  end

  defp error_message({:isolation_unavailable, :untrusted}) do
    "refusing to run an untrusted pipeline on the host: " <>
      "no isolation backend is available (the container backend lands in M1.5-02)"
  end

  defp error_message({:session_open_failed, backend, reason}) do
    "could not open an execution session with #{inspect(backend)}: #{inspect(reason)}"
  end
end
