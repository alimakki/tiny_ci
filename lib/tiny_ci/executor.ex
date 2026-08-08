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

  Every meaningful boundary is emitted as a structured event through
  `TinyCI.Events` to a per-run `TinyCI.Events.Dispatcher` (see `docs/events.md`).
  The human console output is produced by `TinyCI.Events.Sink.Console` consuming
  that stream; passing `events:` adds a `TinyCI.Events.Sink.NDJSON` sink. The
  `listener:` option selects which console sink is attached — `TinyCI.Listener.Human`
  (default) prints progress, `TinyCI.Listener.Silent` suppresses it (e.g. when
  serializing results to JSON) — and still drives the buffered step-output, matrix,
  and retry-attempt renderings that have not yet moved to the event sink.

  Passing `control:` arms execution-control breakpoints (see `TinyCI.Control` and
  `docs/execution-control.md`): the process that reaches an armed step/stage
  boundary blocks awaiting a command, so an independent parallel branch keeps
  running. Without `control:`, no control plane is started and every boundary costs
  a single map lookup.
  """

  alias TinyCI.{Artifacts, Cache, Control, DAG, Matrix, MatrixRunResult, Output}
  alias TinyCI.{StageResult, StepResult}
  alias TinyCI.Events
  alias TinyCI.Executor.{Driver, Env}

  alias TinyCI.Events.{
    CacheLookup,
    MatrixRunCompleted,
    MatrixRunStarted,
    PipelineCompleted,
    PipelineStarted,
    StageCompleted,
    StageSkipped,
    StageStarted,
    StepCompleted,
    StepOutputLine,
    StepRetrying,
    StepSkipped,
    StepStarted
  }

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
      * `:output`   — output mode: `:streaming`, `:buffered`, or `:auto` (default `:auto`)
      * `:listener` — a `TinyCI.Listener` implementation (default `TinyCI.Listener.Human`)
      * `:filter`   — list of stage name atoms to run; others are omitted
      * `:control`  — execution-control options (`:breakpoints`, `:timeout`,
        `:timeout_action`, `:subscribers`, `:serial`). See `TinyCI.Control`.

  ## Returns

    * `{:ok, [%StageResult{}]}` — when all stages succeed or are skipped
    * `{:error, {:stage_failed, stage_name, reason}, [%StageResult{}]}` — on first failure
    * `{:error, {:aborted, stage_name}, [%StageResult{}]}` — when execution control
      aborted the run

  Raises `ArgumentError` when `control:` carries an unparsable `--break` spec —
  a caller error, and one `mix tiny_ci.run` rejects before the run begins.
  """
  def run_pipeline(stages, context \\ nil, opts \\ [])

  def run_pipeline(stages, context, opts) when is_list(stages) do
    ctx = context || TinyCI.Context.build()
    ctx = Map.put_new(ctx, :store, %{})
    ctx = Map.put(ctx, :no_cache, opts[:no_cache] || false)
    ctx = put_artifacts_dir(ctx, opts)
    output_mode = Output.resolve_mode(opts[:output] || :auto)
    listener = opts[:listener] || TinyCI.Listener.Human
    filtered = apply_filter(stages, opts[:filter])

    {:ok, dispatcher} =
      Events.Dispatcher.start_link(build_sink_specs(listener, output_mode, opts))

    ctx = Map.put(ctx, :events, dispatcher)
    pipeline_name = opts[:pipeline_name] || :pipeline
    {ctx, control} = start_control(ctx, opts[:control], dispatcher)

    try do
      Events.emit(ctx, %PipelineStarted{
        run_id: ctx.run_id,
        timestamp: now(),
        pipeline_name: pipeline_name
      })

      {duration_ms, result} =
        measure(fn ->
          if DAG.dag_mode?(filtered) do
            run_pipeline_dag(filtered, ctx, output_mode, listener)
          else
            run_pipeline_sequential(filtered, ctx, output_mode, listener)
          end
        end)

      Events.emit(ctx, %PipelineCompleted{
        run_id: ctx.run_id,
        timestamp: now(),
        status: pipeline_status(result),
        duration_ms: duration_ms
      })

      result
    after
      # Stopped before the dispatcher so any control event it still emits is sunk.
      stop_control(control)
      Events.Dispatcher.stop(dispatcher)
    end
  end

  # Starts the run's control plane only when the caller armed breakpoints, and puts
  # its pid on the context. `Control.checkpoint/2` short-circuits on a `nil` here,
  # which is what keeps an ordinary run on exactly today's code path.
  defp start_control(ctx, nil, _dispatcher), do: {ctx, nil}

  defp start_control(ctx, control, dispatcher) do
    case Control.server_opts(control, ctx.run_id, dispatcher) do
      {:ok, server_opts} ->
        {:ok, server} = Control.Server.start_link(server_opts)

        ctx =
          ctx
          |> Map.put(:control, server)
          |> Map.put(:control_serial, Keyword.get(control, :serial, false))

        {ctx, server}

      {:error, messages} ->
        raise ArgumentError, "invalid control breakpoints: " <> Enum.join(messages, "; ")
    end
  end

  defp stop_control(nil), do: :ok
  defp stop_control(server), do: GenServer.stop(server)

  # Maps the `listener:` option to a set of event sinks: the console sink unless
  # output is silenced, an NDJSON sink when `events:` is given, plus any caller-
  # supplied `extra_sinks` (e.g. the provenance collector).
  defp build_sink_specs(listener, output_mode, opts) do
    console_specs(listener, output_mode) ++
      ndjson_specs(opts[:events]) ++ Keyword.get(opts, :extra_sinks, [])
  end

  defp console_specs(TinyCI.Listener.Silent, _mode), do: []
  defp console_specs(_listener, mode), do: [{Events.Sink.Console, [mode: mode]}]

  defp ndjson_specs(nil), do: []
  defp ndjson_specs(path), do: [{Events.Sink.NDJSON, [path: path]}]

  defp pipeline_status({:ok, _}), do: :passed
  defp pipeline_status({:error, {:aborted, _stage}, _}), do: :aborted
  defp pipeline_status({:error, _, _}), do: :failed

  defp now, do: DateTime.utc_now()

  defp put_artifacts_dir(ctx, opts) do
    root = Map.get(ctx, :root, File.cwd!())
    run_id = Artifacts.generate_run_id(ctx)

    artifacts_dir =
      case opts[:artifacts_dir] do
        nil -> Artifacts.run_artifacts_dir(root, run_id)
        base -> Path.join(base, run_id)
      end

    ctx
    |> Map.put(:run_id, run_id)
    |> Map.put(:artifacts_dir, artifacts_dir)
  end

  defp apply_filter(stages, nil), do: stages
  defp apply_filter(stages, []), do: stages

  defp apply_filter(stages, filter) do
    filter_set = MapSet.new(filter)
    all_names = MapSet.new(stages, & &1.name)

    Enum.each(stages, fn stage ->
      if MapSet.member?(filter_set, stage.name) do
        stage.needs
        |> Enum.filter(&(MapSet.member?(all_names, &1) and not MapSet.member?(filter_set, &1)))
        |> Enum.each(fn dep ->
          IO.puts([
            IO.ANSI.yellow(),
            ~s(Warning: ":#{stage.name}" needs ":#{dep}" which was filtered — running :#{stage.name} without it),
            IO.ANSI.reset()
          ])
        end)
      end
    end)

    stages
    |> Enum.filter(&MapSet.member?(filter_set, &1.name))
    |> Enum.map(fn stage ->
      %{stage | needs: Enum.filter(stage.needs, &MapSet.member?(filter_set, &1))}
    end)
  end

  defp run_pipeline_sequential(stages, ctx, output_mode, listener) do
    result =
      Enum.reduce_while(stages, {[], ctx.store}, fn stage, {acc, current_store} ->
        ctx_with_store = Map.put(ctx, :store, current_store)
        stage_result = execute(stage, ctx_with_store, output_mode, listener)

        if output_mode == :buffered, do: listener.stage_finished(stage_result)

        case stage_result.status do
          :aborted ->
            {:halt, {:error, {:aborted, stage.name}, Enum.reverse([stage_result | acc])}}

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

  defp run_pipeline_dag(stages, ctx, output_mode, listener) do
    case DAG.build_levels(stages) do
      {:error, _} = error ->
        error

      {:ok, levels} ->
        execute_dag_levels(levels, ctx, output_mode, listener)
    end
  end

  defp execute_dag_levels(levels, ctx, output_mode, listener) do
    initial = {[], ctx.store, MapSet.new()}

    {all_results, _store, _blocked} =
      Enum.reduce(levels, initial, fn level, {acc_results, current_store, blocked} ->
        ctx_with_store = Map.put(ctx, :store, current_store)

        {stage_results, new_blocked} =
          execute_dag_level(level, ctx_with_store, output_mode, blocked, listener)

        if output_mode == :buffered, do: Enum.each(stage_results, &listener.stage_finished/1)

        new_store =
          Enum.reduce(stage_results, current_store, fn r, s -> Map.merge(s, r.store) end)

        {acc_results ++ stage_results, new_store, new_blocked}
      end)

    # An abort dominates a failure: it says the run was stopped, not that the code
    # under test is broken.
    case {first_with(all_results, :aborted), first_with(all_results, :failed)} do
      {nil, nil} -> {:ok, all_results}
      {nil, failed} -> {:error, {:stage_failed, failed.name, :failed}, all_results}
      {aborted, _} -> {:error, {:aborted, aborted.name}, all_results}
    end
  end

  defp first_with(results, status), do: Enum.find(results, &(&1.status == status))

  defp execute_dag_level(stages, ctx, output_mode, blocked, listener) do
    stage_results = run_dag_stages(stages, ctx, output_mode, blocked, listener)

    new_blocked =
      Enum.zip(stages, stage_results)
      |> Enum.reduce(blocked, fn {stage, result}, acc ->
        dep_blocked? = Enum.any?(stage.needs, &MapSet.member?(blocked, &1))
        if result.status == :failed or dep_blocked?, do: MapSet.put(acc, stage.name), else: acc
      end)

    {stage_results, new_blocked}
  end

  # `--debug-serial` trades parallelism for predictable stepping: with a breakpoint
  # armed, independent stages run one at a time so the operator is never prompted
  # about two boundaries at once. Off by default — pausing one branch must not
  # freeze the others.
  defp run_dag_stages(stages, ctx, output_mode, blocked, listener) do
    if serial_control?(ctx) do
      Enum.map(stages, &run_dag_stage(&1, ctx, output_mode, blocked, listener))
    else
      caller_gl = Process.group_leader()

      stages
      |> Enum.map(&spawn_dag_stage(&1, ctx, output_mode, blocked, caller_gl, listener))
      |> Task.await_many(:infinity)
    end
  end

  defp serial_control?(ctx), do: Map.get(ctx, :control_serial, false)

  defp spawn_dag_stage(stage, ctx, output_mode, blocked, caller_gl, listener) do
    Task.Supervisor.async(TinyCI.TaskSupervisor, fn ->
      Process.group_leader(self(), caller_gl)
      run_dag_stage(stage, ctx, output_mode, blocked, listener)
    end)
  end

  defp run_dag_stage(stage, ctx, output_mode, blocked, listener) do
    if Enum.any?(stage.needs, &MapSet.member?(blocked, &1)) do
      Events.emit(ctx, %StageStarted{run_id: run_id(ctx), timestamp: now(), stage: stage.name})

      Events.emit(ctx, %StageSkipped{
        run_id: run_id(ctx),
        timestamp: now(),
        stage: stage.name,
        reason: "dependency failed"
      })

      %StageResult{
        name: stage.name,
        status: :skipped,
        step_results: [],
        duration_ms: 0,
        store: ctx.store
      }
    else
      execute(stage, ctx, output_mode, listener)
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
    * `listener`    — a `TinyCI.Listener` implementation (default `TinyCI.Listener.Human`)

  ## Returns

    * `%StageResult{}` with status `:passed`, `:failed`, or `:skipped`
  """
  def execute(
        %TinyCI.Stage{} = stage,
        context \\ %{},
        output_mode \\ :buffered,
        listener \\ TinyCI.Listener.Human
      ) do
    context = Map.put_new(context, :store, %{})

    case Map.get(context, :events) do
      nil ->
        with_ephemeral_dispatcher(context, output_mode, listener, fn ctx ->
          do_execute(stage, ctx, output_mode, listener)
        end)

      _pid ->
        do_execute(stage, context, output_mode, listener)
    end
  end

  # When `execute/4` is called standalone (no run dispatcher on the context),
  # spin up a short-lived dispatcher so its events and console output still work.
  defp with_ephemeral_dispatcher(context, output_mode, listener, fun) do
    {:ok, dispatcher} = Events.Dispatcher.start_link(build_sink_specs(listener, output_mode, []))

    ctx =
      context
      |> Map.put(:events, dispatcher)
      |> Map.put_new(:run_id, ephemeral_run_id())

    try do
      fun.(ctx)
    after
      Events.Dispatcher.stop(dispatcher)
    end
  end

  defp ephemeral_run_id, do: "run_" <> Integer.to_string(System.unique_integer([:positive]))

  defp do_execute(%TinyCI.Stage{} = stage, context, output_mode, listener) do
    Events.emit(context, %StageStarted{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage.name
    })

    if skip_stage?(stage, context) do
      Events.emit(context, %StageSkipped{
        run_id: run_id(context),
        timestamp: now(),
        stage: stage.name,
        reason: "condition not met"
      })

      %StageResult{
        name: stage.name,
        status: :skipped,
        step_results: [],
        duration_ms: 0,
        store: context.store
      }
    else
      ctx_with_stage =
        context
        |> Map.put(:stage_env, stage.env || %{})
        |> Map.put(:stage_name, stage.name)

      result = run_stage_with_control(stage, ctx_with_stage, output_mode, listener)

      Events.emit(context, %StageCompleted{
        run_id: run_id(context),
        timestamp: now(),
        stage: stage.name,
        status: result.status,
        duration_ms: result.duration_ms
      })

      result
    end
  end

  # The `before:` / `after:` stage boundaries. Runs in whichever process owns the
  # stage — the pipeline process in sequential mode, the stage's own task in DAG
  # mode — so pausing here leaves sibling stages untouched.
  defp run_stage_with_control(stage, ctx, output_mode, listener) do
    case Control.checkpoint(ctx, phase: :before) do
      {:abort, ctx, _overrides} -> aborted_stage(stage, ctx)
      {:skip, ctx, _overrides} -> control_skipped_stage(stage, ctx)
      {_continue_or_retry, ctx, _overrides} -> review_stage(stage, ctx, output_mode, listener)
    end
  end

  defp review_stage(stage, ctx, output_mode, listener) do
    result = run_stage_body(stage, ctx, output_mode, listener)
    # The `after:` payload must show the store the stage produced, not the one it
    # started with, so the operator inspects (and edits) what actually happened.
    after_ctx = Map.put(ctx, :store, result.store)

    case Control.checkpoint(after_ctx, phase: :after, result: result) do
      {:continue, ctx, _overrides} -> %{result | store: ctx.store}
      {:skip, ctx, _overrides} -> %{result | status: :skipped, store: ctx.store}
      {:abort, ctx, _overrides} -> %{result | status: :aborted, store: ctx.store}
      {:retry, ctx, _overrides} -> review_stage(stage, ctx, output_mode, listener)
    end
  end

  defp run_stage_body(stage, ctx, output_mode, listener) do
    if stage.matrix != [] do
      execute_matrix_stage(stage, ctx, output_mode, listener)
    else
      execute_regular_stage(stage, ctx, output_mode, listener)
    end
  end

  defp aborted_stage(stage, ctx) do
    %StageResult{
      name: stage.name,
      status: :aborted,
      step_results: [],
      duration_ms: 0,
      store: ctx.store
    }
  end

  defp control_skipped_stage(stage, ctx) do
    Events.emit(ctx, %StageSkipped{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage.name,
      reason: "skipped by execution control"
    })

    %StageResult{
      name: stage.name,
      status: :skipped,
      step_results: [],
      duration_ms: 0,
      store: ctx.store
    }
  end

  defp run_id(ctx), do: Map.get(ctx, :run_id)

  defp execute_regular_stage(stage, context, output_mode, listener) do
    {duration_ms, {step_results, updated_store}} =
      measure(fn -> execute_by_mode(stage, context, output_mode, listener) end)

    %StageResult{
      name: stage.name,
      status: rollup_status(step_results),
      step_results: step_results,
      duration_ms: duration_ms,
      store: updated_store
    }
  end

  # An abort outranks any failure or `allow_failure:` tolerance — the run was
  # stopped by hand, and no declaration in the pipeline file can excuse that away.
  defp rollup_status(step_results) do
    cond do
      Enum.any?(step_results, &(&1.status == :aborted)) -> :aborted
      Enum.all?(step_results, &step_acceptable?/1) -> :passed
      true -> :failed
    end
  end

  defp step_acceptable?(%StepResult{status: status, allowed_failure: allowed}),
    do: status in [:passed, :skipped] or allowed

  defp execute_matrix_stage(stage, context, _output_mode, listener) do
    combinations = Matrix.combinations(stage.matrix)
    max_concurrency = matrix_concurrency(stage, combinations, context)
    caller_gl = Process.group_leader()

    {duration_ms, run_results} =
      measure(fn ->
        TinyCI.TaskSupervisor
        |> Task.Supervisor.async_stream(
          combinations,
          fn combo ->
            Process.group_leader(self(), caller_gl)
            run_matrix_combination(stage, combo, context, listener)
          end,
          max_concurrency: max_concurrency,
          timeout: :infinity,
          ordered: true
        )
        |> Enum.map(fn {:ok, result} -> result end)
      end)

    listener.matrix_stage_finished(run_results)

    merged_store =
      Enum.reduce(run_results, context.store, fn r, acc -> Map.merge(acc, r.store) end)

    %StageResult{
      name: stage.name,
      status: matrix_stage_status(run_results, stage.allow_failure),
      step_results: [],
      matrix_runs: run_results,
      duration_ms: duration_ms,
      store: merged_store
    }
  end

  # `--debug-serial` also caps matrix fan-out at one combination, so stepping
  # through a matrix stage does not queue up N simultaneous prompts.
  defp matrix_concurrency(stage, combinations, context) do
    if serial_control?(context), do: 1, else: stage.max_parallel || length(combinations)
  end

  defp matrix_stage_status(run_results, allow_failure) do
    cond do
      Enum.any?(run_results, &(&1.status == :aborted)) -> :aborted
      allow_failure -> :passed
      Enum.any?(run_results, &(&1.status == :failed)) -> :failed
      true -> :passed
    end
  end

  defp run_matrix_combination(stage, combination, context, listener) do
    Events.emit(context, %MatrixRunStarted{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage.name,
      combination: combination
    })

    combo_env = Matrix.env_vars(combination)
    combo_store = Map.new(combination)

    ctx =
      context
      |> Map.update(:stage_env, combo_env, &Map.merge(&1, combo_env))
      |> Map.update(:store, combo_store, &Map.merge(&1, combo_store))
      # Carried so a breakpoint inside a matrix stage can report *which*
      # combination it stopped in — otherwise N identical payloads are ambiguous.
      |> Map.put(:matrix_combination, combination)

    stage_for_run = %{stage | matrix: [], max_parallel: nil}

    {duration_ms, {step_results, updated_store}} =
      measure(fn -> execute_by_mode(stage_for_run, ctx, :buffered, listener) end)

    status = rollup_status(step_results)

    Events.emit(context, %MatrixRunCompleted{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage.name,
      combination: combination,
      status: status,
      duration_ms: duration_ms
    })

    %MatrixRunResult{
      combination: combination,
      status: status,
      step_results: step_results,
      duration_ms: duration_ms,
      store: updated_store
    }
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

  defp execute_step_or_skip(step, context, output_mode, prefix, working_dir, listener) do
    if skip_step?(step, context) do
      emit_step_skipped(context, step, "condition not met")
      %StepResult{name: step.name, status: :skipped, duration_ms: 0}
    else
      Events.emit(context, %StepStarted{
        run_id: run_id(context),
        timestamp: now(),
        stage: stage_name(context),
        step: step.name
      })

      run_step_with_control(step, context, output_mode, prefix, working_dir, listener)
    end
  end

  # The `before:` step boundary. Runs in the step's own process (its task in
  # parallel mode, the stage's process in serial mode), so a pause is scoped to
  # this step alone.
  defp run_step_with_control(step, context, output_mode, prefix, working_dir, listener) do
    case Control.checkpoint(context, control_opts(step, working_dir, phase: :before)) do
      {:abort, ctx, overrides} ->
        finish_step(ctx, step, control_result(step, :aborted, overrides))

      {:skip, ctx, overrides} ->
        emit_step_skipped(ctx, step, "skipped by execution control")
        control_result(step, :skipped, overrides)

      {_continue_or_retry, ctx, overrides} ->
        review_step(step, ctx, output_mode, prefix, working_dir, listener, overrides)
    end
  end

  # Runs the step body, then offers the `after:` boundary. Store edits ride out on
  # the result's `store_data` so they propagate through the same merge a module
  # step's own return value does — including out of a parallel branch.
  defp review_step(step, ctx, output_mode, prefix, working_dir, listener, overrides) do
    result =
      step
      |> execute_with_cache(ctx, output_mode, prefix, working_dir, listener)
      |> persist_step_artifacts(step, ctx, working_dir)
      |> merge_overrides(overrides)

    after_ctx = Map.put(ctx, :store, Map.merge(ctx.store, result.store_data))
    opts = control_opts(step, working_dir, phase: :after, result: result)

    case Control.checkpoint(after_ctx, opts) do
      {:continue, c, edits} ->
        finish_step(c, step, merge_overrides(result, edits))

      {:skip, c, edits} ->
        finish_step(c, step, %{merge_overrides(result, edits) | status: :skipped})

      {:abort, c, edits} ->
        finish_step(c, step, %{merge_overrides(result, edits) | status: :aborted})

      {:retry, c, edits} ->
        # Bypass the cache: a hit would make the retry a silent no-op, and the
        # operator asked for the body to actually run again.
        retry_ctx = c |> Map.put(:store, c.store) |> Map.put(:no_cache, true)
        review_step(step, retry_ctx, output_mode, prefix, working_dir, listener, edits)
    end
  end

  defp control_opts(step, working_dir, opts) do
    Keyword.merge(opts, step: step.name, step_env: step.env, working_dir: working_dir)
  end

  defp control_result(step, status, overrides) do
    %StepResult{name: step.name, status: status, duration_ms: 0, store_data: overrides}
  end

  defp merge_overrides(result, overrides) when map_size(overrides) == 0, do: result

  defp merge_overrides(result, overrides),
    do: %{result | store_data: Map.merge(result.store_data, overrides)}

  defp finish_step(ctx, step, result) do
    emit_step_output(ctx, step.name, result.output)

    Events.emit(ctx, %StepCompleted{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage_name(ctx),
      step: step.name,
      status: result.status,
      duration_ms: result.duration_ms,
      output: result.output
    })

    result
  end

  defp emit_step_skipped(ctx, step, reason) do
    Events.emit(ctx, %StepSkipped{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage_name(ctx),
      step: step.name,
      reason: reason
    })
  end

  defp stage_name(ctx), do: Map.get(ctx, :stage_name)

  defp emit_step_output(_context, _step, ""), do: :ok

  defp emit_step_output(context, step, output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.each(fn line ->
      Events.emit(context, %StepOutputLine{
        run_id: run_id(context),
        timestamp: now(),
        stage: stage_name(context),
        step: step,
        line: line
      })
    end)
  end

  defp persist_step_artifacts(result, %{artifact: nil}, _ctx, _wd), do: result

  defp persist_step_artifacts(%{status: status} = result, _, _, _) when status != :passed,
    do: result

  defp persist_step_artifacts(result, %{artifact: artifact}, ctx, working_dir) do
    artifacts_dir = Map.get(ctx, :artifacts_dir)

    if is_nil(artifacts_dir) do
      result
    else
      src_base = working_dir || Map.get(ctx, :root, File.cwd!())

      case Artifacts.persist(artifact, src_base, artifacts_dir) do
        {:ok, artifact_path} ->
          store_key = String.to_atom("artifact_#{artifact.name}")
          %{result | store_data: Map.put(result.store_data, store_key, artifact_path)}

        {:warning, artifact_path, missing} ->
          IO.puts(:stderr, [
            IO.ANSI.yellow(),
            "Warning: artifact \"#{artifact.name}\" missing optional paths: #{Enum.join(missing, ", ")}",
            IO.ANSI.reset()
          ])

          store_key = String.to_atom("artifact_#{artifact.name}")
          %{result | store_data: Map.put(result.store_data, store_key, artifact_path)}

        {:error, {:missing_required, name, missing}} ->
          IO.puts(:stderr, [
            IO.ANSI.red(),
            "Error: required artifact \"#{name}\" paths not found: #{Enum.join(missing, ", ")}",
            IO.ANSI.reset()
          ])

          %{result | status: :failed}
      end
    end
  end

  defp execute_with_cache(
         %{cache: nil} = step,
         context,
         output_mode,
         prefix,
         working_dir,
         listener
       ) do
    run_step_with_retries(step, context, output_mode, prefix, working_dir, listener)
  end

  defp execute_with_cache(
         %{cache: cache} = step,
         context,
         output_mode,
         prefix,
         working_dir,
         listener
       ) do
    no_cache = Map.get(context, :no_cache, false)
    root = Map.get(context, :root, File.cwd!())
    key_file = Path.join(root, cache.key)

    with false <- no_cache,
         {:ok, key} <- Cache.compute_key(key_file) do
      cache_ctx = %{key: key, root: root, paths: cache.paths}
      run_cached(step, cache_ctx, context, output_mode, prefix, working_dir, listener)
    else
      _ -> run_step_with_retries(step, context, output_mode, prefix, working_dir, listener)
    end
  end

  defp run_cached(
         step,
         %{key: key, root: root, paths: paths},
         ctx,
         output_mode,
         prefix,
         wd,
         listener
       ) do
    if Cache.hit?(root, key, paths) do
      emit_cache_lookup(ctx, step.name, key, :hit)
      Cache.restore(root, key, paths, wd)
      %StepResult{name: step.name, status: :passed, duration_ms: 0, cache_status: :hit}
    else
      emit_cache_lookup(ctx, step.name, key, :miss)
      result = run_step_with_retries(step, ctx, output_mode, prefix, wd, listener)
      if result.status == :passed, do: Cache.save(root, key, paths, wd)
      %{result | cache_status: :miss}
    end
  end

  defp emit_cache_lookup(ctx, step, key, result) do
    Events.emit(ctx, %CacheLookup{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage_name(ctx),
      step: step,
      key: key,
      result: result
    })
  end

  defp run_step_with_retries(step, ctx, output_mode, prefix, working_dir, listener) do
    total = (step.retry || 0) + 1
    delay = step.retry_delay || 0
    attempt_step(step, ctx, output_mode, prefix, working_dir, {1, total, delay, 0}, listener)
  end

  defp attempt_step(
         step,
         ctx,
         output_mode,
         prefix,
         working_dir,
         {attempt, total, delay, acc_ms},
         listener
       ) do
    listener.step_attempt(attempt, total)

    if attempt > 1 do
      Events.emit(ctx, %StepRetrying{
        run_id: run_id(ctx),
        timestamp: now(),
        stage: stage_name(ctx),
        step: step.name,
        attempt: attempt
      })
    end

    result = run_step(step, ctx, output_mode, prefix, working_dir)
    total_ms = acc_ms + result.duration_ms

    if result.status == :failed and attempt < total do
      sleep_between_attempts(delay)

      attempt_step(
        step,
        ctx,
        output_mode,
        prefix,
        working_dir,
        {attempt + 1, total, delay, total_ms},
        listener
      )
    else
      %{result | attempts: attempt, duration_ms: total_ms}
    end
  end

  defp sleep_between_attempts(0), do: :ok
  defp sleep_between_attempts(delay), do: Process.sleep(delay)

  defp skip_step?(%{when_condition: nil}, _context), do: false

  defp skip_step?(%{when_condition: f}, context) when is_function(f, 1),
    do: not f.(context)

  defp skip_step?(%{when_condition: ast}, context),
    do: not TinyCI.DSL.ConditionEval.eval(ast, context)

  defp execute_by_mode(%{steps: steps, working_dir: stage_wd} = stage, ctx, output_mode, listener) do
    case effective_mode(stage, ctx) do
      :serial -> execute_serial(steps, stage_wd, ctx, output_mode, listener)
      :parallel -> execute_parallel(steps, stage_wd, ctx, output_mode, listener)
    end
  end

  # `--debug-serial` degrades a `mode: :parallel` stage to serial so steps are
  # reached in declaration order while breakpoints are armed.
  defp effective_mode(%{mode: :parallel}, ctx) do
    if serial_control?(ctx), do: :serial, else: :parallel
  end

  defp effective_mode(%{mode: mode}, _ctx), do: mode

  defp execute_serial(steps, stage_wd, context, output_mode, listener) do
    root = Map.get(context, :root)

    {results, final_store} =
      Enum.reduce_while(steps, {[], context.store}, fn step, {acc, current_store} ->
        ctx = Map.put(context, :store, current_store)
        effective_wd = resolve_working_dir(step.working_dir || stage_wd, root)

        step_result = execute_step_or_skip(step, ctx, output_mode, nil, effective_wd, listener)

        new_store = Map.merge(current_store, step_result.store_data)

        case {step_result.status, step_result.allowed_failure} do
          {:passed, _} -> {:cont, {[step_result | acc], new_store}}
          {:skipped, _} -> {:cont, {[step_result | acc], new_store}}
          {:failed, true} -> {:cont, {[step_result | acc], new_store}}
          {:failed, false} -> {:halt, {[step_result | acc], new_store}}
          # No `allow_failure:` tolerance for an abort — the run was stopped.
          {:aborted, _} -> {:halt, {[step_result | acc], new_store}}
        end
      end)

    {Enum.reverse(results), final_store}
  end

  defp execute_parallel(steps, stage_wd, context, output_mode, listener) do
    prefix = if output_mode == :streaming, do: :step_name, else: nil
    caller_gl = Process.group_leader()
    root = Map.get(context, :root)

    tasks =
      Enum.map(steps, fn step ->
        step_prefix = if prefix == :step_name, do: step.name, else: nil
        effective_wd = resolve_working_dir(step.working_dir || stage_wd, root)

        Task.Supervisor.async(TinyCI.TaskSupervisor, fn ->
          Process.group_leader(self(), caller_gl)
          execute_step_or_skip(step, context, output_mode, step_prefix, effective_wd, listener)
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
      merged_env = Env.resolve(ctx, env)
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
    ctx = Map.put(ctx, :env, Env.base(ctx))

    driver = Driver.select(module, ctx)

    {duration_ms, outcome} =
      measure(fn -> driver.run(module, config, ctx, Driver.opts(ctx)) end)

    {status, store_data, output} = interpret_outcome(outcome)

    %StepResult{
      name: name,
      status: status,
      output: output,
      duration_ms: duration_ms,
      allowed_failure: allow_failure and status == :failed,
      store_data: store_data
    }
  end

  defp interpret_outcome({:ok, delta}) when is_map(delta), do: {:passed, delta, ""}
  defp interpret_outcome({:error, reason}), do: {:failed, %{}, driver_error_message(reason)}

  defp driver_error_message({:untrusted_action, module}) do
    "Refused to run untrusted action #{inspect(module)} inline: it belongs to a " <>
      "dependency and must run in a sandbox (no sandbox driver selected)."
  end

  defp driver_error_message({:sandbox_unavailable, backend}) do
    "No sandbox backend available (#{inspect(backend)}); refusing to run an " <>
      "untrusted action unsandboxed."
  end

  defp driver_error_message(reason) when is_binary(reason), do: reason
  defp driver_error_message(reason), do: inspect(reason)

  defp run_cmd_with_timeout(cmd, output_opts, nil) do
    Output.run_cmd(cmd, output_opts)
  end

  defp run_cmd_with_timeout(cmd, output_opts, timeout) when is_integer(timeout) do
    # Output.run_cmd enforces the timeout at the OS-process level, killing the
    # command's entire subtree so nothing is left orphaned when it elapses.
    case Output.run_cmd(cmd, Keyword.put(output_opts, :timeout, timeout)) do
      {:timeout, _output} -> {:failed, "Step timed out after #{timeout}ms"}
      result -> result
    end
  end

  defp measure(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    finish = System.monotonic_time(:millisecond)
    {finish - start, result}
  end
end
