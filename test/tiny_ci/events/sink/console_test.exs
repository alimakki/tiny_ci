defmodule TinyCI.Events.Sink.ConsoleTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.Events.Sink.Console

  alias TinyCI.Events.{
    MatrixRunStarted,
    StageCompleted,
    StageSkipped,
    StageStarted,
    StepCompleted,
    StepOutputLine,
    StepRetrying,
    StepStarted
  }

  @ts ~U[2024-01-15 10:30:00.000000Z]

  defp render(events, opts \\ []) do
    capture_io(fn ->
      {:ok, state} = Console.init(opts)

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

  defp stage_started(stage), do: %StageStarted{run_id: "r", timestamp: @ts, stage: stage}

  defp stage_completed(stage, status \\ :passed),
    do: %StageCompleted{run_id: "r", timestamp: @ts, stage: stage, status: status, duration_ms: 3}

  defp step_started(stage, step, opts \\ []) do
    struct!(%StepStarted{run_id: "r", timestamp: @ts, stage: stage, step: step}, opts)
  end

  defp step_output(stage, step, line, opts \\ []) do
    struct!(
      %StepOutputLine{run_id: "r", timestamp: @ts, stage: stage, step: step, line: line},
      opts
    )
  end

  defp step_completed(stage, step, output, opts \\ []) do
    struct!(
      %StepCompleted{
        run_id: "r",
        timestamp: @ts,
        stage: stage,
        step: step,
        status: :passed,
        duration_ms: 1,
        output: output
      },
      opts
    )
  end

  test "renders a stage header" do
    assert render([stage_started(:build)]) == "Stage: build\n"
  end

  test "renders a skipped stage with its reason verbatim" do
    events = [
      stage_started(:deploy),
      %StageSkipped{run_id: "r", timestamp: @ts, stage: :deploy, reason: "condition not met"}
    ]

    assert render(events) == "Stage: deploy\n  Skipped (condition not met)\n"
  end

  test "ignores events it does not render" do
    out = render([step_completed(:t, :u, "ignored")])
    assert out == ""
  end

  describe "buffered mode" do
    test "prints step output at stage end, under the step header" do
      events = [
        stage_started(:build),
        step_started(:build, :compile),
        step_output(:build, :compile, "compiling"),
        step_completed(:build, :compile, "compiling\n"),
        stage_completed(:build)
      ]

      assert render(events) == "Stage: build\n  [compile] compiling\n"
    end

    test "omits steps with empty output" do
      events = [
        stage_started(:build),
        step_started(:build, :noop),
        step_completed(:build, :noop, ""),
        stage_completed(:build)
      ]

      assert render(events) == "Stage: build\n"
    end

    test "orders steps by their declaration index, not by arrival" do
      events = [
        stage_started(:test),
        step_started(:test, :beta, index: 1),
        step_started(:test, :alpha, index: 0),
        step_completed(:test, :beta, "b\n"),
        step_completed(:test, :alpha, "a\n"),
        stage_completed(:test)
      ]

      assert render(events) == "Stage: test\n  [alpha] a\n  [beta] b\n"
    end

    test "orders matrix combinations by their declaration index" do
      events = [
        stage_started(:compat),
        %MatrixRunStarted{
          run_id: "r",
          timestamp: @ts,
          stage: :compat,
          combination: [v: "b"],
          index: 1
        },
        %MatrixRunStarted{
          run_id: "r",
          timestamp: @ts,
          stage: :compat,
          combination: [v: "a"],
          index: 0
        },
        step_started(:compat, :say, matrix_combination: [v: "b"], index: 0),
        step_completed(:compat, :say, "b!\n", matrix_combination: [v: "b"]),
        step_started(:compat, :say, matrix_combination: [v: "a"], index: 0),
        step_completed(:compat, :say, "a!\n", matrix_combination: [v: "a"]),
        stage_completed(:compat)
      ]

      assert render(events) == "Stage: compat\n  [v=a][say] a!\n  [v=b][say] b!\n"
    end

    test "trims the captured output exactly as the old reporter did" do
      events = [
        stage_started(:build),
        step_started(:build, :multi),
        step_completed(:build, :multi, "  one\ntwo  \n"),
        stage_completed(:build)
      ]

      assert render(events) == "Stage: build\n  [multi] one\ntwo\n"
    end

    test "renders matrix combination rows with their labels" do
      events = [
        stage_started(:compat),
        %MatrixRunStarted{run_id: "r", timestamp: @ts, stage: :compat, combination: [v: "a"]},
        %MatrixRunStarted{run_id: "r", timestamp: @ts, stage: :compat, combination: [v: "b"]},
        step_started(:compat, :say, matrix_combination: [v: "a"]),
        step_completed(:compat, :say, "a!\n", matrix_combination: [v: "a"]),
        step_started(:compat, :say, matrix_combination: [v: "b"]),
        step_completed(:compat, :say, "b!\n", matrix_combination: [v: "b"]),
        stage_completed(:compat)
      ]

      assert render(events) == "Stage: compat\n  [v=a][say] a!\n  [v=b][say] b!\n"
    end

    test "renders the first attempt and each retry notice" do
      events = [
        stage_started(:test),
        step_started(:test, :flaky, attempts: 3, index: 0),
        %StepRetrying{
          run_id: "r",
          timestamp: @ts,
          stage: :test,
          step: :flaky,
          attempt: 2,
          total: 3
        },
        step_completed(:test, :flaky, "ok\n"),
        stage_completed(:test)
      ]

      assert render(events) == "Stage: test\n  [attempt 1/3]\n  [attempt 2/3]\n  [flaky] ok\n"
    end

    test "a step without retries prints no attempt notice" do
      events = [
        stage_started(:test),
        step_started(:test, :unit, index: 0),
        step_completed(:test, :unit, "ok\n"),
        stage_completed(:test)
      ]

      assert render(events) == "Stage: test\n  [unit] ok\n"
    end
  end

  describe "streaming mode" do
    @streaming [mode: :streaming]

    test "prints each line as it arrives, without a prefix when none is set" do
      events = [
        stage_started(:test),
        step_started(:test, :unit),
        step_output(:test, :unit, "one"),
        step_output(:test, :unit, "two"),
        step_completed(:test, :unit, "one\ntwo\n"),
        stage_completed(:test)
      ]

      assert render(events, @streaming) == "Stage: test\none\ntwo\n"
    end

    test "prefixes each line with the step's prefix" do
      events = [
        stage_started(:test),
        step_started(:test, :alpha, prefix: "alpha"),
        step_output(:test, :alpha, "hello"),
        step_completed(:test, :alpha, "hello\n"),
        stage_completed(:test)
      ]

      assert render(events, @streaming) == "Stage: test\n  [alpha] hello\n"
    end

    test "does not print buffered output again at stage end" do
      events = [
        stage_started(:test),
        step_started(:test, :unit),
        step_output(:test, :unit, "once"),
        step_completed(:test, :unit, "once\n"),
        stage_completed(:test)
      ]

      out = render(events, @streaming)
      assert out == "Stage: test\nonce\n"
      assert length(String.split(out, "once")) == 2
    end

    test "still groups matrix output at stage end" do
      events = [
        stage_started(:compat),
        %MatrixRunStarted{run_id: "r", timestamp: @ts, stage: :compat, combination: [v: "a"]},
        step_started(:compat, :say, matrix_combination: [v: "a"]),
        step_output(:compat, :say, "a!", matrix_combination: [v: "a"]),
        step_completed(:compat, :say, "a!\n", matrix_combination: [v: "a"]),
        stage_completed(:compat)
      ]

      assert render(events, @streaming) == "Stage: compat\n  [v=a][say] a!\n"
    end
  end
end
