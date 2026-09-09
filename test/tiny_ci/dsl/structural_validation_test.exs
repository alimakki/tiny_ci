defmodule TinyCI.DSL.StructuralValidationTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.Interpreter

  defp assert_validation_error(source, fragment) do
    assert {:error, {:validation_error, messages}} =
             Interpreter.interpret_string(source, "structure.exs")

    assert Enum.any?(messages, &String.contains?(&1, fragment))
    diagnostics = Interpreter.diagnose_string(source)
    assert Enum.map(diagnostics, & &1.message) == messages
    assert Enum.all?(diagnostics, &(&1.severity == :error and &1.line > 0 and &1.column > 0))
  end

  describe "step and hook actions" do
    for directive <- ["step", "on_success", "on_failure"],
        options <- [
          "",
          ", []",
          ", timeout: 100",
          ", cmd: \"ok\", module: MissingModule",
          ", cmd: \"first\", cmd: \"second\"",
          " do\nset :value, 1\nend"
        ] do
      test "#{directive} requires exactly one action with #{inspect(options)}" do
        body = "#{unquote(directive)} :run#{unquote(options)}"
        source = if unquote(directive) == "step", do: "stage :build do\n#{body}\nend", else: body
        assert_validation_error(source, "exactly one of :cmd or :module")
      end
    end
  end

  describe "required nested options" do
    for {option, value, missing} <- [
          {"artifact", "[paths: [\"build\"]]", "name"},
          {"artifact", "[name: \"release\"]", "paths"},
          {"artifact", "[]", "name"},
          {"cache", "[paths: [\"deps\"]]", "key"},
          {"cache", "[key: \"mix.lock\"]", "paths"},
          {"cache", "[]", "key"}
        ] do
      test "#{option} #{value} requires #{missing}" do
        assert_validation_error(
          "stage :build do\nstep :run, cmd: \"ok\", #{unquote(option)}: #{unquote(value)}\nend",
          "#{unquote(option)} requires :#{unquote(missing)}"
        )
      end
    end
  end

  describe "matrix dimensions" do
    test "rejects empty dimension values instead of silently running no jobs" do
      assert_validation_error(
        "stage :test, matrix: [otp: []] do\nstep :test, cmd: \"ok\"\nend",
        "Matrix values for :otp must be nonempty"
      )
    end

    test "keeps empty stages, an absent matrix, and an explicit empty matrix valid" do
      for options <- ["", ", matrix: []"] do
        assert {:ok, %{stages: [stage]}} =
                 Interpreter.interpret_string("stage :empty#{options} do\nend", "empty.exs")

        assert stage.mode == :parallel
        assert stage.needs == []
        assert stage.matrix == []
        assert stage.steps == []
      end
    end
  end

  describe "unique names" do
    test "rejects repeated stage names" do
      assert_validation_error(
        "stage :build do\nend\nstage :build do\nend",
        "Duplicate stage name :build"
      )
    end

    test "rejects repeated step names within a stage" do
      assert_validation_error(
        "stage :build do\nstep :run, cmd: \"a\"\nstep :run, cmd: \"b\"\nend",
        "Duplicate step name :run"
      )
    end

    test "allows the same step name in different stages" do
      source = """
      stage :one do
        step :run, cmd: "ok"
      end
      stage :two do
        step :run, cmd: "ok"
      end
      """

      assert {:ok, _} = Interpreter.interpret_string(source, "reuse.exs")
      assert Interpreter.diagnose_string(source) == []
    end

    test "rejects multiple name directives even when they agree" do
      for second <- [":first", ":second"] do
        assert_validation_error("name :first\nname #{second}", "Only one name directive")
      end
    end
  end

  describe "malformed option structures" do
    for source <- [
          "stage :build, [123]",
          "stage :build, [123] do\nend",
          "stage :build, [{\"mode\", :serial}] do\nend",
          "stage :build do\nstep :run, [123]\nend",
          "stage :build do\nstep :run, [123] do\nset :x, 1\nend\nend",
          "on_success :notify, [123]",
          "on_failure :notify, [123] do\nset :x, 1\nend",
          "stage :build do\nstep :run, cmd: \"ok\", cache: [123]\nend",
          "stage :build do\nstep :run, cmd: \"ok\", artifact: [123]\nend",
          "stage :build do\nstep :run, cmd: \"ok\", cache: [{1, 2}]\nend",
          "stage :build do\nstep :run, cmd: \"ok\", artifact: [{1, 2}]\nend"
        ] do
      test "returns keyword diagnostics for #{inspect(source)}" do
        assert_validation_error(unquote(source), "keyword")
      end
    end

    test "rejects map updates in env without a construction exception" do
      assert_validation_error(
        "stage :build do\nstep :run, cmd: \"ok\", env: %{existing | x: \"y\"}\nend",
        "Env map"
      )
    end

    test "rejects dynamic module aliases without a construction exception" do
      for body <- [
            "step :run, module: __MODULE__.Action",
            "on_success :run, module: __MODULE__.Action"
          ] do
        source =
          if String.starts_with?(body, "step"), do: "stage :build do\n#{body}\nend", else: body

        assert_validation_error(source, ":module")
      end
    end
  end
end
