defmodule TinyCI.ExecutorExecutionTest do
  @moduledoc """
  Integration tests for the execution seam: sessions per stage/matrix
  combination, trust gating, and local/hosted parity.
  """

  use ExUnit.Case, async: true

  alias TinyCI.{Executor, Stage, StageResult, Step}
  alias TinyCI.Events.{PipelineCompleted, PipelineStarted, StageStarted}
  alias TinyCI.ExecutionFixtures.RecordingBackend

  @moduletag :tmp_dir

  @silent [console: false, output: :buffered, record: false]

  defp log(tmp_dir) do
    tmp_dir
    |> Path.join("execution.log")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp count(lines, prefix), do: Enum.count(lines, &String.starts_with?(&1, prefix))

  defp run(stages, context, opts) do
    Executor.run_pipeline(stages, context, opts)
  end

  defp run_seamed(stages, tmp_dir) do
    run(stages, %{root: tmp_dir}, @silent ++ [backend: RecordingBackend])
  end

  describe "sessions" do
    test "one session wraps a regular stage", %{tmp_dir: tmp_dir} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      assert {:ok, [%StageResult{status: :passed}]} = run_seamed([stage], tmp_dir)

      lines = log(tmp_dir)
      assert count(lines, "open ") == 1
      assert count(lines, "exec ") == 1
      assert count(lines, "close") == 1
      assert Enum.at(lines, 0) =~ "open #{tmp_dir} "
      assert List.last(lines) == "close"
    end

    test "parallel steps share the stage session", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :build,
        mode: :parallel,
        steps: [%Step{name: :a, cmd: "true"}, %Step{name: :b, cmd: "true"}]
      }

      assert {:ok, [%StageResult{status: :passed}]} = run_seamed([stage], tmp_dir)

      lines = log(tmp_dir)
      assert count(lines, "open ") == 1
      assert count(lines, "exec ") == 2
      assert count(lines, "close") == 1
    end

    test "each matrix combination gets its own session", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :compat,
        matrix: [v: ["a", "b"]],
        mode: :serial,
        steps: [%Step{name: :say, cmd: "true"}]
      }

      assert {:ok, [%StageResult{status: :passed}]} = run_seamed([stage], tmp_dir)

      lines = log(tmp_dir)
      assert count(lines, "open ") == 2
      assert count(lines, "exec ") == 2
      assert count(lines, "close") == 2
    end

    test "a crashing backend still closes the session", %{tmp_dir: tmp_dir} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :boom, cmd: "crash"}]}

      assert {:error, {:stage_failed, :build, :failed}, [%StageResult{step_results: [step]}]} =
               run_seamed([stage], tmp_dir)

      assert step.status == :failed
      assert step.output =~ "recording backend crashed"
      assert count(log(tmp_dir), "close") == 1
    end

    test "a stage retry reuses the stage session", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        steps: [%Step{name: :one, cmd: "echo x"}]
      }

      opts =
        @silent ++
          [
            backend: RecordingBackend,
            control: [breakpoints: ["after:build"], subscribers: [self()]]
          ]

      task = Task.async(fn -> Executor.run_pipeline([stage], %{root: tmp_dir}, opts) end)

      session = await_pause()
      assert :ok = TinyCI.Control.resume(session.run_id, session.pause_id, :retry)

      session = await_pause()
      assert :ok = TinyCI.Control.resume(session.run_id, session.pause_id, :continue)

      assert {:ok, [%StageResult{status: :passed}]} = Task.await(task, 5_000)

      lines = log(tmp_dir)
      assert count(lines, "open ") == 1
      assert count(lines, "exec ") == 2
      assert count(lines, "close") == 1
    end

    test "each DAG stage gets its own session", %{tmp_dir: tmp_dir} do
      stages = [
        %Stage{name: :a, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]},
        %Stage{name: :b, needs: [:a], mode: :serial, steps: [%Step{name: :two, cmd: "true"}]}
      ]

      assert {:ok, [%StageResult{status: :passed}, %StageResult{status: :passed}]} =
               run_seamed(stages, tmp_dir)

      lines = log(tmp_dir)
      assert count(lines, "open ") == 2
      assert count(lines, "exec ") == 2
      assert count(lines, "close") == 2
    end

    test "a crashing matrix combination closes its own session", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :compat,
        matrix: [v: ["ok", "crash"]],
        mode: :serial,
        steps: [%Step{name: :say, cmd: "echo $V"}]
      }

      assert {:error, {:stage_failed, :compat, :failed}, [%StageResult{status: :failed}]} =
               run_seamed([stage], tmp_dir)

      lines = log(tmp_dir)
      assert count(lines, "open ") == 2
      assert count(lines, "exec ") == 2
      assert count(lines, "close") == 2
    end
  end

  defp await_pause do
    assert_receive {:tiny_ci_control, :breakpoint_hit, session}, 5_000
    session
  end

  describe "trust" do
    test "an untrusted run fails closed before any stage starts", %{tmp_dir: tmp_dir} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}

      opts = @silent ++ [extra_sinks: [{TinyCI.TestSink, pid: self()}]]
      context = %{root: tmp_dir, trust: :untrusted}

      assert {:error, {:execution_unavailable, {:isolation_unavailable, :untrusted}}, []} =
               Executor.run_pipeline([stage], context, opts)

      assert_receive {:event, %PipelineStarted{}}
      assert_receive {:event, %PipelineCompleted{status: :failed}}
      refute_received {:event, %StageStarted{}}
      refute File.exists?(Path.join(tmp_dir, "execution.log"))
    end

    test "a pre-set Local backend cannot smuggle an untrusted run onto the host" do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}
      context = %{trust: :untrusted, execution_backend: TinyCI.Execution.Backend.Local}

      assert_raise TinyCI.Execution.Error, fn ->
        Executor.execute(stage, context, :buffered, @silent)
      end
    end
  end
end
