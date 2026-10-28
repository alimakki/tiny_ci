defmodule TinyCI.Environment do
  @moduledoc """
  The execution environment a stage runs in.

  An environment is either a **container image** (`image:`) or a **host
  toolchain** (`environment:`). It is declared at pipeline or stage level and
  resolved once per run, before any step starts, so every session of a stage
  uses the same immutable identity.

  ## Precedence

  A stage's effective declaration is the first of:

    1. the stage's `image:`
    2. the stage's `environment:`
    3. the pipeline `image`
    4. the pipeline `environment`
    5. nothing declared

  A stage declaration is a **whole replacement**, not a merge: a stage with
  `environment: "ci"` under a pipeline `image:` runs on the host toolchain, not
  in the pipeline image.

  ## Defaults when nothing is declared

    * a trusted run stays on the host, even when the operator configured
      `:default_image` — zero-config local runs do not silently move into a
      container;
    * an untrusted run uses the operator's `:default_image`, and fails with
      `:no_default_image` when there is none;
    * an untrusted run with `environment:` maps the name through
      `config :tiny_ci, :environments` or fails with
      `{:environment_requires_image, name}`. It never falls back to the default
      image, because a host toolchain is not an isolation boundary.

  Hooks use the **pipeline** declaration only. Shell hooks with no pipeline
  declaration use the same trust-based default; module hooks need no session.

  ## Cache identity

  `cache_identity/1` is the part of an environment a cache key must include: the
  image digest (or ref when unresolved), the toolchain name, the toolchain
  fingerprint, and a stable hash of the resolved toolchain variables (a mise
  `[env]` value the step runs with must change the key). It is `nil` for a plain
  host run, so existing host cache keys do not change.
  """

  alias TinyCI.Environment.{Image, Mise}
  alias TinyCI.Execution
  alias TinyCI.Execution.Backend.{Container, Local}
  alias TinyCI.Stage

  @enforce_keys [:backend]
  defstruct image: nil,
            digest: nil,
            run_ref: nil,
            toolchain: nil,
            tools: [],
            env: %{},
            fingerprint: nil,
            backend: Local

  @typedoc """
  A resolved environment.

    * `:image` — the declared (or operator-mapped) reference, for display
    * `:digest` — the immutable identity used by the cache key
    * `:run_ref` — what the container backend starts (the image ID once
      resolved, otherwise the ref)
    * `:toolchain` — the `environment:` name (not the resolved variables)
    * `:env` — the resolved mise variables for a host toolchain
    * `:tools` — `[{name, version}]`, for the dry-run plan
    * `:fingerprint` — a stable hash of the resolved tool list
    * `:backend` — the selected backend module
  """
  @type t :: %__MODULE__{
          image: String.t() | nil,
          digest: String.t() | nil,
          run_ref: String.t() | nil,
          toolchain: String.t() | nil,
          tools: [{String.t(), String.t()}],
          env: %{optional(String.t()) => String.t()},
          fingerprint: String.t() | nil,
          backend: module()
        }

  @type entry :: {:ok, t()} | {:error, term()}
  @type plan :: %{run: entry() | nil, stages: %{atom() => entry()}}

  @env_name ~r/^[a-z][a-z0-9._-]{0,63}$/

  @doc """
  Returns `true` for a valid `environment:` name.

  ## Examples

      iex> TinyCI.Environment.valid_name?("ci")
      true

      iex> TinyCI.Environment.valid_name?("CI")
      false
  """
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@env_name, name)
  def valid_name?(_name), do: false

  @doc """
  Resolves one declaration.

  `declaration` is a map or keyword list with `:image` and/or `:environment`
  (exactly one of them should be set). Returns a `%TinyCI.Environment{}` or
  `{:error, reason}`.

  ## Options

    * `:backend` — the backend to select (test seam)
    * `:available?` — zero-arity container-runtime probe
    * `:digest` — an injected digest: a string, `:ref`, or a
      `ref -> {:ok, digest, run_ref} | digest | {:error, reason}` function
    * `:toolchain` — an injected toolchain: a map, or a `name -> {:ok, map}`
      function
    * `:default_image`, `:environments` — operator configuration
    * `:pull`, `:check_availability` — see `plan/3`
  """
  @spec resolve(map() | keyword(), map(), keyword()) :: t() | {:error, term()}
  def resolve(declaration, ctx, opts \\ []) do
    case resolve_entry(normalize_declaration(declaration), ctx, opts, %{}) do
      {{:ok, env}, _memo} -> env
      {{:error, _} = error, _memo} -> error
    end
  end

  @doc """
  Builds the environment plan for a run.

  Only runnable stages are planned: a stage excluded by `when:` is not resolved
  and cannot pull an image. Errors are collected per stage rather than
  short-circuiting, so a dry run can show every problem.

  ## Options

    * `:pipeline_image`, `:pipeline_environment` — the pipeline declaration
    * `:hooks` — the run's hooks map; shell hooks resolve the pipeline
      declaration and become the `:run` entry
    * `:backend` — the backend to select (test seam)
    * `:available?` — zero-arity container-runtime probe
    * `:digest` — an injected image digest resolver (see `resolve/3`)
    * `:toolchain` — an injected toolchain resolver (see `resolve/3`)
    * `:default_image` — the operator image for an untrusted run with no
      declaration
    * `:environments` — a `%{name => image}` map for untrusted `environment:`
    * `:pull` — pull missing images (default `true`; dry runs pass `false`)
    * `:check_availability` — require a container runtime when an image is
      needed (default `true`; dry runs pass `false`)

  ## Examples

      iex> stage = %TinyCI.Stage{name: :build, steps: []}
      iex> %{run: nil, stages: %{build: {:ok, %TinyCI.Environment{backend: TinyCI.Execution.Backend.Local}}}} =
      ...>   TinyCI.Environment.plan([stage], %{trust: :trusted}, [])
  """
  @spec plan([Stage.t()], map(), keyword()) :: plan()
  def plan(stages, ctx, opts \\ []) do
    {run, memo} = plan_run(ctx, opts, %{})

    {stage_plan, _memo} =
      Enum.reduce(stages, {%{}, memo}, fn stage, {acc, memo} ->
        if stage_skipped?(stage, stage_context(ctx, stage)) do
          {acc, memo}
        else
          {entry, memo} = resolve_entry(stage_declaration(stage, opts), ctx, opts, memo)
          {Map.put(acc, stage.name, entry), memo}
        end
      end)

    %{run: run, stages: stage_plan}
  end

  @doc """
  Resolves one stage's effective declaration outside a plan.

  Used when a stage becomes runnable after the plan was built — a `when:` that
  reads the store can flip after an earlier stage writes it. Stages that were
  planned keep their plan entry (and therefore one resolved digest per run).
  """
  @spec stage_environment(Stage.t(), map(), keyword()) :: entry()
  def stage_environment(stage, ctx, opts \\ []) do
    {entry, _memo} = resolve_entry(stage_declaration(stage, opts), ctx, opts, %{})
    entry
  end

  @doc """
  Returns the successful environments in a plan, or the first tagged error.

  Run-level errors are tagged `{:hooks, reason}` and stage errors
  `{:stage, name, reason}`, so the executor's error message can name what could
  not be resolved.
  """
  @spec strict(plan()) :: {:ok, %{run: t() | nil, stages: %{atom() => t()}}} | {:error, term()}
  def strict(plan) do
    with {:ok, run} <- strict_run(Map.get(plan, :run)),
         {:ok, stages} <- strict_stages(Map.get(plan, :stages, %{})) do
      {:ok, %{run: run, stages: stages}}
    end
  end

  @doc """
  Returns the cache-key identity of an environment, or `nil` for a plain host
  run.

  A host toolchain contributes a stable hash of its resolved environment as
  well as its tool fingerprint: a `[env]` value the step runs with must change
  the key.

  ## Examples

      iex> TinyCI.Environment.cache_identity(%TinyCI.Environment{backend: TinyCI.Execution.Backend.Local})
      nil

      iex> TinyCI.Environment.cache_identity(%TinyCI.Environment{backend: TinyCI.Execution.Backend.Container, image: "a", digest: "sha256:b"})
      %{image: "sha256:b", toolchain: nil, fingerprint: nil, env: nil}
  """
  @spec cache_identity(t() | nil) :: nil | map()
  def cache_identity(nil), do: nil

  def cache_identity(%__MODULE__{image: nil, toolchain: nil, fingerprint: nil}), do: nil

  def cache_identity(%__MODULE__{} = env) do
    %{
      image: env.digest || env.image,
      toolchain: env.toolchain,
      fingerprint: env.fingerprint,
      env: env_fingerprint(env.env)
    }
  end

  defp env_fingerprint(env) when map_size(env) == 0, do: nil

  defp env_fingerprint(env) do
    env
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.sort()
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Plan internals
  # ---------------------------------------------------------------------------

  defp plan_run(ctx, opts, memo) do
    if shell_hooks?(Keyword.get(opts, :hooks)) do
      declaration = %{
        image: Keyword.get(opts, :pipeline_image),
        environment: normalize_name(Keyword.get(opts, :pipeline_environment))
      }

      resolve_entry(declaration, ctx, opts, memo)
    else
      {nil, memo}
    end
  end

  defp shell_hooks?(hooks) when is_map(hooks) do
    hooks
    |> Map.values()
    |> List.flatten()
    |> Enum.any?(fn
      %TinyCI.Hook{cmd: cmd} -> not is_nil(cmd)
      _hook -> false
    end)
  end

  defp shell_hooks?(_hooks), do: false

  defp stage_context(ctx, stage) do
    case Map.get(stage, :env) do
      nil -> ctx
      env -> Map.put(ctx, :stage_env, env)
    end
  end

  # The executor's stage boundary is what reports a raising `when:` as a failed
  # stage. Planning runs first, so a condition that raises must not take the run
  # down here: treat it as runnable and let the boundary produce the failure.
  defp stage_skipped?(stage, ctx) do
    Stage.skipped?(stage, ctx)
  rescue
    _ -> false
  catch
    _kind, _reason -> false
  end

  defp stage_declaration(stage, opts) do
    cond do
      is_binary(stage.image) ->
        %{image: stage.image, environment: nil}

      is_binary(stage.environment) ->
        %{image: nil, environment: stage.environment}

      is_binary(Keyword.get(opts, :pipeline_image)) ->
        %{image: Keyword.get(opts, :pipeline_image), environment: nil}

      is_binary(Keyword.get(opts, :pipeline_environment)) ->
        %{image: nil, environment: Keyword.get(opts, :pipeline_environment)}

      true ->
        %{image: nil, environment: nil}
    end
  end

  defp resolve_entry(declaration, ctx, opts, memo) do
    key = {declaration.image, declaration.environment}

    case Map.fetch(memo, key) do
      {:ok, entry} ->
        {entry, memo}

      :error ->
        entry = do_resolve(declaration, ctx, opts)
        {entry, Map.put(memo, key, entry)}
    end
  end

  defp do_resolve(%{image: image, environment: environment}, _ctx, _opts)
       when not is_nil(image) and not is_nil(environment) do
    {:error, {:conflicting_declaration, image, environment}}
  end

  defp do_resolve(%{image: image, environment: nil}, ctx, opts) when is_binary(image) do
    resolve_image(image, Execution.trust(ctx), opts)
  end

  defp do_resolve(%{image: nil, environment: environment}, ctx, opts)
       when is_binary(environment) do
    resolve_environment(environment, Execution.trust(ctx), ctx, opts)
  end

  defp do_resolve(%{image: nil, environment: nil}, ctx, opts) do
    resolve_default(Execution.trust(ctx), opts)
  end

  defp resolve_default(:trusted, opts) do
    {:ok, %__MODULE__{backend: Keyword.get(opts, :backend) || Local}}
  end

  defp resolve_default(:untrusted, opts) do
    case default_image(opts) do
      nil ->
        case Keyword.get(opts, :backend) do
          nil -> {:error, :no_default_image}
          Local -> {:error, :no_default_image}
          backend -> {:ok, %__MODULE__{backend: backend}}
        end

      image ->
        resolve_image(image, :untrusted, opts)
    end
  end

  defp resolve_image(image, _trust, opts) do
    with :ok <- Image.validate_ref(image),
         {:ok, backend} <- container_backend(image, opts),
         {:ok, resolved} <- image_resolution(image, opts) do
      {:ok,
       %__MODULE__{
         backend: backend,
         image: image,
         digest: resolved.digest,
         run_ref: resolved.run_ref
       }}
    end
  end

  defp resolve_environment(name, :trusted, ctx, opts) do
    with :ok <- validate_environment_name(name),
         {:ok, toolchain} <- toolchain_resolution(name, ctx, opts) do
      {:ok,
       %__MODULE__{
         backend: Keyword.get(opts, :backend) || Local,
         toolchain: name,
         env: Map.get(toolchain, :env, %{}),
         tools: Map.get(toolchain, :tools, []),
         fingerprint: Map.get(toolchain, :fingerprint)
       }}
    end
  end

  defp resolve_environment(name, :untrusted, _ctx, opts) do
    with :ok <- validate_environment_name(name) do
      case environment_image(name, opts) do
        nil ->
          {:error, {:environment_requires_image, name}}

        image ->
          resolve_environment_image(image, name, opts)
      end
    end
  end

  defp resolve_environment_image(image, name, opts) do
    case resolve_image(image, :untrusted, opts) do
      {:ok, env} -> {:ok, %{env | toolchain: name}}
      {:error, _} = error -> error
    end
  end

  defp validate_environment_name(name) do
    if valid_name?(name), do: :ok, else: {:error, {:invalid_environment, name}}
  end

  defp container_backend(image, opts) do
    case Keyword.get(opts, :backend) do
      Local ->
        {:error, {:image_requires_container, image}}

      nil ->
        with :ok <- ensure_available(opts), do: {:ok, Container}

      backend ->
        with :ok <- ensure_available(opts), do: {:ok, backend}
    end
  end

  defp ensure_available(opts) do
    if check_availability?(opts) and not available?(opts),
      do: {:error, :no_isolation_backend},
      else: :ok
  end

  defp check_availability?(opts), do: Keyword.get(opts, :check_availability, true)

  defp available?(opts) do
    case Keyword.get(opts, :available?) do
      nil -> Container.available?()
      probe when is_function(probe, 0) -> probe.()
      value -> value
    end
  end

  defp image_resolution(image, opts) do
    case Keyword.get(opts, :digest) do
      nil ->
        Image.resolve(image, pull: Keyword.get(opts, :pull, true))

      :ref ->
        {:ok, %{digest: image, run_ref: image}}

      digest when is_binary(digest) ->
        {:ok, %{digest: digest, run_ref: image}}

      fun when is_function(fun, 1) ->
        injected_digest(fun.(image), image)
    end
  end

  defp injected_digest({:ok, digest, run_ref}, _image),
    do: {:ok, %{digest: digest, run_ref: run_ref}}

  defp injected_digest({:ok, digest}, image), do: {:ok, %{digest: digest, run_ref: image}}
  defp injected_digest({:error, _} = error, _image), do: error
  defp injected_digest(nil, image), do: {:ok, %{digest: nil, run_ref: image}}
  defp injected_digest(digest, image), do: {:ok, %{digest: digest, run_ref: image}}

  defp toolchain_resolution(name, ctx, opts) do
    case Keyword.get(opts, :toolchain) do
      nil ->
        Mise.resolve(name, root: Map.get(ctx, :root) || File.cwd!())

      fun when is_function(fun, 1) ->
        fun.(name)

      %{} = toolchain ->
        {:ok, toolchain}
    end
  end

  defp default_image(opts) do
    case Keyword.fetch(opts, :default_image) do
      {:ok, image} -> image
      :error -> Application.get_env(:tiny_ci, :default_image)
    end
  end

  defp environment_image(name, opts) do
    environments =
      case Keyword.fetch(opts, :environments) do
        {:ok, environments} -> environments
        :error -> Application.get_env(:tiny_ci, :environments, %{})
      end

    Map.get(environments || %{}, name)
  end

  defp strict_run(nil), do: {:ok, nil}
  defp strict_run({:ok, env}), do: {:ok, env}
  defp strict_run({:error, reason}), do: {:error, {:hooks, reason}}

  defp strict_stages(stages) do
    stages
    |> Enum.sort_by(fn {name, _entry} -> name end)
    |> Enum.reduce_while({:ok, %{}}, fn {name, entry}, {:ok, acc} ->
      case entry do
        {:ok, env} -> {:cont, {:ok, Map.put(acc, name, env)}}
        {:error, reason} -> {:halt, {:error, {:stage, name, reason}}}
      end
    end)
  end

  defp normalize_declaration(%{} = declaration) do
    %{
      image: Map.get(declaration, :image),
      environment: normalize_name(Map.get(declaration, :environment))
    }
  end

  defp normalize_declaration(declaration) when is_list(declaration) do
    %{
      image: Keyword.get(declaration, :image),
      environment: normalize_name(Keyword.get(declaration, :environment))
    }
  end

  defp normalize_declaration(nil), do: %{image: nil, environment: nil}

  defp normalize_name(nil), do: nil
  defp normalize_name(name) when is_atom(name), do: Atom.to_string(name)
  defp normalize_name(name) when is_binary(name), do: name
end
