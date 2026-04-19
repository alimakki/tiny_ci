defmodule TinyCI.DSL.InterpreterTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.Interpreter
  alias TinyCI.{Hook, PipelineSpec, Stage, Step}

  @tmp_dir "test/tmp/interpreter"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_pipeline(name, content) do
    path = Path.join(@tmp_dir, "#{name}.exs")
    File.write!(path, content)
    path
  end

  describe "interpret_file/1" do
    test "returns error for non-existent file" do
      assert {:error, :file_not_found} =
               Interpreter.interpret_file("/nonexistent/pipeline.exs")
    end

    test "returns parse error for invalid Elixir syntax" do
      path = write_pipeline("bad_syntax", "stage :test do end end")
      assert {:error, {:parse_error, _}} = Interpreter.interpret_file(path)
    end

    test "returns validation error for disallowed constructs" do
      path =
        write_pipeline("bad_construct", """
        defmodule Foo do
        end
        """)

      assert {:error, {:validation_error, _}} = Interpreter.interpret_file(path)
    end

    test "returns a PipelineSpec on success" do
      path =
        write_pipeline("simple", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{}} = Interpreter.interpret_file(path)
    end
  end

  describe "pipeline name" do
    test "uses name directive when present" do
      path =
        write_pipeline("pipeline", """
        name :my_custom_pipeline

        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{name: :my_custom_pipeline}} = Interpreter.interpret_file(path)
    end

    test "derives name from filename when no name directive" do
      path =
        write_pipeline("deploy", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{name: :deploy}} = Interpreter.interpret_file(path)
    end
  end

  describe "stages" do
    test "produces Stage structs in declaration order" do
      path =
        write_pipeline("multi_stage", """
        stage :test do
          step :unit, cmd: "mix test"
        end

        stage :deploy do
          step :release, cmd: "make release"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [s1, s2]}} = Interpreter.interpret_file(path)
      assert s1.name == :test
      assert s2.name == :deploy
    end

    test "defaults mode to :parallel" do
      path =
        write_pipeline("default_mode", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert stage.mode == :parallel
    end

    test "respects explicit :serial mode" do
      path =
        write_pipeline("serial_mode", """
        stage :deploy, mode: :serial do
          step :release, cmd: "make release"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert stage.mode == :serial
    end

    test "stores when condition as quoted AST" do
      path =
        write_pipeline("conditional", """
        stage :deploy, when: branch() == "main" do
          step :release, cmd: "make release"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert stage.when_condition != nil
      refute is_function(stage.when_condition)
    end

    test "nil when_condition for unconditional stages" do
      path =
        write_pipeline("unconditional", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert stage.when_condition == nil
    end

    test "stage with no steps produces empty steps list" do
      path =
        write_pipeline("empty_stage", """
        stage :test do
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert stage.steps == []
    end
  end

  describe "steps" do
    test "produces Step structs" do
      path =
        write_pipeline("steps", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{}] = stage.steps
    end

    test "preserves step name and cmd" do
      path =
        write_pipeline("step_opts", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{name: :unit, cmd: "mix test"}] = stage.steps
    end

    test "preserves step order" do
      path =
        write_pipeline("step_order", """
        stage :test do
          step :first, cmd: "echo first"
          step :second, cmd: "echo second"
          step :third, cmd: "echo third"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [:first, :second, :third] = Enum.map(stage.steps, & &1.name)
    end

    test "preserves timeout" do
      path =
        write_pipeline("timeout", """
        stage :test do
          step :slow, cmd: "sleep 10", timeout: 5000
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{timeout: 5000}] = stage.steps
    end

    test "defaults timeout to nil" do
      path =
        write_pipeline("no_timeout", """
        stage :test do
          step :fast, cmd: "echo hi"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{timeout: nil}] = stage.steps
    end

    test "preserves allow_failure" do
      path =
        write_pipeline("allow_failure", """
        stage :test do
          step :flaky, cmd: "exit 1", allow_failure: true
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{allow_failure: true}] = stage.steps
    end

    test "defaults allow_failure to false" do
      path =
        write_pipeline("no_allow_failure", """
        stage :test do
          step :critical, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{allow_failure: false}] = stage.steps
    end

    test "preserves env map" do
      path =
        write_pipeline("env", """
        stage :test do
          step :check, cmd: "echo $FOO", env: %{"FOO" => "bar", "BAZ" => "qux"}
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{env: env}] = stage.steps
      assert env == %{"FOO" => "bar", "BAZ" => "qux"}
    end

    test "defaults env to empty map" do
      path =
        write_pipeline("no_env", """
        stage :test do
          step :plain, cmd: "echo hi"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{env: %{}}] = stage.steps
    end

    test "module step resolves module alias" do
      path =
        write_pipeline("module_step", """
        stage :deploy do
          step :push, module: TinyCI.DSL.InterpreterTest.DummyStep
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{module: TinyCI.DSL.InterpreterTest.DummyStep}] = stage.steps
    end

    test "module step with set block produces callable config_block" do
      path =
        write_pipeline("set_block", """
        stage :deploy do
          step :push, module: TinyCI.DSL.InterpreterTest.DummyStep do
            set :app, "my-app"
            set :region, "us-east-1"
          end
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      [step] = stage.steps
      assert is_function(step.config_block, 0)
      assert step.config_block.() == [app: "my-app", region: "us-east-1"]
    end

    test "step without set block has nil config_block" do
      path =
        write_pipeline("no_set", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{stages: [stage]}} = Interpreter.interpret_file(path)
      assert [%Step{config_block: nil}] = stage.steps
    end
  end

  describe "hooks" do
    test "on_success hook is captured" do
      path =
        write_pipeline("on_success", """
        on_success :notify, cmd: "echo passed"

        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{hooks: %{on_success: [hook]}}} = Interpreter.interpret_file(path)
      assert %Hook{name: :notify, cmd: "echo passed"} = hook
    end

    test "on_failure hook is captured" do
      path =
        write_pipeline("on_failure", """
        on_failure :alert, cmd: "echo failed"

        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{hooks: %{on_failure: [hook]}}} = Interpreter.interpret_file(path)
      assert %Hook{name: :alert, cmd: "echo failed"} = hook
    end

    test "multiple hooks preserved in order" do
      path =
        write_pipeline("multi_hooks", """
        on_success :first, cmd: "echo first"
        on_success :second, cmd: "echo second"

        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{hooks: %{on_success: hooks}}} = Interpreter.interpret_file(path)
      assert [%Hook{name: :first}, %Hook{name: :second}] = hooks
    end

    test "empty hooks when none declared" do
      path =
        write_pipeline("no_hooks", """
        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{hooks: hooks}} = Interpreter.interpret_file(path)
      assert hooks.on_success == []
      assert hooks.on_failure == []
    end

    test "module hook with set block produces callable config_block" do
      path =
        write_pipeline("module_hook", """
        on_success :notify, module: TinyCI.DSL.InterpreterTest.DummyHook do
          set :channel, "#deploys"
        end

        stage :test do
          step :unit, cmd: "mix test"
        end
        """)

      assert {:ok, %PipelineSpec{hooks: %{on_success: [hook]}}} = Interpreter.interpret_file(path)
      assert is_function(hook.config_block, 0)
      assert hook.config_block.() == [channel: "#deploys"]
    end
  end

  # Dummy modules referenced in pipeline files above
  defmodule DummyStep do
    @moduledoc false
    def execute(_config, _ctx), do: :ok
  end

  defmodule DummyHook do
    @moduledoc false
    def run(_config, _ctx), do: :ok
  end
end
