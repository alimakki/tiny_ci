defmodule TinyCI.Executor do
  @moduledoc """
  Executes pipeline stages and their steps, returning structured results.

  Supports serial and parallel execution modes, conditional stage
  execution via `when_condition`, and both shell command and module-based steps.

  A context map flows through the entire pipeline, carrying metadata such as
  the current git branch, commit SHA, and any user-supplied values. Stages
  can inspect the context in their `when_condition` functions, and module-based
  steps receive it as their second argument.

  A pipeline **store** (a key-value map) accumulates data across steps and
  stages. Module steps may return `{:ok, map}` to merge data into the store.
  Subsequent steps (in serial mode) and subsequent stages see the updated
  store via `context.store`. Shell steps access store values explicitly by
  using `store(:key)` references in the step's `env:` option.

  Step output is either streamed line-by-line to stdout during execution
  (in TTY environments) or buffered and printed after each stage completes
  (in non-TTY environments). The output mode is controlled via the `:output`
  option passed to `run_pipeline/3`.
  """

  alias TinyCI.{Output, Reporter, StageResult, StepResult}

  @doc """
  Starts the task supervisor used for parallel step execution.
  """
  def start_link(opts \\ []) do
    Task.Supervisor.start_link(opts)
  end

  @doc """
  Runs a full pipeline — a list of stages — in order.

  Stages are executed sequentially. If a stage fails (returns a failed result),
  the pipeline halts immediately and returns the failure along with all results
  collected so far. Skipped stages do not interrupt the pipeline.

  A pipeline store (`context.store`) accumulates data across stages. Module
  steps that return `{:ok, map}` merge their data into the store, making it
  available to later steps and stages.

  When no context is provided, one is automatically built from the current
  git environment via `TinyCI.Context.build/0`.

  ## Parameters

    * `stages`  — a list of `%TinyCI.Stage{}` structs
    * `context` — an optional map of pipeline metadata (branch, commit, etc.)
    * `opts`    — keyword options:
      * `:output` — output mode: `:streaming`, `:buffered`, or `:auto` (default `:auto`)

  ## Returns

    * `{:ok, [%StageResult{}]}` — when all stages succeed or are skipped
    * `{:error, {:stage_failed, stage_name, reason}, [%StageResult{}]}` — on first failure
  """
  def run_pipeline(stages, context \\ nil, opts \\ [])

  def run_pipeline(stages, context, opts) when is_list(stages) do
    ctx = context || TinyCI.Context.build()
    ctx = Map.put_new(ctx, :store, %{})
    output_mode = Output.resolve_mode(opts[:output] || :auto)

    result =
      Enum.reduce_while(stages, {[], ctx.store}, fn stage, {acc, current_store} ->
        ctx_with_store = Map.put(ctx, :store, current_store)
        stage_result = execute(stage, ctx_with_store, output_mode)

        if output_mode == :buffered do
          Reporter.print_step_output(stage_result)
        end

        case stage_result.status do
          :failed ->
            {:halt,
             {:error, {:stage_failed, stage.name, :failed}, Enum.reverse([stage_result | acc])}}

          _passed_or_skipped ->
            {:cont, {[stage_result | acc], stage_result.store}}
        end
      end)

    case result do
      {:error, _reason, _results} = error -> error
      {accumulated, _store} -> {:ok, Enum.reverse(accumulated)}
    end
  end

  @doc """
  Executes a single pipeline stage and returns a `%TinyCI.StageResult{}`.

  If the stage has a `when_condition` function that returns `false`,
  the stage is skipped. Otherwise, the stage's steps are run according
  to the stage's `mode`:

    * `:serial`   — steps run one at a time; halts on first failure.
      Each step sees the accumulated store from prior steps.
    * `:parallel` — steps run concurrently via `Task.Supervisor`.
      All steps see the same initial store; their store data is merged
      after completion.

  The returned `%StageResult{}` includes a `:store` field with the
  accumulated pipeline store after this stage's execution.

  ## Parameters

    * `stage`       — a `%TinyCI.Stage{}` struct
    * `context`     — a map of context data passed to conditions and steps
    * `output_mode` — `:streaming` or `:buffered` (default `:buffered`)

  ## Returns

    * `%TinyCI.StageResult{}` with status `:passed`, `:failed`, or `:skipped`
  """
  def execute(%TinyCI.Stage{} = stage, context \\ %{}, output_mode \\ :buffered) do
    context = Map.put_new(context, :store, %{})

    IO.puts("Stage: #{stage.name}")

    if skip_stage?(stage, context) do
      IO.puts("  Skipped (condition not met)")

      %StageResult{
        name: stage.name,
        status: :skipped,
        step_results: [],
        duration_ms: 0,
        store: context.store
      }
    else
      ctx_with_stage_env = Map.put(context, :stage_env, stage.env || %{})

      {duration_ms, {step_results, updated_store}} =
        measure(fn -> execute_by_mode(stage, ctx_with_stage_env, output_mode) end)

      status =
        if Enum.all?(step_results, &(&1.status in [:passed, :skipped] or &1.allowed_failure)),
          do: :passed,
          else: :failed

      %StageResult{
        name: stage.name,
        status: status,
        step_results: step_results,
        duration_ms: duration_ms,
        store: updated_store
      }
    end
  end

  defp skip_stage?(%{when_condition: nil}, _context), do: false

  defp skip_stage?(%{when_condition: f}, context) when is_function(f, 1),
    do: not f.(context)

  defp skip_stage?(%{when_condition: ast}, context),
    do: not TinyCI.DSL.ConditionEval.eval(ast, context)

  defp resolve_working_dir(nil, _root), do: nil

  defp resolve_working_dir(dir, root) do
    if Path.type(dir) == :absolute, do: dir, else: Path.join(root || File.cwd!(), dir)
  end

  defp execute_step_or_skip(step, context, output_mode, prefix, working_dir) do
    if skip_step?(step, context) do
      %StepResult{name: step.name, status: :skipped, duration_ms: 0}
    else
      run_step(step, context, output_mode, prefix, working_dir)
    end
  end

  defp skip_step?(%{when_condition: nil}, _context), do: false

  defp skip_step?(%{when_condition: f}, context) when is_function(f, 1),
    do: not f.(context)

  defp skip_step?(%{when_condition: ast}, context),
    do: not TinyCI.DSL.ConditionEval.eval(ast, context)

  defp execute_by_mode(
         %{mode: :serial, steps: steps, working_dir: stage_wd},
         context,
         output_mode
       ),
       do: execute_serial(steps, stage_wd, context, output_mode)

  defp execute_by_mode(
         %{mode: :parallel, steps: steps, working_dir: stage_wd},
         context,
         output_mode
       ),
       do: execute_parallel(steps, stage_wd, context, output_mode)

  defp execute_serial(steps, stage_wd, context, output_mode) do
    root = Map.get(context, :root)

    {results, final_store} =
      Enum.reduce_while(steps, {[], context.store}, fn step, {acc, current_store} ->
        ctx = Map.put(context, :store, current_store)
        effective_wd = resolve_working_dir(step.working_dir || stage_wd, root)

        step_result = execute_step_or_skip(step, ctx, output_mode, nil, effective_wd)

        new_store = Map.merge(current_store, step_result.store_data)

        case {step_result.status, step_result.allowed_failure} do
          {:passed, _} -> {:cont, {[step_result | acc], new_store}}
          {:skipped, _} -> {:cont, {[step_result | acc], new_store}}
          {:failed, true} -> {:cont, {[step_result | acc], new_store}}
          {:failed, false} -> {:halt, {[step_result | acc], new_store}}
        end
      end)

    {Enum.reverse(results), final_store}
  end

  defp execute_parallel(steps, stage_wd, context, output_mode) do
    prefix = if output_mode == :streaming, do: :step_name, else: nil
    caller_gl = Process.group_leader()
    root = Map.get(context, :root)

    tasks =
      Enum.map(steps, fn step ->
        step_prefix = if prefix == :step_name, do: step.name, else: nil
        effective_wd = resolve_working_dir(step.working_dir || stage_wd, root)

        Task.Supervisor.async(TinyCI.TaskSupervisor, fn ->
          Process.group_leader(self(), caller_gl)
          execute_step_or_skip(step, context, output_mode, step_prefix, effective_wd)
        end)
      end)

    step_results = Task.await_many(tasks, :infinity)

    merged_store =
      Enum.reduce(step_results, context.store, fn result, store ->
        Map.merge(store, result.store_data)
      end)

    {step_results, merged_store}
  end

  defp run_step(
         %{cmd: cmd, name: name, env: env, timeout: timeout, allow_failure: allow_failure},
         ctx,
         output_mode,
         prefix,
         working_dir
       )
       when cmd != nil do
    if working_dir != nil and not File.dir?(working_dir) do
      %StepResult{
        name: name,
        status: :failed,
        output: "Working directory not found: #{working_dir}",
        duration_ms: 0,
        allowed_failure: allow_failure
      }
    else
      pipeline_env = Map.get(ctx, :pipeline_env, %{})
      stage_env = Map.get(ctx, :stage_env, %{})
      merged_env = pipeline_env |> Map.merge(stage_env) |> Map.merge(resolve_env(env, ctx.store))
      output_opts = [mode: output_mode, env: merged_env, prefix: prefix, working_dir: working_dir]

      {duration_ms, {status, output}} =
        measure(fn ->
          run_cmd_with_timeout(cmd, output_opts, timeout)
        end)

      %StepResult{
        name: name,
        status: status,
        output: output,
        duration_ms: duration_ms,
        allowed_failure: allow_failure and status == :failed
      }
    end
  end

  defp run_step(
         %{module: module, name: name, config_block: block, allow_failure: allow_failure},
         ctx,
         _output_mode,
         _prefix,
         _working_dir
       )
       when not is_nil(module) do
    config = if block, do: block.(), else: %{}
    pipeline_env = Map.get(ctx, :pipeline_env, %{})
    stage_env = Map.get(ctx, :stage_env, %{})
    ctx = Map.put(ctx, :env, Map.merge(pipeline_env, stage_env))

    {duration_ms, {status, store_data}} =
      measure(fn ->
        case apply(module, :execute, [config, ctx]) do
          :ok -> {:passed, %{}}
          {:ok, data} when is_map(data) -> {:passed, data}
          {:error, _reason} -> {:failed, %{}}
        end
      end)

    %StepResult{
      name: name,
      status: status,
      output: "",
      duration_ms: duration_ms,
      allowed_failure: allow_failure and status == :failed,
      store_data: store_data
    }
  end

  defp resolve_env(env, store) do
    Map.new(env, fn
      {k, {:store, key}} -> {k, to_string(Map.get(store, key, ""))}
      {k, v} -> {k, v}
    end)
  end

  defp run_cmd_with_timeout(cmd, output_opts, nil) do
    Output.run_cmd(cmd, output_opts)
  end

  defp run_cmd_with_timeout(cmd, output_opts, timeout) when is_integer(timeout) do
    task =
      Task.Supervisor.async_nolink(TinyCI.TaskSupervisor, fn ->
        Output.run_cmd(cmd, output_opts)
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      nil -> {:failed, "Step timed out after #{timeout}ms"}
    end
  end

  defp measure(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    finish = System.monotonic_time(:millisecond)
    {finish - start, result}
  end
end
