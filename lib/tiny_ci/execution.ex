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

  A trusted run uses `TinyCI.Execution.Backend.Local` unless a `:backend` is
  supplied or an image selects `TinyCI.Execution.Backend.Container`. An untrusted
  run is never allowed to fall back to the host: `TinyCI.Execution.Policy` selects
  the container backend (using the operator's `:default_image` when the pipeline
  does not name one), and a run with no runtime or image fails closed.

  ## Sessions

  A backend is opened once per stage, per matrix combination, and per hook phase
  (`with_session/3`). The session is put on the executor's context and read by
  each step; `close/1` is always called from an `after` path.
  """

  alias TinyCI.Execution.{Backend, Command, Policy, Session, SessionSpec}
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
  Resolves the backend and image for a run.

  An explicit `:backend` option wins (it is how tests inject a backend). Local is
  refused for an untrusted context even when named explicitly. Otherwise the
  decision comes from `TinyCI.Execution.Policy`: trust and image select the
  backend, and an untrusted run never falls back to the host.

  ## Examples

      iex> {:ok, %{backend: TinyCI.Execution.Backend.Local}} =
      ...>   TinyCI.Execution.resolve(%{trust: :trusted})

      iex> TinyCI.Execution.resolve(%{trust: :untrusted}, default_image: nil)
      {:error, :no_default_image}
  """
  @spec resolve(map(), keyword()) :: {:ok, Policy.decision()} | {:error, term()}
  def resolve(ctx, opts \\ []) do
    image = Keyword.get(opts, :image) || Map.get(ctx, :image)

    case Keyword.fetch(opts, :backend) do
      {:ok, Local} ->
        resolve_local(ctx, image)

      {:ok, backend} ->
        {:ok,
         %{
           backend: backend,
           image: Keyword.get(opts, :image) || Map.get(ctx, :execution_image) || image
         }}

      :error ->
        policy_opts =
          opts
          |> Keyword.delete(:backend)
          |> Keyword.put_new(:default_image, Application.get_env(:tiny_ci, :default_image))

        Policy.resolve(ctx, image, policy_opts)
    end
  end

  # Local cannot honour an image; refusing it explicitly is what stops a caller
  # (or a stale stored backend) from silently running an imaged stage on the
  # host.
  defp resolve_local(ctx, image) do
    stored_image = Map.get(ctx, :execution_image)

    cond do
      is_binary(stored_image) and stored_image != "" ->
        {:error, {:image_requires_container, stored_image}}

      is_binary(image) and image != "" ->
        {:error, {:image_requires_container, image}}

      trust(ctx) == :trusted ->
        {:ok, %{backend: Local, image: image}}

      true ->
        {:error, {:isolation_unavailable, :untrusted}}
    end
  end

  @doc """
  Selects only the backend module for a run.

  A compatibility wrapper over `resolve/2`; callers that also need the chosen
  image should use `resolve/2`.

  ## Examples

      iex> {:ok, TinyCI.Execution.Backend.Local} = TinyCI.Execution.resolve_backend(%{trust: :trusted})
  """
  @spec resolve_backend(map(), keyword()) :: {:ok, module()} | {:error, term()}
  def resolve_backend(ctx, opts \\ []) do
    case resolve(ctx, opts) do
      {:ok, %{backend: backend}} -> {:ok, backend}
      {:error, _} = error -> error
    end
  end

  @doc """
  Ensures a context carries a resolved backend, raising when none is permitted.

  Used by the standalone `TinyCI.Executor.execute/4` entrypoint, which has no
  run-level error tuple to return. The resolved image is stored alongside the
  backend so sessions opened later use the same decision.
  """
  @spec ensure_backend!(map(), keyword()) :: map()
  def ensure_backend!(ctx, opts \\ []) do
    opts =
      case {Keyword.fetch(opts, :backend), Map.get(ctx, :execution_backend)} do
        {{:ok, _explicit}, _stored} -> opts
        {:error, nil} -> []
        {:error, stored} -> [backend: stored]
      end

    case resolve(ctx, opts) do
      {:ok, %{backend: backend, image: image}} ->
        ctx
        |> Map.put(:execution_backend, backend)
        |> Map.put(:execution_image, image)

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
  Builds the session spec for a run or one of its phases.

  `:workspace` is the project root. A step's own working directory belongs on
  its `Command`, not here, because the container backend maps it under the
  mounted workspace.

  ## Options

    * `:network` — whether the session may use the network (default `true`)
    * `:image` — an override; otherwise the run's resolved image is used
    * `:limits` — container limits; otherwise operator config
  """
  @spec session_spec(map(), keyword()) :: SessionSpec.t()
  def session_spec(ctx, opts \\ []) do
    %SessionSpec{
      workspace: Map.get(ctx, :root) || File.cwd!(),
      run_id: Map.get(ctx, :run_id),
      image: Keyword.get(opts, :image, Map.get(ctx, :execution_image) || Map.get(ctx, :image)),
      network: Keyword.get(opts, :network, true),
      limits: Keyword.get(opts, :limits, container_limits(ctx))
    }
  end

  defp container_limits(ctx) do
    Map.get(ctx, :container_limits) ||
      Application.get_env(:tiny_ci, :container_limits, %{})
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

  @doc """
  Returns the human-readable explanation for an execution error reason.

  The CLI and the Mix task use this so remediation text lives next to the code
  that produced the reason.
  """
  @spec error_message(term()) :: String.t()
  def error_message({:isolation_unavailable, :untrusted}) do
    "refusing to run an untrusted pipeline on the host: no isolation backend is available"
  end

  def error_message(:no_isolation_backend) do
    "no isolation backend is available (check `config :tiny_ci, :container_runtime`): " <>
      "install rootless Podman or Docker, or drop --isolate to run a trusted pipeline on the host"
  end

  def error_message(:no_default_image) do
    "an untrusted run needs a container image: set `config :tiny_ci, :default_image`, " <>
      "or drop --isolate for a trusted run"
  end

  def error_message({:image_requires_container, image}) do
    "the image #{inspect(image)} requires the container backend: " <>
      "the host backend cannot honour an image"
  end

  def error_message({:stage, name, reason}) do
    "stage :#{name} cannot run: #{error_message(reason)}"
  end

  def error_message({:hooks, reason}) do
    "pipeline hooks cannot run: #{error_message(reason)}"
  end

  def error_message({:conflicting_declaration, image, environment}) do
    "a stage cannot declare both image #{inspect(image)} and environment #{inspect(environment)}: " <>
      "an environment replaces the image, it does not layer on it"
  end

  def error_message({:invalid_image, image}) do
    "#{inspect(image)} is not a valid OCI image reference: " <>
      "it must be non-empty, must not start with \"-\", and must not contain whitespace"
  end

  def error_message({:image_unavailable, image, :missing_after_pull}) do
    "image #{inspect(image)} was pulled but is still not available locally"
  end

  def error_message({:image_unavailable, image, status, output}) do
    "could not pull image #{inspect(image)} (exit #{status}): #{String.trim(to_string(output))}"
  end

  def error_message(:no_toolchain_config) do
    "environment \"default\" needs a mise config (.mise.toml, mise.toml, or .tool-versions) " <>
      "in the project root"
  end

  def error_message({:unknown_environment, name, searched}) do
    "environment #{inspect(name)} has no mise config; looked for #{Enum.join(searched, ", ")} " <>
      "in the project root"
  end

  def error_message(:mise_unavailable) do
    "environment: needs `mise` on PATH to resolve a host toolchain; " <>
      "install mise, or declare an `image:` instead"
  end

  def error_message({:mise_failed, name, :timeout}) do
    "resolving environment #{inspect(name)} with mise timed out"
  end

  def error_message({:mise_failed, name, _reason}) do
    "resolving environment #{inspect(name)} with mise failed"
  end

  def error_message({:missing_tools, name, tools}) do
    missing = Enum.map_join(tools, ", ", fn {tool, version} -> "#{tool} #{version}" end)

    "environment #{inspect(name)} requests tools that mise has not installed: #{missing}. " <>
      "Run `mise install` in the project root."
  end

  def error_message({:environment_requires_image, name}) do
    "an untrusted run cannot use environment #{inspect(name)} on the host: " <>
      "map it to an image with `config :tiny_ci, :environments` or declare an `image:`"
  end

  def error_message({:invalid_environment, name}) do
    "#{inspect(name)} is not a valid environment name: use lowercase letters, digits, " <>
      "'.', '_' or '-', starting with a letter (max 64 characters)"
  end

  def error_message({:invalid_container_runtime, runtime}) do
    "invalid :container_runtime #{inspect(runtime)}: expected :auto, :docker, or :podman"
  end

  def error_message({:untrusted_actions, details}) do
    lines =
      Enum.map_join(details, "\n", fn detail ->
        location =
          case detail do
            %{stage: nil} -> "#{detail.kind} :#{detail.name}"
            %{stage: stage} -> "#{detail.kind} :#{detail.name} in stage :#{stage}"
          end

        "  - #{location} uses #{inspect(detail.module)} " <>
          "(#{detail.class}); only builtin actions may run in an untrusted run"
      end)

    "refusing to run repository module code in an untrusted run:\n" <>
      lines <>
      "\n  Replace the module step/hook with a `cmd:` block, or run a trusted invocation."
  end

  def error_message({:unsafe_pipeline_paths, details}) do
    lines =
      Enum.map_join(details, "\n", fn detail ->
        location =
          case detail.kind do
            :stage -> "stage :#{detail.stage}"
            kind -> "#{kind} :#{detail.name} in stage :#{detail.stage}"
          end

        "  - #{location} has a path outside the workspace: #{inspect(detail.path)}"
      end)

    "refusing to run an untrusted pipeline with paths outside the workspace:\n" <>
      lines <> "\n  Use a working_dir under the project root."
  end

  def error_message({:session_open_failed, backend, reason}) do
    "could not open an execution session with #{inspect(backend)}: #{inspect(reason)}"
  end

  def error_message(other), do: "execution error: #{inspect(other)}"
end
