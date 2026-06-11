defmodule TinyCI.ActionValidationTest do
  @moduledoc """
  Verifies that the loader rejects `module:` step / hook targets that do not
  implement the action contract **before** execution, with a descriptive error.
  """
  use ExUnit.Case, async: true

  alias TinyCI.DSL.Interpreter

  @tmp_dir "test/tmp/action_validation"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  defp write_pipeline(name, contents) do
    path = Path.join(@tmp_dir, "#{name}.exs")
    File.write!(path, contents)
    path
  end

  defmodule GoodStep do
    @moduledoc false
    use TinyCI.Action

    @impl TinyCI.Action
    def execute(_config, _ctx), do: :ok
  end

  defmodule GoodHook do
    @moduledoc false
    def run(_config, _ctx), do: :ok
  end

  defmodule BadStep do
    @moduledoc false
    def nope, do: :ok
  end

  test "accepts a pipeline whose module step implements the behaviour" do
    path =
      write_pipeline("good", """
      stage :deploy do
        step :push, module: TinyCI.ActionValidationTest.GoodStep
      end
      """)

    assert {:ok, _spec} = Interpreter.interpret_file(path)
  end

  test "accepts a pipeline whose module hook exports run/2" do
    path =
      write_pipeline("good_hook", """
      stage :test do
        step :unit, cmd: "mix test"
      end

      on_success :notify, module: TinyCI.ActionValidationTest.GoodHook
      """)

    assert {:ok, _spec} = Interpreter.interpret_file(path)
  end

  test "rejects a module step that does not implement execute/2" do
    path =
      write_pipeline("bad", """
      stage :deploy do
        step :push, module: TinyCI.ActionValidationTest.BadStep
      end
      """)

    assert {:error, {:invalid_action, [msg]}} = Interpreter.interpret_file(path)
    assert msg =~ "execute/2"
    assert msg =~ "push"
  end

  test "rejects a module hook that does not export run/2" do
    path =
      write_pipeline("bad_hook", """
      stage :test do
        step :unit, cmd: "mix test"
      end

      on_failure :notify, module: TinyCI.ActionValidationTest.BadStep
      """)

    assert {:error, {:invalid_action, [msg]}} = Interpreter.interpret_file(path)
    assert msg =~ "run/2"
  end

  test "rejects a module step referring to a non-existent module" do
    path =
      write_pipeline("missing", """
      stage :deploy do
        step :push, module: Definitely.Not.A.Real.Module
      end
      """)

    assert {:error, {:invalid_action, [msg]}} = Interpreter.interpret_file(path)
    assert msg =~ "Definitely.Not.A.Real.Module"
  end
end
