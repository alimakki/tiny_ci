defmodule TinyCI.DryRun do
  @moduledoc """
  Prints a dry-run plan of what a pipeline would execute without running anything.

  Evaluates stage conditions against the provided context to show which
  stages would be skipped and which would run, along with step details.
  """

  alias TinyCI.Stage

  @doc """
  Prints the execution plan for the given stages and context.

  Evaluates `when_condition` functions to determine skip/run status.
  Displays step commands, modules, timeouts, and execution modes.

  ## Parameters

    * `stages`  — a list of `%TinyCI.Stage{}` structs
    * `context` — the pipeline context map
  """
  @spec print_plan([Stage.t()], map()) :: :ok
  def print_plan([], context) do
    print_header(context)
    IO.puts("  No stages defined.")
    IO.puts("")
  end

  def print_plan(stages, context) do
    print_header(context)

    Enum.each(stages, fn stage ->
      print_stage(stage, context)
    end)

    IO.puts("")
  end

  defp print_header(context) do
    IO.puts("")
    IO.puts([IO.ANSI.bright(), "═══ Dry Run ═══", IO.ANSI.reset()])

    branch = Map.get(context, :branch, "unknown")
    commit = Map.get(context, :commit, "unknown")
    IO.puts("  Branch: #{branch} | Commit: #{commit}")
    IO.puts("")
  end

  defp print_stage(%Stage{} = stage, context) do
    skipped? = skip_stage?(stage, context)

    if skipped? do
      IO.puts([
        "  ",
        IO.ANSI.yellow(),
        "○ :#{stage.name}",
        IO.ANSI.reset(),
        " — will skip (condition not met)"
      ])
    else
      IO.puts([
        "  ",
        IO.ANSI.green(),
        "▶ :#{stage.name}",
        IO.ANSI.reset(),
        " (#{stage.mode})"
      ])

      Enum.each(stage.steps, &print_step/1)
    end
  end

  defp print_step(step) do
    type_info = step_type_info(step)
    timeout_info = if step.timeout, do: " [timeout: #{step.timeout}ms]", else: ""
    allow_failure_info = if step.allow_failure, do: " [allow_failure]", else: ""

    IO.puts("    • :#{step.name} — #{type_info}#{timeout_info}#{allow_failure_info}")
  end

  defp step_type_info(%{cmd: cmd}) when not is_nil(cmd), do: "cmd: #{inspect(cmd)}"
  defp step_type_info(%{module: mod}) when not is_nil(mod), do: "module: #{inspect(mod)}"
  defp step_type_info(_), do: "(no cmd or module)"

  defp skip_stage?(%{when_condition: nil}, _context), do: false

  defp skip_stage?(%{when_condition: f}, context) when is_function(f, 1),
    do: not f.(context)

  defp skip_stage?(%{when_condition: ast}, context),
    do: not TinyCI.DSL.ConditionEval.eval(ast, context)
end
