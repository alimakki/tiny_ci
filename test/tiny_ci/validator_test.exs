defmodule TinyCI.ValidatorTest do
  use ExUnit.Case, async: true

  alias TinyCI.Validator

  describe "validate/1" do
    test "returns :ok for a valid pipeline" do
      stages = [
        {:build, [mode: :parallel],
         [
           [name: :compile, cmd: "mix compile"],
           [name: :test, cmd: "mix test"]
         ]},
        {:deploy, [mode: :serial],
         [
           [name: :release, cmd: "mix release"]
         ]}
      ]

      assert :ok = Validator.validate(stages)
    end

    test "returns error for duplicate step names within a stage" do
      stages = [
        {:test, [],
         [
           [name: :unit, cmd: "mix test"],
           [name: :unit, cmd: "mix test --cover"]
         ]}
      ]

      assert {:error, errors} = Validator.validate(stages)
      assert length(errors) == 1
      assert hd(errors) =~ "duplicate step"
      assert hd(errors) =~ ":unit"
      assert hd(errors) =~ ":test"
    end

    test "returns error for step missing both cmd and module" do
      stages = [
        {:build, [],
         [
           [name: :empty]
         ]}
      ]

      assert {:error, errors} = Validator.validate(stages)
      assert length(errors) == 1
      assert hd(errors) =~ ":empty"
      assert hd(errors) =~ "cmd"
      assert hd(errors) =~ "module"
    end

    test "returns error for step with both cmd and module" do
      stages = [
        {:deploy, [],
         [
           [name: :ambiguous, cmd: "echo deploy", module: SomeModule]
         ]}
      ]

      assert {:error, errors} = Validator.validate(stages)
      assert length(errors) == 1
      assert hd(errors) =~ ":ambiguous"
      assert hd(errors) =~ "both"
    end

    test "allows module-only step" do
      stages = [
        {:deploy, [],
         [
           [name: :release, module: SomeModule]
         ]}
      ]

      assert :ok = Validator.validate(stages)
    end

    test "collects multiple errors across stages" do
      stages = [
        {:test, [],
         [
           [name: :unit, cmd: "mix test"],
           [name: :unit, cmd: "mix test --cover"]
         ]},
        {:deploy, [],
         [
           [name: :empty]
         ]}
      ]

      assert {:error, errors} = Validator.validate(stages)
      assert length(errors) == 2
    end

    test "returns :ok for empty pipeline" do
      assert :ok = Validator.validate([])
    end

    test "returns :ok for stage with no steps" do
      stages = [{:empty, [], []}]
      assert :ok = Validator.validate(stages)
    end

    test "duplicate step names across different stages are allowed" do
      stages = [
        {:test, [], [[name: :run, cmd: "mix test"]]},
        {:lint, [], [[name: :run, cmd: "mix credo"]]}
      ]

      assert :ok = Validator.validate(stages)
    end
  end
end
