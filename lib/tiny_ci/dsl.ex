defmodule TinyCI.DSL do
  @moduledoc """
  Provides the macro-based DSL for defining TinyCI pipelines.

  Use `use TinyCI.DSL` in a module to gain access to the `stage/2`,
  `step/2`, `step/3`, `set/2`, `when_branch/1`, `when_env/1`, and
  `when_file_changed/1` macros. At compile
  time, a `__pipeline__/0` function is generated that returns the
  normalized list of `%TinyCI.Stage{}` structs.

  ## Example

      defmodule MyApp.Pipeline do
        use TinyCI.DSL

        stage :test, mode: :parallel do
          step :unit, cmd: "mix test"
          step :lint, cmd: "mix credo"
        end

        stage :deploy, when: when_branch("main") do
          step :prod, module: DeployStep do
            set :app, "my-app"
            set :strategy, :heroku
          end
        end
      end
  """

  defmacro __using__(_opts) do
    quote do
      import TinyCI.DSL
      Module.register_attribute(__MODULE__, :stages, accumulate: true)
      Module.register_attribute(__MODULE__, :on_success_hooks, accumulate: true)
      Module.register_attribute(__MODULE__, :on_failure_hooks, accumulate: true)
      Module.put_attribute(__MODULE__, :current_stage, nil)
      @before_compile TinyCI.DSL
    end
  end

  @doc """
  Defines a pipeline stage with the given `name` and options.

  ## Options

    * `:mode` — execution mode for the stage's steps, either `:serial` or
      `:parallel` (default: `:parallel`)
    * `:when` — a condition expression (e.g., `when_branch("main")`) that
      determines whether the stage runs at pipeline execution time

  ## Examples

      stage :test, mode: :parallel do
        step :unit, cmd: "mix test"
      end

      stage :deploy, mode: :serial, when: when_branch("main") do
        step :release, cmd: "make release"
      end
  """
  defmacro stage(name, opts \\ [], do: block) do
    {when_clause, rest_opts} = Keyword.pop(opts, :when)

    if when_clause do
      func_name = :"__stage_when_#{name}__"

      quote do
        def unquote(func_name)(var!(tiny_ci_ctx)), do: unquote(when_clause)

        @current_stage {unquote(name),
                        [{:when, &(__MODULE__.unquote(func_name) / 1)} | unquote(rest_opts)], []}

        unquote(block)
        @stages @current_stage
        @current_stage nil
      end
    else
      quote do
        @current_stage {unquote(name), unquote(opts), []}
        unquote(block)
        @stages @current_stage
        @current_stage nil
      end
    end
  end

  @doc """
  Defines a step within a stage.

  A step can be a shell command or a module-based step. Module steps
  accept an optional `do` block with `set/2` calls for configuration.

  ## Options

    * `:cmd` — a shell command string to execute
    * `:module` — a module implementing `execute/2` for custom step logic
    * `:env` — a map of environment variables for shell commands
    * `:mode` — step-level execution mode (`:inherit`, `:serial`, `:parallel`)
    * `:timeout` — maximum execution time in milliseconds; the step fails if exceeded
    * `:allow_failure` — when `true`, the step can fail without failing its stage
      (default: `false`)

  ## Examples

      step :test, cmd: "mix test"

      step :deploy, module: MyDeploy do
        set :app, "my-app"
        set :region, "us-east-1"
      end
  """
  defmacro step(name, opts \\ []) do
    step_with_block(name, opts, nil)
  end

  defmacro step(name, opts, do: block) do
    step_with_block(name, opts, block)
  end

  defp step_with_block(name, opts, nil) do
    quote do
      {stage_name, stage_opts, steps} = @current_stage
      step_opts = unquote(opts) |> Keyword.put(:name, unquote(name))
      @current_stage {stage_name, stage_opts, [step_opts | steps]}
    end
  end

  defp step_with_block(name, opts, block) do
    func_name = :"__step_config_#{name}__"
    collected_block = collect_block(block)

    quote do
      def unquote(func_name)(), do: unquote(collected_block)

      {stage_name, stage_opts, steps} = @current_stage

      step_opts =
        unquote(opts)
        |> Keyword.put(:name, unquote(name))
        |> Keyword.put(:config_block, &(__MODULE__.unquote(func_name) / 0))

      @current_stage {stage_name, stage_opts, [step_opts | steps]}
    end
  end

  @doc """
  Sets a key-value configuration pair inside a module step's `do` block.

  Use `set/2` to pass arbitrary configuration to module-based steps.
  The collected key-value pairs are available as a keyword list in the
  module's `execute/2` callback.

  ## Examples

      stage :deploy, mode: :serial do
        step :prod, module: MyDeploy do
          set :app, "my-app"
          set :strategy, :heroku
          set :region, "us-east-1"
        end
      end
  """
  defmacro set(key, value) do
    quote do: {unquote(key), unquote(value)}
  end

  @doc """
  Condition macro for use with `stage ... when:`.

  Checks whether the pipeline context's `:branch` matches the given name.
  The context is provided automatically by the executor at runtime.

  ## Examples

      stage :deploy, when: when_branch("main") do
        step :release, cmd: "make release"
      end
  """
  defmacro when_branch(branch_name) do
    quote do
      var!(tiny_ci_ctx).branch == unquote(branch_name)
    end
  end

  @doc """
  Condition macro for use with `stage ... when:`.

  Returns `true` when the given environment variable is set (non-nil)
  at the time the pipeline runs. The check is performed against the
  OS environment, not the pipeline context.

  ## Examples

      stage :deploy, when: when_env("CI") do
        step :release, cmd: "make release"
      end
  """
  defmacro when_env(var_name) do
    quote do
      System.get_env(unquote(var_name)) != nil
    end
  end

  @doc """
  Condition macro for use with `stage ... when:`.

  Returns `true` when any file changed since the last commit matches
  the given glob pattern. The list of changed files is read from the
  pipeline context's `:changed_files` key (populated automatically by
  `TinyCI.Context.build/0`).

  Supports `*` (single-directory wildcard) and `**` (recursive wildcard).

  ## Examples

      stage :test, when: when_file_changed("lib/**/*.ex") do
        step :unit, cmd: "mix test"
      end

      stage :docs, when: when_file_changed("*.md") do
        step :build_docs, cmd: "mix docs"
      end
  """
  defmacro when_file_changed(glob_pattern) do
    quote do
      TinyCI.Context.any_file_matches?(
        Map.get(var!(tiny_ci_ctx), :changed_files, []),
        unquote(glob_pattern)
      )
    end
  end

  @doc """
  Registers a hook to run when the pipeline succeeds.

  A hook can be a shell command (`:cmd`) or a module-based callback (`:module`)
  with an optional `do` block for `set/2` configuration. The name must be unique
  across all `on_success` hooks in the pipeline.

  ## Options

    * `:cmd`     — shell command to execute
    * `:module`  — module implementing `run(config, context)` callback
    * `:env`     — map of extra environment variables (shell hooks only)
    * `:timeout` — max execution time in ms (shell hooks only; default: 30 000)

  ## Examples

      on_success :notify, cmd: "curl -X POST https://hooks.slack.com/..."

      on_success :deploy_notify, module: MyNotifier do
        set :channel, "#deploys"
      end
  """
  defmacro on_success(name, opts) do
    register_hook(:on_success_hooks, name, opts, nil)
  end

  defmacro on_success(name, opts, do: block) do
    register_hook(:on_success_hooks, name, opts, block)
  end

  @doc """
  Registers a hook to run when the pipeline fails.

  A hook can be a shell command (`:cmd`) or a module-based callback (`:module`)
  with an optional `do` block for `set/2` configuration. The name must be unique
  across all `on_failure` hooks in the pipeline.

  ## Options

    * `:cmd`     — shell command to execute
    * `:module`  — module implementing `run(config, context)` callback
    * `:env`     — map of extra environment variables (shell hooks only)
    * `:timeout` — max execution time in ms (shell hooks only; default: 30 000)

  ## Examples

      on_failure :alert, cmd: "say 'build failed'"

      on_failure :pager, module: PagerDuty do
        set :severity, :critical
      end
  """
  defmacro on_failure(name, opts) do
    register_hook(:on_failure_hooks, name, opts, nil)
  end

  defmacro on_failure(name, opts, do: block) do
    register_hook(:on_failure_hooks, name, opts, block)
  end

  defp register_hook(attr, name, opts, nil) do
    quote do
      hook_opts = Keyword.put(unquote(opts), :name, unquote(name))
      Module.put_attribute(__MODULE__, unquote(attr), hook_opts)
    end
  end

  defp register_hook(attr, name, opts, block) do
    func_name = :"__hook_config_#{attr}_#{name}__"
    collected_block = collect_block(block)

    quote do
      def unquote(func_name)(), do: unquote(collected_block)

      hook_opts =
        unquote(opts)
        |> Keyword.put(:name, unquote(name))
        |> Keyword.put(:config_block, &(__MODULE__.unquote(func_name) / 0))

      Module.put_attribute(__MODULE__, unquote(attr), hook_opts)
    end
  end

  defp collect_block({:__block__, _meta, exprs}) do
    exprs
    |> Enum.reduce(quote(do: []), fn expr, acc ->
      quote do: [unquote(expr) | unquote(acc)]
    end)
    |> then(fn q -> quote(do: Enum.reverse(unquote(q))) end)
  end

  defp collect_block(single) do
    quote(do: [unquote(single)])
  end

  defmacro __before_compile__(env) do
    quote do
      @stages
      |> Enum.reverse()
      |> TinyCI.Validator.validate()
      |> case do
        :ok ->
          :ok

        {:error, errors} ->
          for msg <- errors do
            IO.warn(msg, Macro.Env.stacktrace(unquote(Macro.escape(env))))
          end
      end

      def __pipeline__ do
        @stages
        |> Enum.reverse()
        |> Enum.map(&TinyCI.Pipeline.normalize_stage/1)
      end

      def __hooks__ do
        %{
          on_success:
            @on_success_hooks
            |> Enum.reverse()
            |> Enum.map(&TinyCI.Pipeline.normalize_hook/1),
          on_failure:
            @on_failure_hooks
            |> Enum.reverse()
            |> Enum.map(&TinyCI.Pipeline.normalize_hook/1)
        }
      end
    end
  end
end
