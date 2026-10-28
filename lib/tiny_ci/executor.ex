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
  All human console output is produced by `TinyCI.Events.Sink.Console` consuming
  that stream; passing `events:` adds a `TinyCI.Events.Sink.NDJSON` sink. Pass
  `console: false` to attach no console sink (e.g. when serializing results to
  JSON via `--output json`).

  Every run whose context carries a project `:root` is also recorded to the run
  store (`TinyCI.Runs`) by `TinyCI.Runs.Recorder`, another sink on the same stream;
  pass `record: false` to turn that off. A standalone `execute/4` never records.

  Passing `control:` arms execution-control breakpoints (see `TinyCI.Control` and
  `docs/execution-control.md`): the process that reaches an armed step/stage
  boundary blocks awaiting a command, so an independent parallel branch keeps
  running. Without `control:`, no control plane is started and every boundary costs
  a single map lookup.

  A crash (raise, exit, or throw) inside a step is a **failed step**, never a
  crashed run: it is caught at the step boundary and reported through the same
  `StepResult` and `step_finished` event as any other failure, with the formatted
  exception as the step's output (see `TinyCI.Executor.Crash`). Sibling steps and
  stages finish, `allow_failure:` still applies, and the worker tasks used for
  parallel steps, DAG levels, and matrix combinations are not linked to the run,
  so nothing that escapes those boundaries can take it down either.
  """

  alias TinyCI.{
    Artifacts,
    Cache,
    Control,
    DAG,
    Environment,
    Execution,
    Matrix,
    MatrixRunResult,
    Output
  }

  alias TinyCI.{Hooks, Redaction, Runs, Secrets, StageResult, StepResult}
  alias TinyCI.Events
  alias TinyCI.Execution.Command
  alias TinyCI.Execution.Preflight
  alias TinyCI.Executor.{Callback, Crash, Driver, Env}
  alias TinyCI.DSL.Value

  require Logger

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
      * `:console`  — whether to attach the human console sink (default `true`)
      * `:hooks`    — the pipeline's hooks map; run after the stages, before
        `run_finished`, so their events are part of the run's stream
      * `:filter`   — list of stage name atoms to run; others are omitted
      * `:control`  — execution-control options (`:breakpoints`, `:timeout`,
        `:timeout_action`, `:subscribers`, `:serial`). See `TinyCI.Control`.
      * `:record`   — set to `false` to skip recording the run to the run store
        (default: record when the context has a `:root`; see `TinyCI.Runs`)
      * `:secrets`  — resolved secrets as a `%{name => value}` map (see
        `TinyCI.Secrets`). They become the lowest env layer of every step and
        hook, and their values are masked in step output, results, and events.
      * `:backend`  — override the execution backend (default: Local for a
        trusted run). This is a programmatic policy/test seam; an untrusted run
        with no explicit backend fails closed.
      * `:pipeline_image` — the pipeline-level `image:` declaration. Stages
        inherit it unless they declare their own `image:` or `environment:`.
        Legacy callers may pass `:image` (or set `ctx.image`) instead.
      * `:pipeline_environment` — the pipeline-level `environment:`
        declaration, resolved through `mise` for a trusted run and mapped to an
        image (or refused) for an untrusted one.
      * `:available?`, `:digest`, `:toolchain`, `:default_image`,
        `:environments`, `:pull`, `:check_availability` — environment
        resolution seams and operator configuration. See
        `TinyCI.Environment.plan/3`.

  ## Returns

    * `{:ok, [%StageResult{}]}` — when all stages succeed or are skipped
    * `{:error, {:stage_failed, stage_name, reason}, [%StageResult{}]}` — on first failure
    * `{:error, {:aborted, stage_name}, [%StageResult{}]}` — when execution control
      aborted the run
    * `{:error, {:execution_unavailable, reason}, []}` — when no execution
      backend is permitted (for example an untrusted run with no container
      runtime, or no image and no operator default)

  Raises `ArgumentError` when `control:` carries an unparsable `--break` spec —
  a caller error, and one `mix tiny_ci.run` rejects before the run begins.
  """
  def run_pipeline(stages, context \\ nil, opts \\ [])

  def run_pipeline(stages, context, opts) when is_list(stages) do
    ctx = (context || TinyCI.Context.build()) |> Execution.put_default_trust()
    ctx = Map.put_new(ctx, :store, %{})
    ctx = Map.put(ctx, :no_cache, opts[:no_cache] || false)
    ctx = put_artifacts_dir(ctx, opts)
    ctx = Secrets.attach(ctx, opts[:secrets] || Map.get(ctx, :secrets, %{}))
    output_mode = Output.resolve_mode(opts[:output] || :auto)
    filtered = apply_filter(stages, opts[:filter])

    {:ok, dispatcher} =
      Events.Dispatcher.start_link(
        build_sink_specs(output_mode, opts) ++ record_specs(ctx, opts),
        redact: ctx.secret_values
      )

    ctx = Map.put(ctx, :events, dispatcher)
    {ctx, control} = start_control_or_stop(ctx, opts[:control], dispatcher)

    try do
      run_started(stages, filtered, ctx, output_mode, opts)
    after
      # Stopped before the dispatcher so any control event it still emits is sunk.
      stop_control(control)
      Events.Dispatcher.stop(dispatcher)
    end
  end

  defp run_started(stages, filtered, ctx, output_mode, opts) do
    Events.emit(ctx, %PipelineStarted{
      run_id: ctx.run_id,
      timestamp: now(),
      pipeline_name: opts[:pipeline_name] || :pipeline,
      branch: Map.get(ctx, :branch),
      commit: Map.get(ctx, :commit),
      base_ref: Map.get(ctx, :base_ref),
      root: Map.get(ctx, :root)
    })

    case Preflight.check(ctx, stages, opts[:hooks] || %{}) do
      :ok -> run_with_policy(filtered, ctx, output_mode, opts)
      {:error, reason} -> fail_run(ctx, reason)
    end
  end

  defp run_with_policy(stages, ctx, output_mode, opts) do
    env_opts = environment_opts(ctx, opts)
    plan = Environment.plan(stages, ctx, env_opts)

    ctx =
      ctx
      |> Map.put(:environment_plan, plan)
      |> Map.put(:environment_opts, env_opts)

    case Environment.strict(plan) do
      {:ok, %{run: run_env}} ->
        run_stages_and_hooks(stages, put_run_environment(ctx, run_env), output_mode, opts)

      {:error, reason} ->
        fail_run(ctx, {:execution_unavailable, reason})
    end
  end

  # The pipeline declaration applies to the hook phase. A shell hook in a
  # trusted run with no declaration resolves to the host environment, so the
  # hook's behaviour and environment are unchanged.
  defp put_run_environment(ctx, nil), do: ctx
  defp put_run_environment(ctx, env), do: put_execution_env(ctx, env)

  defp put_execution_env(ctx, %Environment{} = env) do
    ctx
    |> Map.put(:execution_backend, env.backend)
    |> Map.put(:execution_image, env.run_ref)
    |> Map.put(:image, env.run_ref)
    |> Map.put(:execution_environment, env)
    |> Map.put(:toolchain_env, env.env)
  end

  # Everything `TinyCI.Environment.plan/3` needs. Nil values are omitted because
  # `Environment` falls back to operator configuration for `:default_image` and
  # `:environments`, and to the real resolver for `:digest`/`:toolchain`.
  defp environment_opts(ctx, opts) do
    {pipeline_image, pipeline_environment} = pipeline_declaration(ctx, opts)

    [
      pipeline_image: pipeline_image,
      pipeline_environment: pipeline_environment,
      hooks: opts[:hooks] || %{},
      backend: opts[:backend],
      available?: opts[:available?],
      digest: opts[:digest],
      toolchain: opts[:toolchain],
      pull: Keyword.get(opts, :pull, true),
      check_availability: Keyword.get(opts, :check_availability, true)
    ]
    |> put_present(:default_image, opts[:default_image])
    |> put_present(:environments, opts[:environments])
  end

  defp put_present(opts, _key, nil), do: opts
  defp put_present(opts, key, value), do: Keyword.put(opts, key, value)

  # `:pipeline_image`/`:pipeline_environment` are the current options;
  # `opts[:image]` and `ctx[:image]` are the pre-M1.5-03 spellings and still
  # name a pipeline image.
  defp pipeline_declaration(ctx, opts) do
    image =
      Keyword.get(opts, :pipeline_image) ||
        Keyword.get(opts, :image) ||
        Map.get(ctx, :image)

    environment =
      normalize_environment(
        Keyword.get(opts, :pipeline_environment) || Map.get(ctx, :pipeline_environment)
      )

    case {blank?(image), environment} do
      {false, _environment} -> {image, nil}
      {true, nil} -> {nil, nil}
      {true, environment} -> {nil, environment}
    end
  end

  defp blank?(value), do: not (is_binary(value) and value != "")

  defp normalize_environment(nil), do: nil

  defp normalize_environment(environment) when is_atom(environment),
    do: Atom.to_string(environment)

  defp normalize_environment(environment) when is_binary(environment), do: environment

  defp fail_run(ctx, reason) do
    Events.emit(ctx, %PipelineCompleted{
      run_id: ctx.run_id,
      timestamp: now(),
      status: :failed,
      duration_ms: 0
    })

    {:error, reason, []}
  end

  defp run_stages_and_hooks(stages, ctx, output_mode, opts) do
    {duration_ms, result} =
      measure(fn ->
        if DAG.dag_mode?(stages) do
          run_pipeline_dag(stages, ctx, output_mode)
        else
          run_pipeline_sequential(stages, ctx, output_mode)
        end
      end)

    run_pipeline_hooks(opts[:hooks], result, ctx)

    Events.emit(ctx, %PipelineCompleted{
      run_id: ctx.run_id,
      timestamp: now(),
      status: pipeline_status(result),
      duration_ms: duration_ms
    })

    result
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

  # The dispatcher, and so every sink, is already open when the control spec is
  # validated. A bad spec raises; it must not leave them running behind the caller.
  defp start_control_or_stop(ctx, control, dispatcher) do
    start_control(ctx, control, dispatcher)
  rescue
    error ->
      Events.Dispatcher.stop(dispatcher)
      reraise error, __STACKTRACE__
  end

  defp stop_control(nil), do: :ok
  defp stop_control(server), do: GenServer.stop(server)

  # Builds the run's sink set: the console sink unless silenced, an NDJSON sink
  # when `events:` is given, plus any caller-supplied `extra_sinks` (e.g. the
  # provenance collector).
  defp build_sink_specs(output_mode, opts) do
    console_specs(output_mode, opts) ++
      ndjson_specs(opts[:events]) ++ Keyword.get(opts, :extra_sinks, [])
  end

  defp console_specs(output_mode, opts) do
    if Keyword.get(opts, :console, true) do
      [{Events.Sink.Console, [mode: output_mode]}]
    else
      []
    end
  end

  # Hooks are part of the run's stream, so they run here — after the stages but
  # before `PipelineCompleted` — while the dispatcher is still open. `nil` when
  # the caller passed no hooks (e.g. a standalone `execute/4`).
  defp run_pipeline_hooks(nil, _result, _ctx), do: :ok

  defp run_pipeline_hooks(hooks, result, ctx) do
    event = if pipeline_status(result) == :passed, do: :on_success, else: :on_failure
    Hooks.run_hooks(hooks, event, Map.put(ctx, :store, merged_store(ctx.store, result)))
  rescue
    e ->
      # Hooks run inside the run, before `run_finished`; a bug must not swallow
      # the run's completion event.
      Logger.error("pipeline hooks crashed: #{Exception.message(e)}")
      :ok
  end

  defp merged_store(store, {:ok, results}), do: merge_store_deltas(store, results)
  defp merged_store(store, {:error, _reason, results}), do: merge_store_deltas(store, results)

  defp merge_store_deltas(store, results) do
    Enum.reduce(results, store, fn result, acc -> Map.merge(acc, result.store_delta) end)
  end

  defp ndjson_specs(nil), do: []
  defp ndjson_specs(path), do: [{Events.Sink.NDJSON, [path: path]}]

  # Every run with a project root is recorded to the run store (see `TinyCI.Runs`)
  # unless the caller passes `record: false`. This is deliberately not part of
  # `build_sink_specs/3`: a standalone `execute/4` has no run id and no root, and
  # must never write to the data dir.
  defp record_specs(ctx, opts) do
    case {Keyword.get(opts, :record), Map.get(ctx, :root)} do
      {false, _root} -> []
      {_default, root} when is_binary(root) -> [{Runs.Recorder, root: root, run_id: ctx.run_id}]
      {_default, _no_root} -> []
    end
  end

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

    for stage <- stages,
        MapSet.member?(filter_set, stage.name),
        dep <- stage.needs,
        MapSet.member?(all_names, dep),
        not MapSet.member?(filter_set, dep) do
      IO.puts(:stderr, [
        IO.ANSI.yellow(),
        ~s(Warning: ":#{stage.name}" needs ":#{dep}" which was filtered — running :#{stage.name} without it),
        IO.ANSI.reset()
      ])
    end

    stages
    |> Enum.filter(&MapSet.member?(filter_set, &1.name))
    |> Enum.map(fn stage ->
      %{stage | needs: Enum.filter(stage.needs, &MapSet.member?(filter_set, &1))}
    end)
  end

  defp run_pipeline_sequential(stages, ctx, output_mode) do
    result =
      Enum.reduce_while(stages, {[], ctx.store}, fn stage, {acc, current_store} ->
        ctx_with_store = Map.put(ctx, :store, current_store)
        stage_result = execute(stage, ctx_with_store, output_mode)

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

  defp run_pipeline_dag(stages, ctx, output_mode) do
    case DAG.build_levels(stages) do
      {:error, _} = error ->
        error

      {:ok, levels} ->
        execute_dag_levels(levels, ctx, output_mode)
    end
  end

  defp execute_dag_levels(levels, ctx, output_mode) do
    initial = {[], ctx.store, MapSet.new()}

    {all_results, _store, _blocked} =
      Enum.reduce(levels, initial, fn level, {acc_results, current_store, blocked} ->
        ctx_with_store = Map.put(ctx, :store, current_store)

        {stage_results, new_blocked} =
          execute_dag_level(level, ctx_with_store, output_mode, blocked)

        new_store =
          Enum.reduce(stage_results, current_store, fn r, s -> Map.merge(s, r.store_delta) end)

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

  defp execute_dag_level(stages, ctx, output_mode, blocked) do
    stage_results = run_dag_stages(stages, ctx, output_mode, blocked)

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
  defp run_dag_stages(stages, ctx, output_mode, blocked) do
    if serial_control?(ctx) do
      Enum.map(stages, &run_dag_stage(&1, ctx, output_mode, blocked))
    else
      caller_gl = Process.group_leader()

      tasks =
        Enum.map(stages, &spawn_dag_stage(&1, ctx, output_mode, blocked, caller_gl))

      tasks
      |> Task.yield_many(timeout: :infinity)
      |> Enum.zip_with(stages, fn
        {_task, {:ok, result}}, _stage -> result
        {_task, {:exit, reason}}, stage -> escaped_stage_crash(stage, ctx, reason)
      end)
    end
  end

  defp serial_control?(ctx), do: Map.get(ctx, :control_serial, false)

  defp spawn_dag_stage(stage, ctx, output_mode, blocked, caller_gl) do
    Task.Supervisor.async_nolink(TinyCI.TaskSupervisor, fn ->
      Process.group_leader(self(), caller_gl)
      run_dag_stage(stage, ctx, output_mode, blocked)
    end)
  end

  # Defense in depth: the stage boundary in `do_execute/4` should have caught
  # this, so an exit reaching here is logged loudly rather than swallowed.
  defp escaped_stage_crash(stage, ctx, reason) do
    crashed_stage(stage, ctx, Crash.format(:exit, reason, []))
  end

  defp crashed_stage(stage, ctx, text) do
    text = mask(ctx, text)
    Logger.error("Stage #{stage.name} crashed outside any step: #{text}")

    Events.emit(ctx, %StageCompleted{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage.name,
      status: :failed,
      duration_ms: 0
    })

    %StageResult{
      name: stage.name,
      status: :failed,
      step_results: [],
      duration_ms: 0,
      store: ctx.store
    }
  end

  defp run_dag_stage(stage, ctx, output_mode, blocked) do
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
      execute(stage, ctx, output_mode)
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
    * `opts`        — sink options; `console: false` attaches no console sink,
      and `backend: Module` overrides the execution backend

  ## Returns

    * `%StageResult{}` with status `:passed`, `:failed`, or `:skipped`

  Raises `TinyCI.Execution.Error` when the context is untrusted and no execution
  backend is permitted.
  """
  def execute(
        %TinyCI.Stage{} = stage,
        context \\ %{},
        output_mode \\ :buffered,
        opts \\ []
      ) do
    context =
      context
      |> Map.put_new(:store, %{})
      |> Execution.put_default_trust()

    case Preflight.check(context, [stage], %{}) do
      :ok ->
        :ok

      {:error, reason} ->
        raise Execution.Error,
          message: Execution.error_message(reason),
          reason: reason
    end

    {context, plan} = environment_for_execute(context, stage, opts)
    context = stage_environment!(context, plan, stage)

    case Map.get(context, :events) do
      nil ->
        with_ephemeral_dispatcher(context, output_mode, opts, fn ctx ->
          do_execute(stage, ctx, output_mode)
        end)

      _pid ->
        do_execute(stage, context, output_mode)
    end
  end

  # `run_pipeline/3` plans every runnable stage up front and puts the plan on
  # the context. A standalone `execute/4` plans its single stage here. Using a
  # stage's entry (rather than re-resolving) is what keeps every session of a
  # stage on one digest.
  defp environment_for_execute(context, stage, opts) do
    env_opts = environment_opts(context, opts)

    case Map.get(context, :environment_plan) do
      %{} = plan ->
        {Map.put_new(context, :environment_opts, env_opts), plan}

      nil ->
        plan = Environment.plan([stage], context, env_opts)

        context =
          context
          |> Map.put(:environment_plan, plan)
          |> Map.put(:environment_opts, env_opts)

        {context, plan}
    end
  end

  # A stage that was omitted from the plan was skipped at plan time. It can
  # still become runnable (a `when:` that reads the store), and then it must
  # resolve its own declaration — never inherit whatever backend happened to be
  # on the context, and never fall back to the host.
  defp stage_environment!(context, plan, stage) do
    case plan_entry(plan, stage.name) do
      nil -> context
      {:ok, env} -> put_execution_env(context, env)
      {:error, reason} -> raise_stage_environment(stage.name, reason)
    end
  end

  defp ensure_stage_environment!(context, stage) do
    case plan_entry(Map.get(context, :environment_plan), stage.name) do
      {:ok, env} ->
        put_execution_env(context, env)

      {:error, reason} ->
        raise_stage_environment(stage.name, reason)

      nil ->
        entry =
          Environment.stage_environment(
            stage,
            context,
            Map.get(context, :environment_opts, [])
          )

        case entry do
          {:ok, env} -> put_execution_env(context, env)
          {:error, reason} -> raise_stage_environment(stage.name, reason)
        end
    end
  end

  defp plan_entry(%{stages: stages}, name), do: Map.get(stages, name)
  defp plan_entry(_plan, _name), do: nil

  defp raise_stage_environment(name, reason) do
    tagged = {:stage, name, reason}

    raise Execution.Error,
      message: Execution.error_message(tagged),
      reason: tagged
  end

  # When `execute/4` is called standalone (no run dispatcher on the context),
  # spin up a short-lived dispatcher so its events and console output still work.
  defp with_ephemeral_dispatcher(context, output_mode, opts, fun) do
    {:ok, dispatcher} =
      Events.Dispatcher.start_link(
        build_sink_specs(output_mode, opts),
        redact: secret_values(context)
      )

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

  defp do_execute(%TinyCI.Stage{} = stage, context, output_mode) do
    Events.emit(context, %StageStarted{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage.name
    })

    run_stage_guarded(stage, context, output_mode)
  end

  # The stage boundary. Covers the `when:` evaluation as well as the stage body,
  # so a crash outside any step still yields a failed `StageResult` and a
  # `stage_finished` event instead of taking the run down.
  defp run_stage_guarded(stage, context, output_mode) do
    run_stage_or_skip(stage, context, output_mode)
  rescue
    e -> crashed_stage(stage, context, Crash.format(:error, e, __STACKTRACE__))
  catch
    kind, reason -> crashed_stage(stage, context, Crash.format(kind, reason, __STACKTRACE__))
  end

  defp run_stage_or_skip(stage, context, output_mode) do
    context = Map.put(context, :stage_env, stage.env || %{})

    if TinyCI.Stage.skipped?(stage, context) do
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
      # Resolve here, after the skip check: a stage that is still skipped must
      # not pull an image or need a runtime. This also covers a stage that was
      # omitted from the plan because its condition was false and became true
      # once an earlier stage updated the store.
      context = ensure_stage_environment!(context, stage)

      ctx_with_stage =
        context
        |> Map.put(:stage_env, stage.env || %{})
        |> Map.put(:stage_name, stage.name)

      result = run_stage_with_control(stage, ctx_with_stage, output_mode)

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
  defp run_stage_with_control(stage, ctx, output_mode) do
    {command, ctx, overrides} = Control.checkpoint(ctx, phase: :before)

    result =
      case command do
        :abort -> aborted_stage(stage, ctx)
        :skip -> control_skipped_stage(stage, ctx)
        _ -> review_stage(stage, ctx, output_mode)
      end

    %{result | store_delta: Map.merge(overrides, result.store_delta)}
  end

  # A regular stage owns one session for its whole life: the body, the `after:`
  # boundary, and any retry. A retry must keep the toolchain and `$HOME` state the
  # session exists to preserve; matrix stages instead open one session per
  # combination inside `execute_matrix_stage/3`.
  defp review_stage(%{matrix: []} = stage, ctx, output_mode) do
    Execution.with_session(
      Execution.session_spec(ctx, network: stage.network),
      fn session ->
        review_stage_body(stage, Map.put(ctx, :execution_session, session), output_mode)
      end,
      backend: Execution.backend(ctx)
    )
  end

  defp review_stage(%{matrix: _matrix} = stage, ctx, output_mode) do
    review_stage_body(stage, ctx, output_mode)
  end

  defp review_stage_body(stage, ctx, output_mode) do
    result = run_stage_body(stage, ctx, output_mode)
    # The `after:` payload must show the store the stage produced, not the one it
    # started with, so the operator inspects (and edits) what actually happened.
    after_ctx = Map.put(ctx, :store, result.store)

    {command, ctx, overrides} = Control.checkpoint(after_ctx, phase: :after, result: result)
    result = %{result | store: ctx.store, store_delta: Map.merge(result.store_delta, overrides)}

    case command do
      :continue ->
        result

      :skip ->
        %{result | status: :skipped}

      :abort ->
        %{result | status: :aborted}

      :retry ->
        retried = review_stage_body(stage, ctx, output_mode)
        %{retried | store_delta: Map.merge(result.store_delta, retried.store_delta)}
    end
  end

  defp run_stage_body(stage, ctx, output_mode) do
    if stage.matrix != [] do
      execute_matrix_stage(stage, ctx, output_mode)
    else
      execute_regular_stage(stage, ctx, output_mode)
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

  defp execute_regular_stage(stage, context, output_mode) do
    {duration_ms, {step_results, updated_store}} =
      measure(fn -> execute_by_mode(stage, context, output_mode) end)

    %StageResult{
      name: stage.name,
      status: rollup_status(step_results),
      step_results: step_results,
      duration_ms: duration_ms,
      store: updated_store,
      store_delta: step_writes(step_results)
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

  defp execute_matrix_stage(stage, context, _output_mode) do
    combinations = Matrix.combinations(stage.matrix)
    max_concurrency = matrix_concurrency(stage, combinations, context)
    caller_gl = Process.group_leader()

    {duration_ms, run_results} =
      measure(fn ->
        TinyCI.TaskSupervisor
        |> Task.Supervisor.async_stream_nolink(
          Enum.with_index(combinations),
          fn {combo, index} ->
            Process.group_leader(self(), caller_gl)
            run_matrix_combination(stage, combo, index, context)
          end,
          max_concurrency: max_concurrency,
          timeout: :infinity,
          ordered: true,
          zip_input_on_exit: true
        )
        |> Enum.map(fn
          {:ok, result} ->
            result

          {:exit, {combination, reason}} ->
            escaped_matrix_crash(stage, combination, reason, context)
        end)
      end)

    merged_store =
      Enum.reduce(run_results, %{}, fn r, acc -> Map.merge(acc, r.store_delta) end)

    %StageResult{
      name: stage.name,
      status: matrix_stage_status(run_results, stage.allow_failure),
      step_results: [],
      matrix_runs: run_results,
      duration_ms: duration_ms,
      store: Map.merge(context.store, merged_store),
      store_delta: merged_store
    }
  end

  # Defense in depth, as with `escaped_stage_crash/3`: the step boundary should
  # have caught this inside the combination's own task.
  defp escaped_matrix_crash(stage, combination, reason, context) do
    text = Crash.format(:exit, reason, [])

    Logger.error(
      "Matrix combination #{inspect(combination)} of stage #{stage.name} crashed: #{text}"
    )

    Events.emit(context, %MatrixRunCompleted{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage.name,
      combination: combination,
      status: :failed,
      duration_ms: 0
    })

    %MatrixRunResult{combination: combination, status: :failed, step_results: [], store: %{}}
  end

  # `--debug-serial` also caps matrix fan-out at one combination, so stepping
  # through a matrix stage does not queue up N simultaneous prompts. Without an
  # explicit `max_parallel:`, fan-out is bounded by the scheduler count so a wide
  # matrix does not start every combination's processes at once.
  defp matrix_concurrency(stage, combinations, context) do
    cond do
      serial_control?(context) -> 1
      stage.max_parallel -> stage.max_parallel
      true -> min(length(combinations), System.schedulers_online())
    end
  end

  defp matrix_stage_status(run_results, allow_failure) do
    cond do
      Enum.any?(run_results, &(&1.status == :aborted)) -> :aborted
      allow_failure -> :passed
      Enum.any?(run_results, &(&1.status == :failed)) -> :failed
      true -> :passed
    end
  end

  defp run_matrix_combination(stage, combination, index, context) do
    Events.emit(context, %MatrixRunStarted{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage.name,
      combination: combination,
      index: index
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
      |> matrix_artifacts(stage.name, combination)

    stage_for_run = %{stage | matrix: [], max_parallel: nil}

    Execution.with_session(
      Execution.session_spec(context, network: stage.network),
      fn session ->
        ctx = Map.put(ctx, :execution_session, session)

        {duration_ms, {step_results, updated_store}} =
          measure(fn -> execute_by_mode(stage_for_run, ctx, :buffered) end)

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
          store: updated_store,
          store_delta: Map.merge(combo_store, step_writes(step_results))
        }
      end,
      backend: Execution.backend(context)
    )
  end

  defp step_writes(results) do
    Enum.reduce(results, %{}, fn result, writes -> Map.merge(writes, result.store_data) end)
  end

  defp matrix_artifacts(%{artifacts_dir: dir} = ctx, stage, combination) when is_binary(dir) do
    digest = :crypto.hash(:sha256, :erlang.term_to_binary({stage, combination}, [:deterministic]))
    Map.put(ctx, :artifacts_dir, Path.join(dir, "matrix-" <> Base.encode16(digest, case: :lower)))
  end

  defp matrix_artifacts(ctx, _stage, _combination), do: ctx

  defp resolve_working_dir(nil, root), do: root || File.cwd!()

  defp resolve_working_dir(dir, root) do
    if Path.type(dir) == :absolute, do: dir, else: Path.join(root || File.cwd!(), dir)
  end

  defp execute_step_or_skip(step, context, output_mode, prefix, working_dir, index) do
    context = Map.put(context, :env, Env.resolve(context, step.env))

    if skip_step?(step, context) do
      emit_step_skipped(context, step, "condition not met")
      %StepResult{name: step.name, status: :skipped, duration_ms: 0}
    else
      Events.emit(context, %StepStarted{
        run_id: run_id(context),
        timestamp: now(),
        stage: stage_name(context),
        step: step.name,
        matrix_combination: combination(context),
        prefix: prefix,
        attempts: planned_attempts(step),
        index: index
      })

      run_step_guarded(step, context, output_mode, prefix, working_dir)
    end
  end

  # The total number of attempts a step may make, when it can retry. `nil` for a
  # step with no retries, so ordinary `step_started` lines are unchanged.
  defp planned_attempts(step) do
    case Map.get(step, :retry, 0) do
      retries when is_integer(retries) and retries > 0 -> retries + 1
      _none -> nil
    end
  end

  # The step boundary: the single place a crash in one step's execution — the
  # action itself, cache restore, artifact copy, port errors — becomes a failed
  # `StepResult` carrying the formatted exception, with the usual events emitted.
  defp run_step_guarded(step, context, output_mode, prefix, working_dir) do
    run_step_with_control(step, context, output_mode, prefix, working_dir)
  rescue
    e -> crashed_step(context, step, Crash.format(:error, e, __STACKTRACE__))
  catch
    kind, reason -> crashed_step(context, step, Crash.format(kind, reason, __STACKTRACE__))
  end

  defp crashed_step(ctx, step, text) do
    output = mask(ctx, text)
    emit_step_output(ctx, step.name, output)

    finish_step(ctx, step, %StepResult{
      name: step.name,
      status: :failed,
      output: output,
      duration_ms: 0,
      allowed_failure: step.allow_failure
    })
  end

  # The `before:` step boundary. Runs in the step's own process (its task in
  # parallel mode, the stage's process in serial mode), so a pause is scoped to
  # this step alone.
  defp run_step_with_control(step, context, output_mode, prefix, working_dir) do
    case Control.checkpoint(context, control_opts(step, working_dir, phase: :before)) do
      {:abort, ctx, overrides} ->
        finish_step(ctx, step, control_result(step, :aborted, overrides))

      {:skip, ctx, overrides} ->
        emit_step_skipped(ctx, step, "skipped by execution control")
        control_result(step, :skipped, overrides)

      {_continue_or_retry, ctx, overrides} ->
        review_step(step, ctx, output_mode, prefix, working_dir, overrides)
    end
  end

  # Runs the step body, then offers the `after:` boundary. Store edits ride out on
  # the result's `store_data` so they propagate through the same merge a module
  # step's own return value does — including out of a parallel branch.
  defp review_step(step, ctx, output_mode, prefix, working_dir, overrides) do
    result =
      step
      |> execute_with_cache(ctx, output_mode, prefix, working_dir)
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
        review_step(step, retry_ctx, output_mode, prefix, working_dir, edits)
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

  # Output lines are emitted as they are produced (by `Output`'s `:on_line`
  # callback for shell steps, or directly for module/crash output), so this only
  # records the step's completion.
  defp finish_step(ctx, step, result) do
    Events.emit(ctx, %StepCompleted{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage_name(ctx),
      step: step.name,
      status: result.status,
      duration_ms: result.duration_ms,
      output: result.output,
      allowed_failure: result.allowed_failure,
      matrix_combination: combination(ctx)
    })

    result
  end

  defp emit_step_skipped(ctx, step, reason) do
    Events.emit(ctx, %StepSkipped{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage_name(ctx),
      step: step.name,
      reason: reason,
      matrix_combination: combination(ctx)
    })
  end

  defp stage_name(ctx), do: Map.get(ctx, :stage_name)

  # The matrix combination a step ran in, or nil outside a matrix stage. Step-scoped
  # events carry it so a fold can attribute them to the right combination.
  defp combination(ctx), do: Map.get(ctx, :matrix_combination)

  # Emits one `step_output` event for a single line. Returned as a closure so
  # `Output` can report shell output as it arrives, in production order.
  defp emit_line(context, step) do
    fn line -> emit_line(context, step, line) end
  end

  defp emit_line(context, step, line) do
    Events.emit(context, %StepOutputLine{
      run_id: run_id(context),
      timestamp: now(),
      stage: stage_name(context),
      step: step,
      line: line,
      matrix_combination: combination(context)
    })
  end

  # Module and crash output is known only when the step finishes; blank lines are
  # not events (matching the captured-output contract of `TinyCI.Runs.Projection`).
  defp emit_step_output(_context, _step, ""), do: :ok

  defp emit_step_output(context, step, output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.each(emit_line(context, step))
  end

  defp persist_step_artifacts(result, %{artifact: nil}, _ctx, _wd), do: result

  defp persist_step_artifacts(%{status: status} = result, _, _, _) when status != :passed,
    do: result

  defp persist_step_artifacts(result, %{artifact: artifact}, ctx, working_dir) do
    artifacts_dir = Map.get(ctx, :artifacts_dir)
    root = Map.get(ctx, :root, File.cwd!())
    src_base = working_dir || root

    cond do
      Execution.trust(ctx) == :untrusted ->
        # Artifact copy validates a tree and then copies it; a step can race a
        # symlink swap between those operations. An untrusted run therefore skips
        # artifact persistence entirely rather than exposing a host file read.
        result

      is_nil(artifacts_dir) ->
        result

      true ->
        persist_artifacts(result, artifact, src_base, artifacts_dir, ctx)
    end
  end

  defp persist_artifacts(result, artifact, src_base, artifacts_dir, ctx) do
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

      {:error, {:unsafe_path, name, path}} ->
        message = mask(ctx, "Unsafe path #{inspect(path)} in artifact #{inspect(name)}")
        %{result | status: :failed, output: result.output <> message}
    end
  end

  defp execute_with_cache(
         %{cache: nil} = step,
         context,
         output_mode,
         prefix,
         working_dir
       ) do
    run_step_with_retries(step, context, output_mode, prefix, working_dir)
  end

  defp execute_with_cache(
         %{cache: cache} = step,
         context,
         output_mode,
         prefix,
         working_dir
       ) do
    if Execution.trust(context) == :untrusted do
      # Cache restore/save are host-side file operations driven by repository
      # paths. An untrusted run does not get that host access; the step still
      # runs in its container, just without a cache.
      run_step_with_retries(step, context, output_mode, prefix, working_dir)
    else
      execute_with_trusted_cache(step, cache, context, output_mode, prefix, working_dir)
    end
  end

  defp execute_with_trusted_cache(
         step,
         cache,
         context,
         output_mode,
         prefix,
         working_dir
       ) do
    no_cache = Map.get(context, :no_cache, false)
    root = Map.get(context, :root, File.cwd!())
    key_file = Path.join(root, cache.key)

    inputs =
      %{
        command: step.cmd,
        module: step.module,
        env: cache_env(context, step),
        working_dir: working_dir,
        matrix: Map.get(context, :matrix_combination),
        paths: cache.paths
      }
      |> maybe_put_runtime(context, step)
      |> maybe_put_environment(context, step)

    with false <- no_cache,
         {:ok, key} <- Cache.compute_key(key_file, inputs) do
      cache_ctx = %{key: key, root: root, paths: cache.paths}
      run_cached(step, cache_ctx, context, output_mode, prefix, working_dir)
    else
      _ -> run_step_with_retries(step, context, output_mode, prefix, working_dir)
    end
  end

  # A shell step that runs in an image never sees the host environment, so its
  # key must not change when a host variable does. A module step always runs in
  # the runner's VM, even in an imaged stage, so it keeps the host environment
  # and the host runtime tuple.
  defp imaged_shell_step?(_context, %{cmd: nil}), do: false

  defp imaged_shell_step?(context, %{cmd: cmd}) when not is_nil(cmd) do
    case Map.get(context, :execution_environment) do
      %Environment{image: image} -> is_binary(image)
      _ -> false
    end
  end

  defp cache_env(context, step) do
    resolved = Env.resolve(context, step.env)

    if imaged_shell_step?(context, step),
      do: Env.process(context, resolved),
      else: Map.merge(System.get_env(), resolved)
  end

  # The image identity is the runtime for an imaged shell step; keeping the host
  # tuple would make an unchanged image miss after a runner upgrade.
  defp maybe_put_runtime(inputs, context, step) do
    if imaged_shell_step?(context, step),
      do: inputs,
      else: Map.put(inputs, :runtime, host_runtime())
  end

  # Only a shell step can run in the image, so only a shell step inherits the
  # image/toolchain identity. A nil identity (a plain host run) adds no input,
  # which keeps existing host cache keys unchanged.
  defp maybe_put_environment(inputs, context, step) do
    identity =
      if is_nil(step.cmd),
        do: nil,
        else: Environment.cache_identity(Map.get(context, :execution_environment))

    if identity, do: Map.put(inputs, :execution_environment, identity), else: inputs
  end

  defp host_runtime do
    {System.version(), :erlang.system_info(:system_version),
     :erlang.system_info(:system_architecture)}
  end

  defp run_cached(
         step,
         %{key: key, root: root, paths: paths},
         ctx,
         output_mode,
         prefix,
         wd
       ) do
    cache_status = Cache.restore_if_present(root, key, paths, wd)
    emit_cache_lookup(ctx, step.name, key, cache_status)

    if cache_status == :hit and is_nil(step.module) do
      %StepResult{name: step.name, status: :passed, duration_ms: 0, cache_status: :hit}
    else
      result = run_step_with_retries(step, ctx, output_mode, prefix, wd)
      if result.status == :passed, do: Cache.save(root, key, paths, wd)
      %{result | cache_status: cache_status}
    end
  end

  defp emit_cache_lookup(ctx, step, key, result) do
    Events.emit(ctx, %CacheLookup{
      run_id: run_id(ctx),
      timestamp: now(),
      stage: stage_name(ctx),
      step: step,
      key: key,
      result: result,
      matrix_combination: combination(ctx)
    })
  end

  defp run_step_with_retries(step, ctx, output_mode, prefix, working_dir) do
    total = (step.retry || 0) + 1
    delay = step.retry_delay || 0
    attempt_step(step, ctx, output_mode, prefix, working_dir, {1, total, delay, 0})
  end

  defp attempt_step(
         step,
         ctx,
         output_mode,
         prefix,
         working_dir,
         {attempt, total, delay, acc_ms}
       ) do
    if attempt > 1 do
      Events.emit(ctx, %StepRetrying{
        run_id: run_id(ctx),
        timestamp: now(),
        stage: stage_name(ctx),
        step: step.name,
        attempt: attempt,
        total: total,
        matrix_combination: combination(ctx)
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
        {attempt + 1, total, delay, total_ms}
      )
    else
      %{result | attempts: attempt, duration_ms: total_ms}
    end
  end

  defp sleep_between_attempts(0), do: :ok
  defp sleep_between_attempts(delay), do: Process.sleep(delay)

  defp skip_step?(%{when_condition: nil}, _context), do: false

  defp skip_step?(%{when_condition: f}, context) when is_function(f, 1),
    do: !f.(context)

  defp skip_step?(%{when_condition: ast}, context),
    do: !TinyCI.DSL.ConditionEval.eval(ast, context)

  defp execute_by_mode(%{steps: steps, working_dir: stage_wd} = stage, ctx, output_mode) do
    case effective_mode(stage, ctx) do
      :serial -> execute_serial(steps, stage_wd, ctx, output_mode)
      :parallel -> execute_parallel(steps, stage_wd, ctx, output_mode)
    end
  end

  # `--debug-serial` degrades a `mode: :parallel` stage to serial so steps are
  # reached in declaration order while breakpoints are armed.
  defp effective_mode(%{mode: :parallel}, ctx) do
    if serial_control?(ctx), do: :serial, else: :parallel
  end

  defp effective_mode(%{mode: mode}, _ctx), do: mode

  defp execute_serial(steps, stage_wd, context, output_mode) do
    root = Map.get(context, :root)

    {results, final_store} =
      Enum.reduce_while(Enum.with_index(steps), {[], context.store}, fn {step, index},
                                                                        {acc, current_store} ->
        ctx = Map.put(context, :store, current_store)
        effective_wd = resolve_working_dir(step.working_dir || stage_wd, root)

        step_result = execute_step_or_skip(step, ctx, output_mode, nil, effective_wd, index)

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

  defp execute_parallel(steps, stage_wd, context, output_mode) do
    prefix = if output_mode == :streaming, do: :step_name, else: nil
    caller_gl = Process.group_leader()
    root = Map.get(context, :root)

    tasks =
      Enum.map(Enum.with_index(steps), fn {step, index} ->
        step_prefix = if prefix == :step_name, do: to_string(step.name), else: nil
        effective_wd = resolve_working_dir(step.working_dir || stage_wd, root)

        Task.Supervisor.async_nolink(TinyCI.TaskSupervisor, fn ->
          Process.group_leader(self(), caller_gl)
          execute_step_or_skip(step, context, output_mode, step_prefix, effective_wd, index)
        end)
      end)

    step_results =
      tasks
      |> Task.yield_many(timeout: :infinity)
      |> Enum.zip_with(steps, fn
        {_task, {:ok, result}}, _step -> result
        {_task, {:exit, reason}}, step -> escaped_step_crash(context, step, reason)
      end)

    merged_store =
      Enum.reduce(step_results, context.store, fn result, store ->
        Map.merge(store, result.store_data)
      end)

    {step_results, merged_store}
  end

  # Defense in depth: the step boundary should have caught this inside the task.
  defp escaped_step_crash(ctx, step, reason) do
    crashed_step(ctx, step, Crash.format(:exit, reason, []))
  end

  defp run_step(%{cmd: cmd} = step, ctx, _output_mode, _prefix, working_dir)
       when cmd != nil do
    if working_dir != nil and not File.dir?(working_dir) and not container_session?(ctx) do
      missing_working_dir_result(step, working_dir)
    else
      run_shell_step(step, ctx, working_dir)
    end
  end

  defp run_step(
         %{module: module, name: name, config_block: block, allow_failure: allow_failure} = step,
         ctx,
         _output_mode,
         _prefix,
         _working_dir
       )
       when not is_nil(module) do
    ctx = Map.put(ctx, :env, Env.resolve(ctx, step.env))

    if Execution.trust(ctx) == :untrusted and
         TinyCI.Sandbox.Trust.classify(module, load: false) != :builtin do
      raise TinyCI.Execution.Error,
        message: driver_error_message({:untrusted_action, module}),
        reason: {:untrusted_action, module}
    end

    driver = Driver.select(module, ctx)
    driver_opts = Keyword.put(Driver.opts(ctx), :timeout, step.timeout)
    timeout = if driver == Driver.Inline, do: step.timeout

    callback = fn ->
      config = Value.resolve(if(block, do: block.(), else: []), ctx.store)
      driver.run(module, config, ctx, driver_opts)
    end

    {duration_ms, {outcome, captured}} =
      measure(fn -> Callback.run(callback, timeout) end)

    outcome =
      if outcome == {:error, :timeout},
        do: {:error, "Step timed out after #{step.timeout}ms"},
        else: outcome

    {status, store_data, output} = interpret_outcome(outcome)
    output = mask(ctx, captured <> output)
    emit_step_output(ctx, name, output)

    %StepResult{
      name: name,
      status: status,
      output: mask(ctx, output),
      duration_ms: duration_ms,
      allowed_failure: allow_failure and status == :failed,
      store_data: store_data
    }
  end

  defp missing_working_dir_result(%{name: name, allow_failure: allow_failure}, working_dir) do
    %StepResult{
      name: name,
      status: :failed,
      output: "Working directory not found: #{working_dir}",
      duration_ms: 0,
      allowed_failure: allow_failure
    }
  end

  defp container_session?(%{execution_session: %TinyCI.Execution.Session{backend: backend}}),
    do: backend == TinyCI.Execution.Backend.Container

  defp container_session?(_ctx), do: false

  defp run_shell_step(
         %{cmd: cmd, name: name, env: env, timeout: timeout, allow_failure: allow_failure},
         ctx,
         working_dir
       ) do
    session = Map.fetch!(ctx, :execution_session)

    command = %Command{
      run: {:shell, cmd},
      env: Env.process(ctx, Env.resolve(ctx, env)),
      working_dir: working_dir,
      timeout: timeout
    }

    live? = live_line_events?(ctx)
    on_line = if live?, do: emit_line(ctx, name), else: fn _line -> :ok end

    {duration_ms, {status, output}} =
      measure(fn -> run_command(session, command, on_line) end)

    masked = mask(ctx, output)
    # A secret containing a newline can only be masked against the whole
    # output, not line by line, so in that case the line events are emitted
    # from the masked result rather than live.
    if live?, do: :ok, else: emit_step_output(ctx, name, masked)

    %StepResult{
      name: name,
      status: status,
      output: masked,
      duration_ms: duration_ms,
      allowed_failure: allow_failure and status == :failed
    }
  end

  # Live per-line emission is only safe when no secret can span a line break:
  # `Output` (and the dispatcher) redact one line at a time, so a multi-line
  # secret would survive as fragments. With one present, emit from the whole
  # masked output instead.
  defp live_line_events?(ctx) do
    Enum.all?(secret_values(ctx), &(not (is_binary(&1) and String.contains?(&1, "\n"))))
  end

  # Results are masked at creation so `Results.to_json/2` and the reporter never
  # see a secret; the dispatcher masks the console and events.
  defp mask(ctx, output), do: Redaction.redact(output, secret_values(ctx))

  defp secret_values(ctx), do: Map.get(ctx, :secret_values, [])

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

  defp driver_error_message({:crashed, text}) when is_binary(text), do: text
  defp driver_error_message(reason) when is_binary(reason), do: reason
  defp driver_error_message(reason), do: inspect(reason)

  # The backend owns the deadline and has already killed the command's process
  # tree when it reports :timeout. A timed-out step is a failed step, and its
  # output is the existing human-readable deadline message.
  defp run_command(session, %Command{timeout: timeout} = command, on_line) do
    case Execution.exec(session, command, on_line) do
      {:timeout, _output} when is_integer(timeout) ->
        {:failed, "Step timed out after #{timeout}ms"}

      {:timeout, output} ->
        {:failed, output}

      outcome ->
        outcome
    end
  end

  defp measure(fun) do
    start = System.monotonic_time(:millisecond)
    result = fun.()
    finish = System.monotonic_time(:millisecond)
    {finish - start, result}
  end
end
