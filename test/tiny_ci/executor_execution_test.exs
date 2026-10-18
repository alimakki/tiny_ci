defmodule TinyCI.ExecutorExecutionTest do
  @moduledoc """
  Integration tests for the execution seam: sessions per stage/matrix
  combination, trust gating, and local/hosted parity.
  """

  use ExUnit.Case, async: true

  alias TinyCI.{Executor, Stage, StageResult, Step}

  alias TinyCI.Events.{
    MatrixRunCompleted,
    MatrixRunStarted,
    PipelineCompleted,
    PipelineStarted,
    StageStarted
  }

  alias TinyCI.ExecutionFixtures.RecordingBackend
  alias TinyCI.ExecutionFixtures.SpecBackend
  alias TinyCI.ExecutionFixtures.UnopenableBackend

  @moduletag :tmp_dir

  @silent [console: false, output: :buffered, record: false]

  defp log(tmp_dir) do
    tmp_dir
    |> Path.join("execution.log")
    |> File.read!()
    |> String.split("\n", trim: true)
  end

  defp count(lines, prefix), do: Enum.count(lines, &String.starts_with?(&1, prefix))

  defp cache_inputs(ctx, command, paths, working_dir) do
    %{
      command: command,
      module: nil,
      env: Map.merge(System.get_env(), TinyCI.Executor.Env.resolve(ctx, %{})),
      working_dir: working_dir,
      matrix: nil,
      paths: paths,
      runtime:
        {System.version(), :erlang.system_info(:system_version),
         :erlang.system_info(:system_architecture)}
    }
  end

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

    test "a stage's network option reaches the session spec", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        network: false,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert {:ok, [%StageResult{status: :passed}]} =
               run([stage], %{root: tmp_dir}, @silent ++ [backend: SpecBackend])

      assert File.read!(Path.join(tmp_dir, "session_specs.log")) =~ "|false|"
    end

    test "matrix combinations each get the stage's network option", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :compat,
        matrix: [v: ["a", "b"]],
        mode: :serial,
        network: false,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      assert {:ok, [%StageResult{status: :passed}]} =
               run([stage], %{root: tmp_dir}, @silent ++ [backend: SpecBackend])

      lines =
        File.read!(Path.join(tmp_dir, "session_specs.log")) |> String.split("\n", trim: true)

      assert length(lines) == 2
      assert Enum.all?(lines, &String.contains?(&1, "|false|"))
    end

    test "a matrix session-open failure emits a failed completion event", %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :compat,
        matrix: [v: ["a", "b"]],
        mode: :serial,
        steps: [%Step{name: :one, cmd: "true"}]
      }

      opts =
        @silent ++
          [backend: UnopenableBackend, extra_sinks: [{TinyCI.TestSink, pid: self()}]]

      assert {:error, {:stage_failed, :compat, _reason}, [_result]} =
               run([stage], %{root: tmp_dir}, opts)

      assert_receive {:event, %MatrixRunStarted{stage: :compat}}
      assert_receive {:event, %MatrixRunCompleted{stage: :compat, status: :failed}}
    end

    test "an untrusted run skips the host-side cache", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "mix.lock"), "%{}")
      File.write!(Path.join(tmp_dir, "out"), "cached")
      paths = ["out"]

      ctx = %{root: tmp_dir, trust: :trusted}
      inputs = cache_inputs(ctx, "true", paths, tmp_dir)
      {:ok, key} = TinyCI.Cache.compute_key(Path.join(tmp_dir, "mix.lock"), inputs)
      :ok = TinyCI.Cache.save(tmp_dir, key, paths, tmp_dir)
      File.rm!(Path.join(tmp_dir, "out"))

      step = %Step{name: :one, cmd: "true", cache: %{key: "mix.lock", paths: paths}}
      stage = %Stage{name: :build, mode: :serial, steps: [step]}

      assert {:ok, [%StageResult{status: :passed}]} =
               run(
                 [stage],
                 %{root: tmp_dir, trust: :untrusted},
                 @silent ++ [backend: RecordingBackend]
               )

      refute File.exists?(Path.join(tmp_dir, "out"))
      assert count(log(tmp_dir), "exec ") == 1
    end

    test "an untrusted run skips host-side artifact persistence", %{tmp_dir: tmp_dir} do
      File.write!(Path.join(tmp_dir, "out"), "cached")
      artifacts_dir = Path.join(tmp_dir, "artifacts")

      step = %Step{
        name: :one,
        cmd: "true",
        artifact: %{name: "a", paths: ["out"], required: true}
      }

      stage = %Stage{name: :build, mode: :serial, steps: [step]}

      assert {:ok, [%StageResult{status: :passed}]} =
               run(
                 [stage],
                 %{root: tmp_dir, trust: :untrusted},
                 @silent ++ [backend: RecordingBackend, artifacts_dir: artifacts_dir]
               )

      refute File.exists?(Path.join([artifacts_dir, "a"]))
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

      assert {:error, {:execution_unavailable, :no_default_image}, []} =
               Executor.run_pipeline([stage], context, opts)

      assert_receive {:event, %PipelineStarted{}}
      assert_receive {:event, %PipelineCompleted{status: :failed}}
      refute_received {:event, %StageStarted{}}
      refute File.exists?(Path.join(tmp_dir, "execution.log"))
    end

    test "an untrusted run refuses a repository module step before any stage starts",
         %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :build,
        mode: :serial,
        steps: [
          %Step{name: :prepare, cmd: "true"},
          %Step{name: :deploy, module: MyApp.Deploy}
        ]
      }

      opts = @silent ++ [backend: RecordingBackend, extra_sinks: [{TinyCI.TestSink, pid: self()}]]
      context = %{root: tmp_dir, trust: :untrusted}

      assert {:error, {:untrusted_actions, [detail]}, []} =
               Executor.run_pipeline([stage], context, opts)

      assert %{kind: :step, stage: :build, name: :deploy, module: MyApp.Deploy} = detail
      assert_receive {:event, %PipelineStarted{}}
      assert_receive {:event, %PipelineCompleted{status: :failed}}
      refute_received {:event, %StageStarted{}}
      refute File.exists?(Path.join(tmp_dir, "execution.log"))
    end

    test "an untrusted run refuses a repository module hook before any stage starts",
         %{tmp_dir: tmp_dir} do
      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :test, cmd: "true"}]}
      hooks = %{on_success: [%TinyCI.Hook{name: :notify, module: MyApp.Notify}]}

      opts =
        @silent ++
          [backend: RecordingBackend, hooks: hooks, extra_sinks: [{TinyCI.TestSink, pid: self()}]]

      assert {:error, {:untrusted_actions, [detail]}, []} =
               Executor.run_pipeline([stage], %{root: tmp_dir, trust: :untrusted}, opts)

      assert %{kind: :hook, name: :notify, module: MyApp.Notify} = detail
      refute File.exists?(Path.join(tmp_dir, "execution.log"))
    end

    test "an untrusted run rejects paths outside the workspace before any stage starts",
         %{tmp_dir: tmp_dir} do
      outside = Path.dirname(tmp_dir)

      stage = %Stage{
        name: :build,
        mode: :serial,
        steps: [%Step{name: :one, cmd: "true", working_dir: outside}]
      }

      opts = @silent ++ [backend: RecordingBackend, extra_sinks: [{TinyCI.TestSink, pid: self()}]]

      assert {:error, {:unsafe_pipeline_paths, [detail]}, []} =
               Executor.run_pipeline([stage], %{root: tmp_dir, trust: :untrusted}, opts)

      assert %{kind: :step, stage: :build, name: :one} = detail
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
