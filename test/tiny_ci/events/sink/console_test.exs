defmodule TinyCI.Events.Sink.ConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.Events.Sink.Console
  alias TinyCI.Events.{StageSkipped, StageStarted, StepCompleted}

  @ts ~U[2024-01-15 10:30:00.000000Z]

  defp render(events) do
    capture_io(fn ->
      {:ok, state} = Console.init([])

      final =
        events
        |> Enum.with_index(1)
        |> Enum.reduce(state, fn {event, seq}, st ->
          {:ok, st} = Console.handle_event(seq, event, st)
          st
        end)

      Console.close(final)
    end)
  end

  test "renders a stage header" do
    out = render([%StageStarted{run_id: "r", timestamp: @ts, stage: :build}])
    assert out =~ "Stage: build"
  end

  test "renders a skipped stage with its reason verbatim" do
    out =
      render([
        %StageSkipped{run_id: "r", timestamp: @ts, stage: :deploy, reason: "condition not met"}
      ])

    assert out =~ "Skipped (condition not met)"
  end

  test "ignores events it does not render" do
    out =
      render([
        %StepCompleted{
          run_id: "r",
          timestamp: @ts,
          stage: :t,
          step: :u,
          status: :passed,
          duration_ms: 1
        }
      ])

    assert out == ""
  end
end
