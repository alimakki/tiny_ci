defmodule TinyCI.ExecutionRegressionTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.{Executor, Hook, Hooks, RegressionActions, Stage, StageResult, Step}
  alias TinyCI.DSL.Interpreter

  @silent [listener: TinyCI.Listener.Silent, output: :buffered]

  defp action(operation, extra \\ []) do
    struct!(
      Step,
      Keyword.merge(
        [
          name: operation,
          module: RegressionActions,
          config_block: fn -> [operation: operation] end
        ],
        extra
      )
    )
  end

  describe "working directory" do
    @tag :tmp_dir
    test "the project root is the default directory in serial and parallel steps", %{
      tmp_dir: root
    } do
      for mode <- [:serial, :parallel] do
        stage = %Stage{name: :cwd, mode: mode, steps: [%Step{name: :pwd, cmd: "pwd"}]}
        result = Executor.execute(stage, %{root: root}, :buffered, TinyCI.Listener.Silent)
        assert result.status == :passed
        assert String.trim(hd(result.step_results).output) == root
      end
    end

    @tag :tmp_dir
    test "shell hooks also use the project root", %{tmp_dir: root} do
      hook = %Hook{name: :cwd, cmd: "pwd; false"}

      output =
        capture_io(:stderr, fn ->
          Hooks.run_hooks(%{on_success: [hook]}, :on_success, %{root: root})
        end)

      assert output =~ root
    end
  end

  describe "store writes" do
    @tag :tmp_dir
    test "matrix artifacts have separate destinations", %{tmp_dir: root} do
      File.write!(Path.join(root, "output"), "build output")

      stage = %Stage{
        name: :matrix,
        matrix: [variant: ["a", "b"]],
        steps: [
          %Step{
            name: :package,
            cmd: "true",
            artifact: %{name: "release", paths: ["output"], required: true}
          }
        ]
      }

      result =
        Executor.execute(
          stage,
          %{root: root, artifacts_dir: Path.join(root, "artifacts")},
          :buffered,
          TinyCI.Listener.Silent
        )

      assert result.status == :passed
      paths = Enum.map(result.matrix_runs, & &1.store.artifact_release)
      assert length(Enum.uniq(paths)) == 2
      assert Enum.all?(paths, &(File.read!(Path.join(&1, "output")) == "build output"))
    end

    test "an unchanged DAG sibling cannot revert a write" do
      stages = [
        %Stage{name: :writer, steps: [action(:write)]},
        %Stage{name: :noop, steps: [%Step{name: :noop, cmd: "true"}]},
        %Stage{name: :consumer, needs: [:writer, :noop], steps: []}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages, %{store: %{tag: "old"}}, @silent)
      assert Enum.find(results, &(&1.name == :consumer)).store.tag == "new"
    end

    test "an unchanged matrix combination cannot revert a write" do
      stage = %Stage{
        name: :matrix,
        matrix: [variant: ["writer", "noop"]],
        steps: [action(:matrix)]
      }

      assert {:ok, [result]} = Executor.run_pipeline([stage], %{store: %{tag: "old"}}, @silent)
      assert result.store.tag == "new"
    end

    test "explicit writes equal to the inherited value still participate in conflict ordering" do
      stage = fn name, tag ->
        %Stage{name: name, steps: [action(:write, config_block: fn -> [tag: tag] end)]}
      end

      stages = [
        stage.(:first, "new"),
        stage.(:second, "old"),
        %Stage{name: :next, needs: [:first, :second]}
      ]

      assert {:ok, results} = Executor.run_pipeline(stages, %{store: %{tag: "old"}}, @silent)
      assert List.last(results).store.tag == "old"
    end
  end

  describe "module invocation" do
    test "third-party module hooks cannot bypass the execution driver" do
      ctx = %{test_pid: self(), sandbox: [root_app: :another_application]}
      hook = %Hook{name: :untrusted, module: RegressionActions}

      stderr =
        capture_io(:stderr, fn -> Hooks.run_hooks(%{on_success: [hook]}, :on_success, ctx) end)

      assert stderr =~ "untrusted"
      refute_received {:hook_config, _}
    end

    test "module hook timeouts terminate the callback" do
      hook = %Hook{
        name: :blocked,
        module: RegressionActions,
        timeout: 30,
        config_block: fn -> [operation: :block] end
      }

      parent = self()

      task =
        Task.async(fn ->
          capture_io(:stderr, fn ->
            Hooks.run_hooks(%{on_success: [hook]}, :on_success, %{test_pid: parent})
          end)
        end)

      assert_receive {:callback_started, callback}, 1000
      monitor = Process.monitor(callback)

      try do
        assert {:ok, output} = Task.yield(task, 1000)
        assert output =~ "timed out after 30ms"
        assert_receive {:DOWN, ^monitor, :process, ^callback, _}
      after
        Process.exit(callback, :kill)
        Task.shutdown(task, :brutal_kill)
      end
    end

    test "configuration references resolve at execution, including nested literals" do
      source = """
      stage :build do
        step :inspect, module: TinyCI.RegressionActions do
          set :operation, :config
          set :options, %{source: store(:artifact_release)}
        end
      end
      """

      assert {:ok, spec} = Interpreter.interpret_string(source, "pipeline.exs")

      assert {:ok, [result]} =
               Executor.run_pipeline(
                 spec.stages,
                 %{store: %{artifact_release: "/release"}},
                 @silent
               )

      assert result.store.config[:options] == %{source: "/release"}
    end

    test "a module without a configuration block receives a keyword list" do
      stage = %Stage{name: :build, steps: [%Step{name: :write, module: RegressionActions}]}
      assert {:ok, [result]} = Executor.run_pipeline([stage], %{}, @silent)
      assert result.store.tag == "new"
    end

    test "a module receives its resolved step environment" do
      stage = %Stage{
        name: :build,
        env: %{"VALUE" => "stage"},
        steps: [action(:config, env: %{"VALUE" => "step"})]
      }

      assert {:ok, [result]} = Executor.run_pipeline([stage], %{}, @silent)
      assert result.store.env["VALUE"] == "step"
    end

    for mode <- [:serial, :parallel] do
      test "module timeout terminates the callback in #{mode} mode" do
        stage = %Stage{name: :timeout, mode: unquote(mode), steps: [action(:block, timeout: 30)]}
        parent = self()

        task =
          Task.async(fn ->
            Executor.execute(stage, %{test_pid: parent}, :buffered, TinyCI.Listener.Silent)
          end)

        assert_receive {:callback_started, callback}, 1000
        monitor = Process.monitor(callback)

        try do
          assert {:ok, %StageResult{status: :failed, step_results: [step]}} =
                   Task.yield(task, 1000)

          assert step.output =~ "timed out after 30ms"
          assert_receive {:DOWN, ^monitor, :process, ^callback, _}
        after
          Process.exit(callback, :kill)
          Task.shutdown(task, :brutal_kill)
        end
      end
    end

    test "ordinary module IO is captured and redacted before output, results and events" do
      stage = %Stage{name: :output, steps: [action(:print)]}

      opts =
        @silent ++
          [
            secrets: %{"TOKEN" => "synthetic-secret"},
            extra_sinks: [{TinyCI.TestSink, pid: self()}]
          ]

      {{:ok, [result]}, console} = with_io(fn -> Executor.run_pipeline([stage], %{}, opts) end)
      assert console == ""
      assert hd(result.step_results).output == "***\n"
      assert_receive {:event, %TinyCI.Events.StepOutputLine{line: "***"}}
    end

    test "module hooks resolve config and do not leak their printed or raised secrets" do
      ctx = %{
        store: %{source: "/release"},
        test_pid: self(),
        secrets: %{"TOKEN" => "synthetic-secret"},
        secret_values: ["synthetic-secret"]
      }

      ref = %TinyCI.DSL.Value.StoreRef{key: :source}

      hooks =
        for op <- [nil, :print, :raise],
            do: %Hook{
              name: :module,
              module: RegressionActions,
              config_block: fn -> [operation: op, source: ref] end
            }

      stderr =
        capture_io(:stderr, fn ->
          stdout = capture_io(fn -> Hooks.run_hooks(%{on_success: hooks}, :on_success, ctx) end)
          refute stdout =~ "synthetic-secret"
        end)

      assert_received {:hook_config, [operation: nil, source: "/release"]}
      assert stderr =~ "***"
      refute stderr =~ "synthetic-secret"
    end
  end

  describe "condition semantics" do
    test "bare environment conditions use pipeline, stage and step values in both plan and run" do
      source = """
      env PIPELINE_FLAG: "yes"
      stage :enabled, when: env("STAGE_FLAG") do
        env STAGE_FLAG: "yes"
        step :enabled, cmd: "true", when: env("STEP_FLAG") and env("PIPELINE_FLAG"), env: %{"STEP_FLAG" => "yes"}
      end
      stage :disabled, when: nil do
        step :never, cmd: "false"
      end
      stage :step_condition do
        step :disabled, cmd: "false", when: nil
      end
      """

      assert {:ok, spec} = Interpreter.interpret_string(source, "conditions.exs")
      ctx = %{pipeline_env: spec.env}

      assert {:ok, [enabled, disabled, step_condition]} =
               Executor.run_pipeline(spec.stages, ctx, @silent)

      assert enabled.status == :passed
      assert disabled.status == :skipped
      assert hd(step_condition.step_results).status == :skipped
      plan = capture_io(fn -> TinyCI.DryRun.print_plan(spec.stages, ctx) end)
      assert plan =~ ":disabled"
      assert plan =~ "will skip"
    end
  end
end
