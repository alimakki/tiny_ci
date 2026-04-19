defmodule TinyCI.Reporter do
  @moduledoc """
  Formats and prints pipeline execution results.

  Provides a human-readable summary of stage and step outcomes
  including pass/fail/skip status and wall-clock duration.
  """

  alias TinyCI.{StageResult, StepResult}

  @doc """
  Prints a formatted pipeline summary to stdout.

  Shows each stage with its steps, their status (passed/failed/skipped),
  and duration. Uses ANSI colors when the terminal supports them.

  ## Parameters

    * `stage_results` — a list of `%TinyCI.StageResult{}` structs
  """
  @spec print_summary([StageResult.t()]) :: :ok
  def print_summary([]) do
    IO.puts("")
    IO.puts(header("Pipeline Summary"))
    IO.puts("  No stages executed.")
    IO.puts("")
  end

  def print_summary(stage_results) do
    IO.puts("")
    IO.puts(header("Pipeline Summary"))

    Enum.each(stage_results, &print_stage/1)

    total_duration = Enum.reduce(stage_results, 0, &(&1.duration_ms + &2))

    IO.puts(
      "  Total: #{format_duration(total_duration)} | Result: #{colorize_status(pipeline_status(stage_results))}"
    )

    IO.puts("")
  end

  @doc """
  Prints buffered step output for a stage, preserving step order.

  Each step's captured output is printed under a labeled header
  so parallel output appears grouped by step, not interleaved.

  ## Parameters

    * `stage_result` — a `%TinyCI.StageResult{}` struct
  """
  @spec print_step_output(StageResult.t()) :: :ok
  def print_step_output(%StageResult{step_results: step_results}) do
    Enum.each(step_results, fn %StepResult{name: name, output: output} ->
      if output != "" do
        IO.puts("  [#{name}] #{String.trim(output)}")
      end
    end)
  end

  @doc """
  Formats a duration in milliseconds to a human-readable string.

  Durations under 1000ms are shown as "Nms". Durations at or above
  1000ms are shown as "N.Ns" with one decimal place.

  ## Examples

      iex> TinyCI.Reporter.format_duration(500)
      "500ms"

      iex> TinyCI.Reporter.format_duration(2500)
      "2.5s"
  """
  @spec format_duration(non_neg_integer()) :: String.t()
  def format_duration(ms) when ms < 1000, do: "#{ms}ms"

  def format_duration(ms) do
    seconds = ms / 1000
    "#{:erlang.float_to_binary(seconds, decimals: 1)}s"
  end

  @doc """
  Determines the overall pipeline status from a list of stage results.

  Returns `:failed` if any stage failed, otherwise `:passed`.

  ## Parameters

    * `stage_results` — a list of `%TinyCI.StageResult{}` structs
  """
  @spec pipeline_status([StageResult.t()]) :: :passed | :failed
  def pipeline_status(stage_results) do
    if Enum.any?(stage_results, &(&1.status == :failed)), do: :failed, else: :passed
  end

  defp header(text) do
    [IO.ANSI.bright(), "═══ #{text} ═══", IO.ANSI.reset()]
  end

  defp print_stage(%StageResult{} = stage) do
    IO.puts(
      "  #{status_icon(stage.status)} #{stage.name} — #{colorize_status(stage.status)} (#{format_duration(stage.duration_ms)})"
    )

    Enum.each(stage.step_results, fn step ->
      label = step_label(step)

      IO.puts("    #{label} #{step.name} (#{format_duration(step.duration_ms)})")
    end)
  end

  defp step_label(%StepResult{allowed_failure: true}),
    do: IO.ANSI.yellow() <> "⚠" <> IO.ANSI.reset() <> " (allowed failure)"

  defp step_label(%StepResult{status: status}), do: status_icon(status)

  defp status_icon(:passed), do: IO.ANSI.green() <> "✓" <> IO.ANSI.reset()
  defp status_icon(:failed), do: IO.ANSI.red() <> "✗" <> IO.ANSI.reset()
  defp status_icon(:skipped), do: IO.ANSI.yellow() <> "○" <> IO.ANSI.reset()

  defp colorize_status(:passed), do: IO.ANSI.green() <> "passed" <> IO.ANSI.reset()
  defp colorize_status(:failed), do: IO.ANSI.red() <> "failed" <> IO.ANSI.reset()
  defp colorize_status(:skipped), do: IO.ANSI.yellow() <> "skipped" <> IO.ANSI.reset()
end
