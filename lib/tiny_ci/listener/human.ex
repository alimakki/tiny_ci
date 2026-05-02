defmodule TinyCI.Listener.Human do
  @moduledoc """
  Human-readable pipeline progress output.

  Prints stage headers, skip messages, buffered step output, matrix combination
  results, and retry attempt notices to stdout.
  """

  @behaviour TinyCI.Listener

  alias TinyCI.{Matrix, MatrixRunResult, Reporter, StepResult}

  @impl TinyCI.Listener
  def stage_started(name), do: IO.puts("Stage: #{name}")

  @impl TinyCI.Listener
  def stage_skipped(_name, :condition_not_met), do: IO.puts("  Skipped (condition not met)")
  def stage_skipped(_name, :dependency_failed), do: IO.puts("  Skipped (dependency failed)")

  @impl TinyCI.Listener
  def stage_finished(result), do: Reporter.print_step_output(result)

  @impl TinyCI.Listener
  def matrix_stage_finished(run_results), do: Enum.each(run_results, &print_combination_output/1)

  @impl TinyCI.Listener
  def step_attempt(_attempt, 1), do: :ok
  def step_attempt(attempt, total), do: IO.puts("  [attempt #{attempt}/#{total}]")

  defp print_combination_output(%MatrixRunResult{combination: combo, step_results: results}) do
    label = Matrix.label(combo)
    Enum.each(results, &print_combo_step(&1, label))
  end

  defp print_combo_step(%StepResult{name: name, output: output}, label) do
    if output != "", do: IO.puts("  [#{label}][#{name}] #{String.trim(output)}")
  end
end
