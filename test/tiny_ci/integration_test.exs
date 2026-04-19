defmodule TinyCI.IntegrationTest do
  @moduledoc """
  End-to-end integration tests that exercise the full pipeline lifecycle.

  Tests in the "DSL -> execute -> report" group compile pipeline modules from
  source strings using the legacy Elixir macro DSL directly, bypassing the
  file interpreter. This exercises the executor, reporter, and core pipeline
  logic without touching the file format.

  Tests that go through `Mix.Tasks.TinyCi.Run` write pipeline files in the
  new flat DSL format and exercise the full interpreter -> executor path.
  """

  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TinyCI.{Executor, Reporter, StageResult, StepResult}

  defmodule Notifier do
    @moduledoc false
    def execute(config, ctx) do
      path = config[:output_path]
      content = "channel=#{config[:channel]},branch=#{ctx.branch}"
      File.write!(path, content)
      :ok
    end
  end

  @tmp_dir "test/tmp/integration"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp compile_pipeline(code) do
    [{module, _bytecode}] =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        send(self(), {:modules, Code.compile_string(code)})
      end)
      |> then(fn _warnings ->
        receive do
          {:modules, modules} -> modules
        end
      end)

    module
  end

  describe "full pipeline: DSL -> execute -> report" do
    test "multi-stage passing pipeline produces correct results and output" do
      code = """
      defmodule TinyCI.IntegrationTest.PassingPipeline do
        use TinyCI.DSL

        stage :lint, mode: :parallel do
          step :format, cmd: "echo formatted"
          step :credo, cmd: "echo clean"
        end

        stage :test, mode: :serial do
          step :unit, cmd: "echo '5 tests, 0 failures'"
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      context = %{branch: "main", commit: "abc123def456", timestamp: DateTime.utc_now()}

      assert {:ok, results} = Executor.run_pipeline(stages, context)

      assert length(results) == 2

      assert [
               %StageResult{name: :lint, status: :passed},
               %StageResult{name: :test, status: :passed}
             ] = results

      lint_result = Enum.find(results, &(&1.name == :lint))
      assert length(lint_result.step_results) == 2
      assert Enum.all?(lint_result.step_results, &(&1.status == :passed))

      test_result = Enum.find(results, &(&1.name == :test))
      assert [%StepResult{name: :unit, status: :passed}] = test_result.step_results
      assert test_result.step_results |> hd() |> Map.get(:output) =~ "5 tests, 0 failures"

      summary =
        capture_io(fn ->
          Reporter.print_summary(results)
        end)

      assert summary =~ "Pipeline Summary"
      assert summary =~ "lint"
      assert summary =~ "test"
      assert summary =~ "passed"
    after
      :code.purge(TinyCI.IntegrationTest.PassingPipeline)
      :code.delete(TinyCI.IntegrationTest.PassingPipeline)
    end

    test "pipeline halts on stage failure and reports correctly" do
      code = """
      defmodule TinyCI.IntegrationTest.FailingPipeline do
        use TinyCI.DSL

        stage :build, mode: :serial do
          step :compile, cmd: "echo compiling"
          step :typecheck, cmd: "exit 1"
        end

        stage :deploy, mode: :serial do
          step :release, cmd: "echo should_not_run"
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      context = %{branch: "main", commit: "abc123", timestamp: DateTime.utc_now()}

      assert {:error, {:stage_failed, :build, :failed}, results} =
               Executor.run_pipeline(stages, context)

      assert length(results) == 1
      assert [%StageResult{name: :build, status: :failed}] = results

      build_result = hd(results)
      assert length(build_result.step_results) == 2
      assert Enum.at(build_result.step_results, 0).status == :passed
      assert Enum.at(build_result.step_results, 1).status == :failed

      summary =
        capture_io(fn ->
          Reporter.print_summary(results)
        end)

      assert summary =~ "build"
      assert summary =~ "failed"
    after
      :code.purge(TinyCI.IntegrationTest.FailingPipeline)
      :code.delete(TinyCI.IntegrationTest.FailingPipeline)
    end

    test "conditional stage is skipped based on context" do
      code = """
      defmodule TinyCI.IntegrationTest.ConditionalPipeline do
        use TinyCI.DSL

        stage :test do
          step :unit, cmd: "echo tests_pass"
        end

        stage :deploy, when: when_branch("main") do
          step :release, cmd: "echo deploying"
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()

      feature_context = %{branch: "feature/foo", commit: "abc123", timestamp: DateTime.utc_now()}

      assert {:ok, results} = Executor.run_pipeline(stages, feature_context)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :deploy, status: :skipped}
             ] = results

      main_context = %{branch: "main", commit: "def456", timestamp: DateTime.utc_now()}

      assert {:ok, results} = Executor.run_pipeline(stages, main_context)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :deploy, status: :passed}
             ] = results
    after
      :code.purge(TinyCI.IntegrationTest.ConditionalPipeline)
      :code.delete(TinyCI.IntegrationTest.ConditionalPipeline)
    end

    test "module step receives config and context end-to-end" do
      output_path = Path.join(@tmp_dir, "notifier_output.txt")

      code = """
      defmodule TinyCI.IntegrationTest.ModuleStepPipeline do
        use TinyCI.DSL

        stage :notify, mode: :serial do
          step :slack, module: TinyCI.IntegrationTest.Notifier do
            set :channel, "#deploys"
            set :output_path, "#{output_path}"
          end
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      context = %{branch: "main", commit: "abc123", timestamp: DateTime.utc_now()}

      assert {:ok, [%StageResult{name: :notify, status: :passed}]} =
               Executor.run_pipeline(stages, context)

      assert File.read!(output_path) == "channel=#deploys,branch=main"
    after
      :code.purge(TinyCI.IntegrationTest.ModuleStepPipeline)
      :code.delete(TinyCI.IntegrationTest.ModuleStepPipeline)
    end

    test "env variables flow through DSL to execution" do
      code = """
      defmodule TinyCI.IntegrationTest.EnvPipeline do
        use TinyCI.DSL

        stage :check, mode: :serial do
          step :env_test, cmd: ~s(echo "$TINY_CI_INTEGRATION_VAR"), env: %{"TINY_CI_INTEGRATION_VAR" => "it_works"}
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      context = %{branch: "main", commit: "abc123", timestamp: DateTime.utc_now()}

      assert {:ok, [%StageResult{name: :check, status: :passed, step_results: [step]}]} =
               Executor.run_pipeline(stages, context)

      assert step.output =~ "it_works"
    after
      :code.purge(TinyCI.IntegrationTest.EnvPipeline)
      :code.delete(TinyCI.IntegrationTest.EnvPipeline)
    end

    test "timeout kills slow step in end-to-end run" do
      code = """
      defmodule TinyCI.IntegrationTest.TimeoutPipeline do
        use TinyCI.DSL

        stage :test, mode: :serial do
          step :slow, cmd: "sleep 30", timeout: 200
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      context = %{branch: "main", commit: "abc123", timestamp: DateTime.utc_now()}

      assert {:error, {:stage_failed, :test, :failed}, [result]} =
               Executor.run_pipeline(stages, context)

      assert result.status == :failed
      [step] = result.step_results
      assert step.status == :failed
      assert step.output =~ "timed out"
    after
      :code.purge(TinyCI.IntegrationTest.TimeoutPipeline)
      :code.delete(TinyCI.IntegrationTest.TimeoutPipeline)
    end

    test "full pipeline via Mix task with --file flag (new format)" do
      path = Path.join(@tmp_dir, "pipeline.exs")

      File.write!(path, """
      stage :greet, mode: :serial do
        step :hello, cmd: "echo integration_hello"
        step :world, cmd: "echo integration_world"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
      assert output =~ "integration_hello"
      assert output =~ "integration_world"
    end

    test "dry-run via Mix task shows plan without executing (new format)" do
      path = Path.join(@tmp_dir, "pipeline.exs")

      File.write!(path, """
      stage :test, mode: :parallel do
        step :unit, cmd: "mix test", timeout: 120_000
        step :lint, cmd: "mix credo"
      end

      stage :deploy, mode: :serial, when: branch() == "main" do
        step :release, cmd: "mix release"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--dry-run"])
          assert result == :ok
        end)

      assert output =~ "Dry Run"
      assert output =~ ":test"
      assert output =~ ":unit"
      assert output =~ ":lint"
      assert output =~ "120000"
      assert output =~ ":deploy"
      refute output =~ "Pipeline completed successfully"
    end
  end

  describe "phase 10: step data passing" do
    defmodule ImageTagger do
      @moduledoc false
      def execute(config, _ctx) do
        {:ok, %{image_tag: "myapp:#{config[:version]}"}}
      end
    end

    defmodule StoreVerifier do
      @moduledoc false
      def execute(_config, ctx) do
        path = ctx[:verify_path]
        content = inspect(ctx.store)
        File.write!(path, content)
        :ok
      end
    end

    test "module step produces store data consumed by later shell step via env" do
      path = Path.join(@tmp_dir, "store_producer.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :tag, module: TinyCI.IntegrationTest.ImageTagger do
          set :version, "1.0.0"
        end
      end

      stage :deploy, mode: :serial do
        step :push, cmd: "echo $IMAGE_TAG", env: %{"IMAGE_TAG" => store(:image_tag)}
      end
      """)

      {:ok, spec} = TinyCI.Discovery.load_pipeline(path)
      context = %{branch: "main", commit: "abc123", store: %{}, timestamp: DateTime.utc_now()}

      assert {:ok, results} = Executor.run_pipeline(spec.stages, context)

      assert [
               %StageResult{name: :build, status: :passed},
               %StageResult{name: :deploy, status: :passed}
             ] = results

      deploy_result = Enum.find(results, &(&1.name == :deploy))
      [push_step] = deploy_result.step_results
      assert push_step.output =~ "myapp:1.0.0"
    end

    test "module step reads store from context across stages" do
      verify_path = Path.join(@tmp_dir, "store_verify.txt")

      code = """
      defmodule TinyCI.IntegrationTest.StoreReaderPipeline do
        use TinyCI.DSL

        stage :build, mode: :serial do
          step :tag, module: TinyCI.IntegrationTest.ImageTagger do
            set :version, "2.0.0"
          end
        end

        stage :verify, mode: :serial do
          step :check, module: TinyCI.IntegrationTest.StoreVerifier
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()

      context = %{
        branch: "main",
        commit: "abc123",
        timestamp: DateTime.utc_now(),
        verify_path: verify_path
      }

      assert {:ok, results} = Executor.run_pipeline(stages, context)
      assert Enum.all?(results, &(&1.status == :passed))

      store_contents = File.read!(verify_path)
      assert store_contents =~ "image_tag"
      assert store_contents =~ "myapp:2.0.0"
    after
      :code.purge(TinyCI.IntegrationTest.StoreReaderPipeline)
      :code.delete(TinyCI.IntegrationTest.StoreReaderPipeline)
    end

    test "serial steps within a stage accumulate store data" do
      path = Path.join(@tmp_dir, "serial_store.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :tag, module: TinyCI.IntegrationTest.ImageTagger do
          set :version, "3.0.0"
        end
        step :check, cmd: "echo $IMAGE_TAG", env: %{"IMAGE_TAG" => store(:image_tag)}
      end
      """)

      {:ok, spec} = TinyCI.Discovery.load_pipeline(path)
      context = %{branch: "main", commit: "abc123", store: %{}, timestamp: DateTime.utc_now()}

      assert {:ok, [result]} = Executor.run_pipeline(spec.stages, context)
      assert result.status == :passed

      check_step = Enum.find(result.step_results, &(&1.name == :check))
      assert check_step.output =~ "myapp:3.0.0"
    end
  end

  describe "phase 9: allow_failure" do
    test "allow_failure step does not fail the stage end-to-end" do
      code = """
      defmodule TinyCI.IntegrationTest.AllowFailurePipeline do
        use TinyCI.DSL

        stage :test, mode: :serial do
          step :flaky, cmd: "exit 1", allow_failure: true
          step :unit, cmd: "echo tests_pass"
        end

        stage :deploy, mode: :serial do
          step :release, cmd: "echo deployed"
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      context = %{branch: "main", commit: "abc123", timestamp: DateTime.utc_now()}

      assert {:ok, results} = Executor.run_pipeline(stages, context)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :deploy, status: :passed}
             ] = results

      test_result = Enum.find(results, &(&1.name == :test))
      flaky = Enum.find(test_result.step_results, &(&1.name == :flaky))
      assert flaky.status == :failed
      assert flaky.allowed_failure == true

      unit = Enum.find(test_result.step_results, &(&1.name == :unit))
      assert unit.status == :passed

      summary =
        capture_io(fn ->
          Reporter.print_summary(results)
        end)

      assert summary =~ "allowed"
    after
      :code.purge(TinyCI.IntegrationTest.AllowFailurePipeline)
      :code.delete(TinyCI.IntegrationTest.AllowFailurePipeline)
    end
  end

  describe "phase 9: when_env (new format via interpreter)" do
    test "stage runs when env var is set, skips when absent" do
      path = Path.join(@tmp_dir, "when_env_pipeline.exs")

      File.write!(path, """
      stage :test do
        step :unit, cmd: "echo tests_pass"
      end

      stage :deploy, when: env("TINY_CI_DEPLOY_ENABLED") != nil do
        step :release, cmd: "echo deployed"
      end
      """)

      context = %{branch: "main", commit: "abc123", timestamp: DateTime.utc_now()}

      System.delete_env("TINY_CI_DEPLOY_ENABLED")

      {:ok, spec} = TinyCI.Discovery.load_pipeline(path)

      assert {:ok, results} = Executor.run_pipeline(spec.stages, context)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :deploy, status: :skipped}
             ] = results

      System.put_env("TINY_CI_DEPLOY_ENABLED", "true")

      assert {:ok, results} = Executor.run_pipeline(spec.stages, context)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :deploy, status: :passed}
             ] = results
    after
      System.delete_env("TINY_CI_DEPLOY_ENABLED")
    end
  end

  describe "phase 11: on_success / on_failure hooks" do
    defmodule HookNotifier do
      @moduledoc false
      def run(config, ctx) do
        path = config[:output_path]
        content = "result=#{ctx.pipeline_result},branch=#{ctx.branch}"
        File.write!(path, content)
        :ok
      end
    end

    test "on_success hook runs via Mix task when pipeline passes" do
      output_path = Path.join(@tmp_dir, "on_success_output.txt")
      path = Path.join(@tmp_dir, "pipeline_hooks_success.exs")

      File.write!(path, """
      on_success :write_result, cmd: "echo passed_hook > #{output_path}"
      on_failure :should_not_run, cmd: "echo failure_hook > #{output_path}_fail"

      stage :test, mode: :serial do
        step :pass, cmd: "true"
      end
      """)

      capture_io(fn ->
        result = Mix.Tasks.TinyCi.Run.run(["--file", path])
        assert result == :ok
      end)

      assert File.exists?(output_path)
      assert File.read!(output_path) =~ "passed_hook"
      refute File.exists?(output_path <> "_fail")
    end

    test "on_failure hook runs via Mix task when pipeline fails" do
      output_path = Path.join(@tmp_dir, "on_failure_output.txt")
      path = Path.join(@tmp_dir, "pipeline_hooks_failure.exs")

      File.write!(path, """
      on_success :should_not_run, cmd: "echo success_hook > #{output_path}_success"
      on_failure :write_result, cmd: "echo failed_hook > #{output_path}"

      stage :test, mode: :serial do
        step :fail, cmd: "false"
      end
      """)

      capture_io(fn ->
        result = Mix.Tasks.TinyCi.Run.run(["--file", path])
        assert result == {:error, :pipeline_failed}
      end)

      assert File.exists?(output_path)
      assert File.read!(output_path) =~ "failed_hook"
      refute File.exists?(output_path <> "_success")
    end

    test "module-based on_success hook receives context with pipeline_result" do
      output_path = Path.join(@tmp_dir, "hook_module_output.txt")

      code = """
      defmodule TinyCI.IntegrationTest.ModuleHookPipeline do
        use TinyCI.DSL

        on_success :notify, module: TinyCI.IntegrationTest.HookNotifier do
          set :output_path, "#{output_path}"
        end

        stage :test, mode: :serial do
          step :pass, cmd: "true"
        end
      end
      """

      module = compile_pipeline(code)
      stages = module.__pipeline__()
      hooks = module.__hooks__()
      context = %{branch: "main", commit: "abc123", store: %{}, timestamp: DateTime.utc_now()}

      assert {:ok, _results} = TinyCI.Executor.run_pipeline(stages, context)
      TinyCI.Hooks.run_hooks(hooks, :on_success, context)

      content = File.read!(output_path)
      assert content =~ "result=on_success"
      assert content =~ "branch=main"
    after
      :code.purge(TinyCI.IntegrationTest.ModuleHookPipeline)
      :code.delete(TinyCI.IntegrationTest.ModuleHookPipeline)
    end

    test "hook failure does not affect pipeline exit code" do
      path = Path.join(@tmp_dir, "pipeline_hooks_hook_fail.exs")

      File.write!(path, """
      on_success :fail_hook, cmd: "false"

      stage :test, mode: :serial do
        step :pass, cmd: "true"
      end
      """)

      {result, _output} =
        ExUnit.CaptureIO.with_io(fn ->
          Mix.Tasks.TinyCi.Run.run(["--file", path])
        end)

      assert result == :ok
    end

    test "pipeline with no hooks still works normally" do
      path = Path.join(@tmp_dir, "pipeline_no_hooks.exs")

      File.write!(path, """
      stage :test, mode: :serial do
        step :pass, cmd: "echo ok"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end
  end

  describe "phase 9: when_file_changed (new format via interpreter)" do
    test "stage runs when matching files changed, skips otherwise" do
      path = Path.join(@tmp_dir, "when_file_pipeline.exs")

      File.write!(path, """
      stage :test, when: file_changed?("lib/**/*.ex") do
        step :unit, cmd: "echo tests_pass"
      end

      stage :docs, when: file_changed?("*.md") do
        step :build_docs, cmd: "echo docs_built"
      end
      """)

      {:ok, spec} = TinyCI.Discovery.load_pipeline(path)

      ctx_lib = %{
        branch: "main",
        commit: "abc123",
        changed_files: ["lib/tiny_ci/executor.ex"],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, results} = Executor.run_pipeline(spec.stages, ctx_lib)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :docs, status: :skipped}
             ] = results

      ctx_md = %{
        branch: "main",
        commit: "def456",
        changed_files: ["README.md"],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, results} = Executor.run_pipeline(spec.stages, ctx_md)

      assert [
               %StageResult{name: :test, status: :skipped},
               %StageResult{name: :docs, status: :passed}
             ] = results

      ctx_both = %{
        branch: "main",
        commit: "ghi789",
        changed_files: ["lib/app.ex", "CHANGELOG.md"],
        timestamp: DateTime.utc_now()
      }

      assert {:ok, results} = Executor.run_pipeline(spec.stages, ctx_both)

      assert [
               %StageResult{name: :test, status: :passed},
               %StageResult{name: :docs, status: :passed}
             ] = results
    end
  end
end
