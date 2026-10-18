defmodule TinyCI.DSL.NetworkOptionTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.{Interpreter, Spec, Validator}

  defp pipeline(option) do
    """
    stage :build, #{option} do
      step :test, cmd: "true"
    end
    """
  end

  describe "network: stage option" do
    test "defaults to true" do
      assert {:ok, %{stages: [%{network: true}]}} =
               Interpreter.interpret_string(pipeline("mode: :serial"), "pipeline.exs")
    end

    test "accepts false" do
      assert {:ok, %{stages: [%{network: false}]}} =
               Interpreter.interpret_string(pipeline("network: false"), "pipeline.exs")
    end

    test "rejects a non-boolean" do
      assert {:error, {:validation_error, messages}} =
               Interpreter.interpret_string(pipeline(~s(network: "none")), "pipeline.exs")

      assert Enum.any?(messages, &(&1 =~ "network must be true or false"))
    end

    test "is advertised by the DSL spec" do
      assert %Spec.Entry{contexts: [:stage], type: "boolean"} = Spec.lookup(:network, :stage)
    end

    test "is rejected on a step" do
      source = """
      stage :build do
        step :test, cmd: "true", network: false
      end
      """

      assert {:error, {:validation_error, messages}} =
               Interpreter.interpret_string(source, "pipeline.exs")

      assert Enum.any?(messages, &(&1 =~ "Unknown step option"))
    end
  end

  describe "Validator" do
    test "accepts boolean true/false and rejects anything else" do
      for value <- ["true", "false"] do
        ast = Code.string_to_quoted!(pipeline(~s(network: #{value})))
        assert Validator.validate(ast) == :ok
      end

      ast = Code.string_to_quoted!(pipeline("network: :sometimes"))
      assert {:error, [message]} = Validator.validate(ast)
      assert message =~ "network must be true or false"
    end
  end
end
