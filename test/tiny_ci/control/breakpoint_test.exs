defmodule TinyCI.Control.BreakpointTest do
  use ExUnit.Case, async: true

  alias TinyCI.Control.Breakpoint
  alias TinyCI.{Stage, Step}

  doctest TinyCI.Control.Breakpoint

  describe "parse/1" do
    test "parses a stage-scoped breakpoint in both phases" do
      assert {:ok, %Breakpoint{phase: :before, stage: :deploy, step: nil}} =
               Breakpoint.parse("before:deploy")

      assert {:ok, %Breakpoint{phase: :after, stage: :deploy, step: nil}} =
               Breakpoint.parse("after:deploy")
    end

    test "parses a step-scoped breakpoint" do
      assert {:ok, %Breakpoint{phase: :after, stage: :test, step: :unit}} =
               Breakpoint.parse("after:test.unit")
    end

    test "leaves the T11 condition slot empty" do
      assert {:ok, %Breakpoint{condition: nil}} = Breakpoint.parse("before:deploy")
    end

    test "tolerates surrounding whitespace and leading colons on names" do
      assert {:ok, %Breakpoint{phase: :before, stage: :test, step: :unit}} =
               Breakpoint.parse("  before: :test.:unit  ")
    end

    test "rejects an unknown phase, naming the valid ones" do
      assert {:error, message} = Breakpoint.parse("during:test")
      assert message =~ ~s(unknown breakpoint phase "during")
      assert message =~ ~s("before")
      assert message =~ ~s("after")
    end

    test "rejects a spec with no phase separator, showing the grammar" do
      assert {:error, message} = Breakpoint.parse("deploy")
      assert message =~ ~s(invalid breakpoint "deploy")
      assert message =~ "before:STAGE.STEP"
    end

    test "rejects a spec that names no target" do
      assert {:error, message} = Breakpoint.parse("before:")
      assert message =~ "names no target"
    end

    test "rejects a spec with an empty step" do
      assert {:error, message} = Breakpoint.parse("after:test.")
      assert message =~ "names no target"
    end
  end

  describe "format/1" do
    test "round-trips every spec shape" do
      for spec <- ["before:deploy", "after:deploy", "before:test.unit", "after:test.unit"] do
        assert {:ok, breakpoint} = Breakpoint.parse(spec)
        assert Breakpoint.format(breakpoint) == spec
      end
    end
  end

  describe "scope/1" do
    test "is :stage without a step and :step with one" do
      assert Breakpoint.scope(%Breakpoint{phase: :before, stage: :t}) == :stage
      assert Breakpoint.scope(%Breakpoint{phase: :before, stage: :t, step: :u}) == :step
    end
  end

  describe "match?/2" do
    test "matches only its own phase, scope, stage, and step" do
      bp = %Breakpoint{phase: :before, stage: :test, step: :unit}

      assert Breakpoint.match?(bp, {:before, :step, :test, :unit})
      refute Breakpoint.match?(bp, {:after, :step, :test, :unit})
      refute Breakpoint.match?(bp, {:before, :step, :test, :other})
      refute Breakpoint.match?(bp, {:before, :step, :build, :unit})
    end

    test "a stage breakpoint does not fire for steps inside that stage" do
      bp = %Breakpoint{phase: :before, stage: :test}

      assert Breakpoint.match?(bp, {:before, :stage, :test, nil})
      refute Breakpoint.match?(bp, {:before, :step, :test, :unit})
    end
  end

  describe "validate/2" do
    setup do
      stages = [
        %Stage{name: :test, steps: [%Step{name: :unit, cmd: "true"}]},
        %Stage{name: :deploy, steps: [%Step{name: :push, cmd: "true"}]}
      ]

      {:ok, stages: stages}
    end

    test "accepts breakpoints whose targets exist", %{stages: stages} do
      breakpoints = [
        %Breakpoint{phase: :before, stage: :deploy},
        %Breakpoint{phase: :after, stage: :test, step: :unit}
      ]

      assert Breakpoint.validate(breakpoints, stages) == :ok
    end

    test "rejects an unknown stage and lists what is available", %{stages: stages} do
      breakpoints = [%Breakpoint{phase: :before, stage: :nope}]

      assert {:error, [message]} = Breakpoint.validate(breakpoints, stages)
      assert message =~ "unknown stage :nope"
      assert message =~ "Available stages: :test, :deploy"
    end

    test "rejects an unknown step and lists that stage's steps", %{stages: stages} do
      breakpoints = [%Breakpoint{phase: :before, stage: :test, step: :nope}]

      assert {:error, [message]} = Breakpoint.validate(breakpoints, stages)
      assert message =~ "unknown step :nope in stage :test"
      assert message =~ "Available steps: :unit"
    end

    test "reports every bad target rather than stopping at the first", %{stages: stages} do
      breakpoints = [
        %Breakpoint{phase: :before, stage: :nope},
        %Breakpoint{phase: :after, stage: :test, step: :missing}
      ]

      assert {:error, errors} = Breakpoint.validate(breakpoints, stages)
      assert length(errors) == 2
    end
  end
end
