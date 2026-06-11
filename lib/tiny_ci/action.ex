defmodule TinyCI.Action do
  @moduledoc """
  The contract every module-based pipeline step implements.

  An *action* is a module that does work for a `module:` step. Historically
  this was an informal convention — "a module that exports `execute/2`". This
  behaviour formalizes that convention into a typed, documented contract that
  the loader can verify before execution and that downstream features (the
  marketplace, lockfile resolution, sandboxing, provenance) build on.

  ## Implementing an action

      defmodule MyApp.Deploy do
        use TinyCI.Action

        @impl TinyCI.Action
        def execute(config, ctx) do
          IO.puts("Deploying \#{config[:app]} from \#{ctx.branch}")
          {:ok, %{deployed_at: DateTime.utc_now()}}
        end

        @impl TinyCI.Action
        def metadata do
          %TinyCI.Action.Metadata{
            name: "my_app.deploy",
            version: "1.0.0",
            capabilities: [:network]
          }
        end
      end

  ## Return semantics

  `c:execute/2` receives the step's `set/2` configuration as a keyword list and
  the pipeline `t:TinyCI.Context.t/0`. It must return one of:

    * `:ok` — the step passed; the pipeline store is unchanged.
    * `{:ok, map}` — the step passed; `map` is merged into the pipeline store
      and becomes visible to later steps and stages via `ctx.store`.
    * `{:error, reason}` — the step failed; the stage fails unless the step is
      marked `allow_failure: true`.

  ## Serializability

  The contract is *config in, result + store-delta out*. Keep it serializable
  in spirit: T8/T16 run actions inside a sandbox or on a remote node, so do not
  smuggle PIDs, file handles, or closures across the `execute/2` boundary.

  ## Back-compatibility (deprecated)

  Modules that export `execute/2` without `use TinyCI.Action` still run — they
  satisfy the contract by convention. This is **deprecated**: adopt the
  behaviour with `use TinyCI.Action` so the `@impl` annotations and the
  compiler verify your callbacks.
  """

  alias TinyCI.Action.Metadata
  alias TinyCI.{Hook, PipelineSpec, Stage, Step}

  @typedoc "The step's `set/2` configuration, passed to `c:execute/2`."
  @type config :: keyword()

  @typedoc "The result of running an action."
  @type result :: :ok | {:ok, map()} | {:error, term()}

  @doc """
  Runs the action with its configuration and the pipeline context.

  See the module documentation for the return semantics.
  """
  @callback execute(config(), TinyCI.Context.t()) :: result()

  @doc """
  Optionally declares the action's metadata (name, version, inputs, capabilities).
  """
  @callback metadata() :: Metadata.t()

  @optional_callbacks metadata: 0

  @doc false
  defmacro __using__(_opts) do
    quote do
      @behaviour TinyCI.Action
    end
  end

  @doc """
  Returns `true` if `module` is loadable and satisfies the action contract.

  Accepts both modules that `use TinyCI.Action` and legacy modules that merely
  export `execute/2` by convention.
  """
  @spec implements?(module()) :: boolean()
  def implements?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :execute, 2)
  end

  @doc """
  Returns `true` if `module` explicitly adopts `@behaviour TinyCI.Action`.

  This distinguishes modules that `use TinyCI.Action` from legacy convention
  modules — useful for nudging the latter toward the behaviour.
  """
  @spec behaviour_adopted?(module()) :: boolean()
  def behaviour_adopted?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and
      __MODULE__ in List.flatten(Keyword.get_values(module.__info__(:attributes), :behaviour))
  end

  @doc """
  Returns the module's declared `t:TinyCI.Action.Metadata.t/0`, or `nil`.

  `nil` is returned when the module is not loadable or does not implement the
  optional `c:metadata/0` callback.
  """
  @spec metadata(module()) :: Metadata.t() | nil
  def metadata(module) when is_atom(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :metadata, 0) do
      module.metadata()
    else
      nil
    end
  end

  @doc """
  Verifies that every `module:` target in a spec satisfies its contract.

  Step modules must implement `TinyCI.Action` (export `execute/2`); hook modules
  must export `run/2`. Failures are collected so the loader can report them all
  at once, **before** any step runs.

  ## Returns

    * `:ok` — all module targets are valid
    * `{:error, {:invalid_action, [String.t()]}}` — one message per invalid target
  """
  @spec validate_spec(PipelineSpec.t()) :: :ok | {:error, {:invalid_action, [String.t()]}}
  def validate_spec(%PipelineSpec{stages: stages, hooks: hooks}) do
    case stage_errors(stages) ++ hook_errors(hooks) do
      [] -> :ok
      errors -> {:error, {:invalid_action, errors}}
    end
  end

  defp stage_errors(stages) do
    for %Stage{name: stage_name, steps: steps} <- stages,
        %Step{module: module} = step <- steps,
        not is_nil(module),
        message = step_error(stage_name, step),
        message != nil do
      message
    end
  end

  defp step_error(stage_name, %Step{name: name, module: module}) do
    cond do
      not Code.ensure_loaded?(module) ->
        "Step :#{name} in stage :#{stage_name} refers to module " <>
          "#{inspect(module)}, which could not be loaded"

      not function_exported?(module, :execute, 2) ->
        "Step :#{name} in stage :#{stage_name} module #{inspect(module)} does not " <>
          "implement TinyCI.Action (missing execute/2)"

      true ->
        nil
    end
  end

  defp hook_errors(hooks) do
    hooks
    |> Map.values()
    |> List.flatten()
    |> Enum.filter(fn %Hook{module: module} -> not is_nil(module) end)
    |> Enum.map(&hook_error/1)
    |> Enum.reject(&is_nil/1)
  end

  defp hook_error(%Hook{name: name, module: module}) do
    cond do
      not Code.ensure_loaded?(module) ->
        "Hook :#{name} refers to module #{inspect(module)}, which could not be loaded"

      not function_exported?(module, :run, 2) ->
        "Hook :#{name} module #{inspect(module)} does not export run/2"

      true ->
        nil
    end
  end
end
