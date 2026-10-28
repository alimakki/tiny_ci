defmodule TinyCI.DryRun do
  @moduledoc """
  Prints a dry-run plan of what a pipeline would execute without running anything.

  Evaluates stage conditions against the provided context to show which
  stages would be skipped and which would run, along with step details.
  """

  alias TinyCI.{DAG, Environment, Execution, Matrix, Stage}

  @doc """
  Prints the execution plan for the given stages and context.

  Evaluates `when_condition` functions to determine skip/run status.
  Displays step commands, modules, timeouts, and execution modes.

  The third argument is an optional `TinyCI.Environment.plan/3` result. Without
  one, a default plan is built that neither pulls images nor requires a
  container runtime, so `--dry-run` cannot change the machine. Stages whose
  environment is the plain host are printed exactly as before; an image or a
  named toolchain adds one `Environment:` line.

  ## Parameters

    * `stages`  — a list of `%TinyCI.Stage{}` structs
    * `context` — the pipeline context map
    * `plan`    — an optional environment plan (default: resolved without pull)
  """
  @spec print_plan([Stage.t()], map(), map() | nil) :: :ok
  def print_plan(stages, context, plan \\ nil)

  def print_plan([], context, _plan) do
    print_header(context)
    IO.puts("  No stages defined.")
    IO.puts("")
  end

  def print_plan(stages, context, nil) do
    print_plan(stages, context, default_plan(stages, context))
  end

  def print_plan(stages, context, plan) do
    print_header(context)

    if DAG.dag_mode?(stages) do
      print_dag_plan(stages, context, plan)
    else
      Enum.each(stages, &print_stage(&1, context, plan))
    end

    IO.puts("")
  end

  # Dry runs never pull and never require a runtime: inspecting a plan must be
  # side-effect free and work on a machine that has no container runtime.
  defp default_plan(stages, context) do
    Environment.plan(stages, context,
      pipeline_image: Map.get(context, :pipeline_image),
      pipeline_environment: Map.get(context, :pipeline_environment),
      pull: false,
      check_availability: false
    )
  end

  defp print_dag_plan(stages, context, plan) do
    case DAG.build_levels(stages) do
      {:ok, levels} ->
        levels
        |> Enum.with_index(1)
        |> Enum.each(&print_dag_level(&1, context, plan))

      {:error, {:circular_dependency, cycle}} ->
        IO.puts([
          IO.ANSI.red(),
          "  ✗ Circular dependency detected: #{inspect(cycle)}",
          IO.ANSI.reset()
        ])

      {:error, {:unknown_stages, errors}} ->
        Enum.each(errors, fn e ->
          IO.puts([IO.ANSI.red(), "  ✗ #{e}", IO.ANSI.reset()])
        end)
    end
  end

  defp print_dag_level({level, idx}, context, plan) do
    names = Enum.map_join(level, ", ", fn s -> ":#{s.name}" end)
    IO.puts([IO.ANSI.cyan(), "  [level #{idx}] #{names}", IO.ANSI.reset()])
    Enum.each(level, &print_stage(&1, context, plan))
  end

  defp print_header(context) do
    IO.puts("")
    IO.puts([IO.ANSI.bright(), "═══ Dry Run ═══", IO.ANSI.reset()])

    branch = Map.get(context, :branch, "unknown")
    commit = Map.get(context, :commit, "unknown")
    IO.puts("  Branch: #{branch} | Commit: #{commit}#{base_info(context)}")

    # Names only — a dry run must never print a secret value.
    case Map.get(context, :secret_names, []) do
      [] -> :ok
      names -> IO.puts("  Secrets: #{Enum.join(names, ", ")}")
    end

    pipeline_env = Map.get(context, :pipeline_env, %{})

    unless map_size(pipeline_env) == 0 do
      IO.puts("  Env: #{format_env(pipeline_env)}")
    end

    IO.puts("")
  end

  # The base is what `file_changed?` was evaluated against, so the plan can be
  # checked. The parenthesised SHA is the merge base actually diffed from.
  defp base_info(%{base_ref: nil}), do: " | Base: (none — initial commit)"

  defp base_info(%{base_ref: base} = context) do
    root = Map.get(context, :root) || File.cwd!()

    case TinyCI.Context.merge_base(root, base) do
      nil -> " | Base: #{base}"
      sha -> " | Base: #{base} (#{String.slice(sha, 0, 7)})"
    end
  end

  defp base_info(_context), do: ""

  defp print_stage(%Stage{} = stage, context, plan) do
    context = Map.put(context, :stage_env, stage.env)
    skipped? = Stage.skipped?(stage, context)
    root = Map.get(context, :root)

    if skipped? do
      IO.puts([
        "  ",
        IO.ANSI.yellow(),
        "○ :#{stage.name}",
        IO.ANSI.reset(),
        " — will skip (condition not met)"
      ])
    else
      needs_info =
        case stage.needs do
          [] -> ""
          names -> " [needs: #{Enum.map_join(names, ", ", &":#{&1}")}]"
        end

      matrix_info =
        case stage.matrix do
          [] -> ""
          spec -> " [matrix: #{length(Matrix.combinations(spec))} combinations]"
        end

      IO.puts([
        "  ",
        IO.ANSI.green(),
        "▶ :#{stage.name}",
        IO.ANSI.reset(),
        " (#{stage.mode})#{needs_info}#{matrix_info}"
      ])

      unless map_size(stage.env) == 0 do
        IO.puts("    Env: #{format_env(stage.env)}")
      end

      print_environment(stage, plan)

      if stage.matrix != [] do
        print_matrix_combinations(stage.matrix)
      end

      Enum.each(stage.steps, &print_step(&1, stage.working_dir, root, context))
    end
  end

  # A plain host stage prints nothing extra: the dry-run output for existing
  # pipelines is byte-identical.
  defp print_environment(stage, plan) do
    case Map.get(plan.stages, stage.name) do
      nil ->
        :ok

      {:ok, env} ->
        print_resolved_environment(env)

      {:error, reason} ->
        IO.puts([
          "    ",
          IO.ANSI.yellow(),
          "Environment: unresolved — #{Execution.error_message(reason)}",
          IO.ANSI.reset()
        ])
    end
  end

  defp print_resolved_environment(%Environment{image: image} = env) when is_binary(image) do
    IO.puts("    Environment: container image=#{image} digest=#{env.digest || "unresolved"}")
  end

  defp print_resolved_environment(%Environment{toolchain: name} = env) when is_binary(name) do
    tools = Enum.map_join(env.tools, ", ", fn {tool, version} -> "#{tool} #{version}" end)
    IO.puts("    Environment: host environment=#{name} (#{tools})")
  end

  defp print_resolved_environment(_env), do: :ok

  defp print_matrix_combinations(matrix_spec) do
    IO.puts("    Combinations:")
    matrix_spec |> Matrix.combinations() |> Enum.each(&print_combination/1)
  end

  defp print_combination(combo) do
    IO.puts("      • #{Matrix.label(combo)}")
  end

  defp print_step(step, stage_wd, root, context) do
    context = Map.put(context, :env, TinyCI.Executor.Env.resolve(context, step.env))

    if skip_step?(step, context) do
      IO.puts([
        "    ",
        IO.ANSI.yellow(),
        "○ :#{step.name}",
        IO.ANSI.reset(),
        " — will skip (condition not met)"
      ])
    else
      type_info = step_type_info(step)
      timeout_info = if step.timeout, do: " [timeout: #{step.timeout}ms]", else: ""
      allow_failure_info = if step.allow_failure, do: " [allow_failure]", else: ""
      retry_info = format_retry_info(step.retry, step.retry_delay)
      cache_info = format_cache_info(step.cache)
      artifact_info = format_artifact_info(step.artifact, context)

      wd_info =
        case resolve_working_dir(step.working_dir || stage_wd, root) do
          nil -> ""
          dir -> " [working_dir: #{dir}]"
        end

      IO.puts(
        "    • :#{step.name} — #{type_info}#{timeout_info}#{allow_failure_info}#{retry_info}#{cache_info}#{artifact_info}#{wd_info}"
      )
    end
  end

  defp step_type_info(%{cmd: cmd}) when not is_nil(cmd), do: "cmd: #{inspect(cmd)}"
  defp step_type_info(%{module: mod}) when not is_nil(mod), do: "module: #{inspect(mod)}"
  defp step_type_info(_), do: "(no cmd or module)"

  defp skip_step?(%{when_condition: nil}, _context), do: false

  defp skip_step?(%{when_condition: f}, context) when is_function(f, 1),
    do: !f.(context)

  defp skip_step?(%{when_condition: ast}, context),
    do: !TinyCI.DSL.ConditionEval.eval(ast, context)

  defp format_retry_info(nil, _), do: ""
  defp format_retry_info(0, _), do: ""
  defp format_retry_info(r, nil), do: " [retry: #{r}]"
  defp format_retry_info(r, 0), do: " [retry: #{r}]"
  defp format_retry_info(r, d), do: " [retry: #{r}, retry_delay: #{d}ms]"

  defp format_cache_info(nil), do: ""

  defp format_cache_info(%{paths: paths, key: key}) do
    paths_str = Enum.join(paths, ", ")
    " [cache: key=#{key}, paths=[#{paths_str}]]"
  end

  defp format_artifact_info(nil, _context), do: ""

  defp format_artifact_info(%{name: name, paths: paths, required: required}, context) do
    root = Map.get(context, :root, File.cwd!())
    run_id = Map.get(context, :run_id, "<run_id>")
    artifact_dir = TinyCI.Artifacts.run_artifacts_dir(root, run_id)
    resolved = Path.join(artifact_dir, name)
    required_str = if required, do: ", required", else: ""
    paths_str = Enum.join(paths, ", ")
    " [artifact: name=#{name}, paths=[#{paths_str}]#{required_str}, dest=#{resolved}]"
  end

  defp format_env(env) do
    Enum.map_join(env, ", ", fn {k, v} -> "#{k}=#{v}" end)
  end

  defp resolve_working_dir(nil, _root), do: nil

  defp resolve_working_dir(dir, root) do
    if Path.type(dir) == :absolute, do: dir, else: Path.join(root || File.cwd!(), dir)
  end
end
