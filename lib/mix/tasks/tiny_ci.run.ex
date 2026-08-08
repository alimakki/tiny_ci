defmodule Mix.Tasks.TinyCi.Run do
  @shortdoc "Discovers and runs a TinyCI pipeline"

  @moduledoc """
  Discovers and executes a TinyCI pipeline definition file.

  ## Usage

      mix tiny_ci.run [NAME] [options]

  An optional `NAME` selects a pipeline by name from the `.tiny_ci/` directory.
  Slash-separated names resolve to nested files (e.g. `jobs/release` looks for
  `.tiny_ci/jobs/release.exs`).

  ## Options

    * `--file PATH` / `-f` — path to a specific pipeline file (skips discovery)
    * `--root DIR` / `-r` — project root directory (defaults to current directory)
    * `--dry-run` — show what would execute without running anything
    * `--list` — list all available pipelines in `.tiny_ci/` and exit
    * `--filter STAGES` — run only the named stage(s), comma-separated
    * `--output FORMAT` — output format: `json` for machine-readable output
    * `--events FILE` — write the structured run event stream as NDJSON to `FILE`
      (one JSON object per line); use `-` to write to stdout. See `docs/events.md`.
    * `--break SPEC` — pause at a step/stage boundary. Repeatable. `SPEC` is
      `before:STAGE`, `after:STAGE`, `before:STAGE.STEP`, or `after:STAGE.STEP`.
    * `--break-timeout MS` — auto-resolve a breakpoint after `MS` milliseconds, so a
      forgotten breakpoint cannot hang CI. Required when no interactive terminal is
      attached to answer the prompt.
    * `--break-timeout-action ACTION` — `abort` (default) or `continue` on timeout
    * `--debug-serial` — force serial scheduling while breakpoints are armed, for
      predictable stepping. Off by default: pausing one branch must not freeze the
      independent ones.

  ## Execution control

  A breakpoint pauses the process that reached the boundary, prints the resolved
  environment, working directory, store snapshot, git context, and matrix
  combination, and reads a command: `continue`, `skip`, `retry`, `abort`, or
  `set KEY VALUE`. `set`, a forced `skip`, and a forced `retry` mark the run
  **divergent** — it is no longer a CI result and `--attest` refuses to sign it.
  See `docs/execution-control.md`.

  ## Pipeline Selection

  Resolution order (first match wins):

    1. `--file PATH` — explicit path, no discovery
    2. `NAME` positional argument — loads `.tiny_ci/<NAME>.exs`
    3. Auto-discovery — checks `tiny_ci.exs`, then `.tiny_ci/pipeline.exs`

  ## Examples

      # Run the default pipeline
      mix tiny_ci.run

      # Run a named pipeline from .tiny_ci/
      mix tiny_ci.run deploy

      # Run a nested pipeline from .tiny_ci/jobs/release.exs
      mix tiny_ci.run jobs/release

      # List all available pipelines
      mix tiny_ci.run --list

      # Preview a named pipeline without executing
      mix tiny_ci.run deploy --dry-run

      # Machine-readable JSON output
      mix tiny_ci.run --output json

      # Write the structured event stream as NDJSON
      mix tiny_ci.run --events run.ndjson
      mix tiny_ci.run --events -            # to stdout

      # Pause before the deploy stage and after a specific step
      mix tiny_ci.run --break before:deploy
      mix tiny_ci.run --break after:test.unit --debug-serial

      # Headless: give up on a breakpoint after 30s and abort
      mix tiny_ci.run --break before:deploy --break-timeout 30000

  ## Exit Codes

    * `0` — pipeline completed successfully (or `--list` / `--dry-run`)
    * `1` — pipeline failed, was aborted through execution control, or no pipeline
      file was found
  """

  use Mix.Task

  alias TinyCI.{Artifacts, Discovery, DryRun, Executor, Hooks, Provenance, Reporter, Results}
  alias TinyCI.Action.Audit
  alias TinyCI.Control
  alias TinyCI.Listener

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [
          file: :string,
          root: :string,
          dry_run: :boolean,
          list: :boolean,
          filter: :string,
          output: :string,
          no_cache: :boolean,
          artifacts_dir: :string,
          list_artifacts: :boolean,
          events: :string,
          attest: :string,
          signing_key: :string,
          break: :keep,
          break_timeout: :integer,
          break_timeout_action: :string,
          debug_serial: :boolean
        ],
        aliases: [f: :file, r: :root]
      )

    root = opts[:root] || File.cwd!()
    name = List.first(positional)
    filter = parse_filter(opts[:filter])

    result =
      cond do
        opts[:list] -> list_available_pipelines(root)
        opts[:list_artifacts] -> list_artifacts(root, opts[:artifacts_dir])
        true -> run_or_error(opts, root, name, filter)
      end

    maybe_halt(result)
    result
  end

  defp maybe_halt(:ok), do: halt_unless_test(0)
  defp maybe_halt({:error, _}), do: halt_unless_test(1)

  defp halt_unless_test(code) do
    if Mix.env() != :test, do: System.halt(code)
  end

  defp parse_output_format(nil), do: {:ok, :human}
  defp parse_output_format("json"), do: {:ok, :json}

  defp parse_output_format(other) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Unknown --output format: #{inspect(other)}.",
      IO.ANSI.reset(),
      " Supported formats: json"
    ])

    {:error, :no_pipeline}
  end

  defp resolve_pipeline(opts, root, name, output_format) do
    cond do
      opts[:file] ->
        Discovery.load_pipeline(opts[:file])

      name ->
        case Discovery.find_pipeline_by_name(root, name) do
          {:ok, path} -> load_and_announce(path, output_format)
          {:error, :not_found} -> {:error, {:named_not_found, name}}
        end

      true ->
        discover_and_load(root, output_format)
    end
  end

  defp discover_and_load(root, output_format) do
    with {:ok, path} <- Discovery.find_pipeline(root) do
      load_and_announce(path, output_format)
    end
  end

  defp load_and_announce(path, output_format) do
    with {:ok, spec} <- Discovery.load_pipeline(path) do
      if output_format != :json, do: IO.puts("Found pipeline: #{path}")
      {:ok, spec}
    end
  end

  defp list_available_pipelines(root) do
    case Discovery.list_pipelines(root) do
      [] ->
        IO.puts("No pipelines found in .tiny_ci/")

      pipelines ->
        IO.puts("Available pipelines:")

        Enum.each(pipelines, fn {name, path} ->
          IO.puts("  #{name}  #{path}")
        end)
    end

    :ok
  end

  defp run_or_error(opts, root, name, filter) do
    with {:ok, output_format} <- parse_output_format(opts[:output]) do
      case resolve_pipeline(opts, root, name, output_format) do
        {:ok, spec} -> run_resolved(spec, opts, root, filter, output_format)
        {:error, reason} -> handle_error(reason)
      end
    end
  end

  defp run_resolved(spec, opts, root, filter, output_format) do
    # Anchor working_dir/artifact/cache resolution to the project root the user
    # invoked from, not the pipeline file's own directory. Otherwise a pipeline in
    # `.tiny_ci/` would resolve relative paths against `.tiny_ci/` rather than the
    # repo root.
    spec = %{spec | root: Path.expand(root)}

    with :ok <- verify_actions(spec, opts[:dry_run]),
         {:ok, control} <- resolve_control(opts, spec, output_format) do
      run_and_attest(spec, opts, root, filter, output_format, control)
    else
      {:error, reason} -> handle_error(reason)
    end
  end

  # Runs the pipeline and, when `--attest` is given, writes a signed provenance
  # attestation built from the run's event stream (skipped for --dry-run).
  defp run_and_attest(spec, opts, root, filter, output_format, control) do
    attest_path = if opts[:dry_run], do: nil, else: opts[:attest]
    {run_opts, agent} = maybe_collector(base_run_opts(opts, control), attest_path)

    result = run_with_filter(spec, opts[:dry_run], filter, output_format, run_opts)

    finalize_attest(agent, attest_path, spec, opts, root, result)
  end

  defp base_run_opts(opts, control) do
    [
      no_cache: opts[:no_cache] || false,
      artifacts_dir: opts[:artifacts_dir],
      events: opts[:events],
      control: control
    ]
  end

  # ---------------------------------------------------------------------------
  # Execution control (T10)
  # ---------------------------------------------------------------------------

  # Everything about `--break` is settled here, before a single step runs: specs
  # parse, targets exist, and there is *something* that will eventually release the
  # pause. A typo or a missing driver must never cost a whole run.
  defp resolve_control(opts, spec, output_format) do
    case Keyword.get_values(opts, :break) do
      [] -> {:ok, nil}
      specs -> build_control(specs, opts, spec, output_format)
    end
  end

  defp build_control(specs, opts, spec, output_format) do
    with {:ok, breakpoints} <- parse_breakpoints(specs),
         :ok <- validate_breakpoints(breakpoints, spec.stages),
         {:ok, action} <- parse_timeout_action(opts[:break_timeout_action]),
         {:ok, subscribers, interactive?} <- start_control_driver(output_format),
         {:ok, timeout} <- resolve_break_timeout(opts[:break_timeout], interactive?) do
      {:ok,
       [
         breakpoints: breakpoints,
         timeout: timeout,
         timeout_action: action,
         subscribers: subscribers,
         serial: opts[:debug_serial] || false
       ]}
    end
  end

  defp parse_breakpoints(specs) do
    {parsed, errors} =
      Enum.reduce(specs, {[], []}, fn spec, {ok, errors} ->
        case Control.Breakpoint.parse(spec) do
          {:ok, breakpoint} -> {[breakpoint | ok], errors}
          {:error, message} -> {ok, [message | errors]}
        end
      end)

    if errors == [],
      do: {:ok, Enum.reverse(parsed)},
      else: {:error, {:breakpoints, Enum.reverse(errors)}}
  end

  defp validate_breakpoints(breakpoints, stages) do
    case Control.Breakpoint.validate(breakpoints, stages) do
      :ok -> :ok
      {:error, errors} -> {:error, {:breakpoints, errors}}
    end
  end

  defp parse_timeout_action(nil), do: {:ok, :abort}
  defp parse_timeout_action("abort"), do: {:ok, :abort}
  defp parse_timeout_action("continue"), do: {:ok, :continue}
  defp parse_timeout_action(other), do: {:error, {:break_timeout_action, other}}

  # The terminal REPL only makes sense when a human is at an ANSI terminal and
  # stdout is not already committed to machine-readable JSON.
  defp start_control_driver(:json), do: {:ok, [], false}

  defp start_control_driver(_human) do
    if IO.ANSI.enabled?() do
      {:ok, driver} = Control.Console.start_link()
      {:ok, [driver], true}
    else
      {:ok, [], false}
    end
  end

  # Without an interactive driver something else must release the pause. Rather
  # than guess a default that silently changes CI behaviour, demand the timeout
  # explicitly — this is the "a forgotten breakpoint can't hang CI" guarantee.
  defp resolve_break_timeout(nil, true), do: {:ok, :infinity}
  defp resolve_break_timeout(nil, false), do: {:error, :break_timeout_required}
  defp resolve_break_timeout(ms, _interactive?) when is_integer(ms) and ms > 0, do: {:ok, ms}
  defp resolve_break_timeout(ms, _interactive?), do: {:error, {:break_timeout, ms}}

  defp maybe_collector(run_opts, nil), do: {run_opts, nil}

  defp maybe_collector(run_opts, _attest_path) do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {run_opts ++ [extra_sinks: [{Provenance.Collector, agent: agent}]], agent}
  end

  defp finalize_attest(nil, _path, _spec, _opts, _root, result), do: result

  defp finalize_attest(agent, path, spec, opts, root, result) do
    events = Provenance.Collector.events(agent)
    Agent.stop(agent)

    case write_attestation(path, spec, opts, root, events) do
      # A pipeline failure dominates; otherwise a failed attestation surfaces.
      :ok -> result
      {:error, _} = attest_error -> if result == :ok, do: attest_error, else: result
    end
  end

  defp write_attestation(path, spec, opts, root, events) do
    with :ok <- refuse_divergent(events),
         {:ok, private} <- signing_key(opts),
         {:ok, actions} <- Audit.analyze(spec, root, root_app: Mix.Project.config()[:app]),
         ctx = TinyCI.Context.build(root: root),
         statement =
           Provenance.build(
             events: events,
             spec: spec,
             actions: actions,
             commit: ctx.commit,
             branch: ctx.branch,
             tool_version: to_string(Mix.Project.config()[:version])
           ),
         {:ok, envelope} <- Provenance.Attestation.sign(statement, private: private),
         :ok <- File.write(path, Jason.encode!(envelope, pretty: true)) do
      IO.puts(:stderr, "Wrote signed attestation to #{path}")
      :ok
    else
      {:error, reason} ->
        print_error({:attestation, reason})
        {:error, :attestation_failed}
    end
  end

  # Cross-cutting invariant 5: a run a human steered by hand records what an
  # operator made happen, not what the pipeline does. Signing it would launder a
  # manual result into a supply-chain claim.
  defp refuse_divergent(events) do
    if Provenance.divergent?(events), do: {:error, :divergent_run}, else: :ok
  end

  defp signing_key(opts) do
    cond do
      path = opts[:signing_key] -> read_signing_key(path)
      key = System.get_env("TINY_CI_SIGNING_KEY") -> {:ok, String.trim(key)}
      true -> {:error, :no_signing_key}
    end
  end

  defp read_signing_key(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, _} -> {:error, {:key_unreadable, path}}
    end
  end

  # Supply-chain gate: before executing, verify every module action is pinned in
  # the lockfile and matches the locked version (T6). Skipped for --dry-run.
  defp verify_actions(_spec, true), do: :ok

  defp verify_actions(spec, _dry_run) do
    Audit.verify(spec, spec.root, root_app: Mix.Project.config()[:app])
  end

  defp run_with_filter(spec, dry_run, filter, output_format, run_opts) do
    with :ok <- validate_filter(filter, spec.stages) do
      dispatch_pipeline(spec, dry_run, filter, output_format, run_opts)
    end
  end

  defp dispatch_pipeline(spec, true, filter, _output_format, _run_opts),
    do: dry_run_pipeline(spec, filter)

  defp dispatch_pipeline(spec, _, filter, output_format, run_opts),
    do: execute_pipeline(spec, filter, output_format, run_opts)

  defp handle_error(reason) do
    print_error(reason)
    {:error, :no_pipeline}
  end

  defp parse_filter(nil), do: nil

  defp parse_filter(filter_str) do
    filter_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn
      ":" <> name -> String.to_atom(name)
      name -> String.to_atom(name)
    end)
  end

  defp validate_filter(nil, _stages), do: :ok
  defp validate_filter([], _stages), do: :ok

  defp validate_filter(filter, stages) do
    stage_names = MapSet.new(stages, & &1.name)
    unknown = Enum.reject(filter, &MapSet.member?(stage_names, &1))

    if unknown == [] do
      :ok
    else
      available = Enum.map_join(stages, ", ", fn s -> ":#{s.name}" end)
      unknown_str = Enum.map_join(unknown, ", ", &":#{&1}")

      IO.puts(:stderr, [
        IO.ANSI.red(),
        "Unknown stage filter: #{unknown_str}.",
        IO.ANSI.reset(),
        " Available stages: #{available}"
      ])

      {:error, :no_pipeline}
    end
  end

  defp dry_run_pipeline(
         %TinyCI.PipelineSpec{stages: stages, root: root, env: pipeline_env},
         filter
       ) do
    context = TinyCI.Context.build(root: root, pipeline_env: pipeline_env)
    filtered = filter_stages(stages, filter)
    DryRun.print_plan(filtered, context)
    :ok
  end

  defp execute_pipeline(
         %TinyCI.PipelineSpec{
           name: name,
           stages: stages,
           hooks: hooks,
           root: root,
           env: pipeline_env
         },
         filter,
         :json,
         run_opts
       ) do
    context = TinyCI.Context.build(root: root, pipeline_env: pipeline_env)

    pipeline_result =
      Executor.run_pipeline(
        stages,
        context,
        Keyword.merge(run_opts,
          filter: filter,
          output: :buffered,
          listener: Listener.Silent,
          pipeline_name: name
        )
      )

    stage_results = extract_stage_results(pipeline_result)

    IO.puts(Results.to_json(simplify_result(pipeline_result), stage_results))
    Hooks.run_hooks(hooks, hook_event(pipeline_result), context)

    case pipeline_result do
      {:ok, _} -> :ok
      {:error, _, _} -> {:error, :pipeline_failed}
    end
  end

  defp execute_pipeline(
         %TinyCI.PipelineSpec{
           name: name,
           stages: stages,
           hooks: hooks,
           root: root,
           env: pipeline_env
         },
         filter,
         :human,
         run_opts
       ) do
    context = TinyCI.Context.build(root: root, pipeline_env: pipeline_env)

    run_opts = Keyword.merge(run_opts, filter: filter, pipeline_name: name)

    case Executor.run_pipeline(stages, context, run_opts) do
      {:ok, stage_results} ->
        Reporter.print_summary(stage_results)
        Hooks.run_hooks(hooks, :on_success, context)
        IO.puts([IO.ANSI.green(), "Pipeline completed successfully.", IO.ANSI.reset()])
        :ok

      {:error, reason, stage_results} ->
        Reporter.print_summary(stage_results)
        Hooks.run_hooks(hooks, :on_failure, context)
        IO.puts(:stderr, [IO.ANSI.red(), failure_message(reason), IO.ANSI.reset()])
        {:error, :pipeline_failed}
    end
  end

  defp failure_message({:aborted, stage}),
    do: "Pipeline aborted by execution control at stage :#{stage}."

  defp failure_message(_reason), do: "Pipeline failed."

  defp list_artifacts(root, artifacts_dir_override) do
    base_root = artifacts_dir_override || root

    case Artifacts.list_runs(base_root) do
      [] -> IO.puts("No artifacts found.")
      runs -> print_last_run_artifacts(base_root, List.last(runs))
    end

    :ok
  end

  defp print_last_run_artifacts(base_root, {last_run_id, artifact_names}) do
    IO.puts("Artifacts from last run (#{last_run_id}):")
    print_artifact_names(base_root, last_run_id, artifact_names)
  end

  defp print_artifact_names(_base_root, _run_id, []) do
    IO.puts("  (none)")
  end

  defp print_artifact_names(base_root, run_id, names) do
    run_dir = Artifacts.run_artifacts_dir(base_root, run_id)
    Enum.each(names, fn name -> IO.puts("  #{name}: #{Path.join(run_dir, name)}") end)
  end

  defp extract_stage_results({:ok, results}), do: results
  defp extract_stage_results({:error, _, results}), do: results

  defp simplify_result({:ok, _}), do: :ok
  defp simplify_result({:error, reason, _}), do: {:error, reason}

  defp hook_event({:ok, _}), do: :on_success
  defp hook_event({:error, _, _}), do: :on_failure

  defp filter_stages(stages, nil), do: stages
  defp filter_stages(stages, []), do: stages

  defp filter_stages(stages, filter) do
    filter_set = MapSet.new(filter)
    Enum.filter(stages, &MapSet.member?(filter_set, &1.name))
  end

  defp print_error(:not_found) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "No pipeline file found. ",
      IO.ANSI.reset(),
      "Expected tiny_ci.exs or .tiny_ci/pipeline.exs"
    ])
  end

  defp print_error(:file_not_found) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Pipeline file not found.",
      IO.ANSI.reset()
    ])
  end

  defp print_error({:parse_error, message}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Failed to parse pipeline: ",
      IO.ANSI.reset(),
      message
    ])
  end

  defp print_error({:validation_error, violations}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Invalid pipeline file:", IO.ANSI.reset()])

    Enum.each(violations, fn v ->
      IO.puts(:stderr, "  • #{v}")
    end)
  end

  defp print_error({:named_not_found, name}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Pipeline not found: ",
      IO.ANSI.reset(),
      "#{name} (looked for .tiny_ci/#{name}.exs)"
    ])
  end

  defp print_error({:circular_dependency, cycle}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Circular dependency detected:", IO.ANSI.reset()])

    IO.puts(:stderr, "  Stages involved: #{Enum.map_join(cycle, ", ", &":#{&1}")}")
  end

  defp print_error({:unknown_stages, errors}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Unknown stage references:", IO.ANSI.reset()])
    Enum.each(errors, fn e -> IO.puts(:stderr, "  • #{e}") end)
  end

  defp print_error({:invalid_action, errors}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Invalid module step or hook:", IO.ANSI.reset()])
    Enum.each(errors, fn e -> IO.puts(:stderr, "  • #{e}") end)
  end

  defp print_error({:action_lock, errors}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Action supply-chain check failed:", IO.ANSI.reset()])
    Enum.each(errors, fn e -> IO.puts(:stderr, "  • #{e}") end)
    IO.puts(:stderr, "Run `mix tiny_ci.actions.audit` to inspect the resolved action tree.")
  end

  defp print_error({:breakpoints, errors}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Invalid --break:", IO.ANSI.reset()])
    Enum.each(errors, fn e -> IO.puts(:stderr, "  • #{e}") end)
  end

  defp print_error({:break_timeout_action, value}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Unknown --break-timeout-action: #{inspect(value)}.",
      IO.ANSI.reset(),
      " Supported actions: abort, continue"
    ])
  end

  defp print_error({:break_timeout, value}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Invalid --break-timeout: #{inspect(value)}.",
      IO.ANSI.reset(),
      " Expected a positive number of milliseconds."
    ])
  end

  defp print_error(:break_timeout_required) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Refusing to arm --break with nothing to release it.",
      IO.ANSI.reset(),
      "\n  No interactive terminal is attached (non-TTY, or --output json), so the\n",
      "  breakpoint prompt cannot be answered. Pass --break-timeout MS so the run\n",
      "  cannot hang, or attach a control driver via TinyCI.Control.subscribe/1."
    ])
  end

  defp print_error({:attestation, :divergent_run}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Refusing to attest a divergent run.",
      IO.ANSI.reset(),
      "\n  Execution control altered this run (set_store, or a forced skip/retry), so\n",
      "  it records what an operator made happen rather than what the pipeline does.\n",
      "  Re-run without --break to produce an attestable result."
    ])
  end

  defp print_error({:attestation, :no_signing_key}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Cannot write attestation: no signing key.",
      IO.ANSI.reset(),
      " Pass --signing-key PATH or set TINY_CI_SIGNING_KEY. ",
      "Generate one with `mix tiny_ci.attest.gen_key`."
    ])
  end

  defp print_error({:attestation, reason}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Failed to write attestation: ",
      IO.ANSI.reset(),
      inspect(reason)
    ])
  end

  defp print_error(reason) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Error: #{inspect(reason)}",
      IO.ANSI.reset()
    ])
  end
end
