defmodule TinyCI.PipelineTest do
  use ExUnit.Case, async: true

  alias TinyCI.{Hook, Pipeline, Stage, Step}

  describe "normalize_stage/1" do
    test "converts a raw tuple to a Stage struct" do
      result = Pipeline.normalize_stage({:build, [], []})
      assert %Stage{name: :build} = result
    end

    test "defaults mode to :parallel" do
      result = Pipeline.normalize_stage({:build, [], []})
      assert result.mode == :parallel
    end

    test "extracts mode from opts" do
      result = Pipeline.normalize_stage({:deploy, [mode: :serial], []})
      assert result.mode == :serial
    end

    test "extracts when_condition from opts" do
      condition = fn -> true end
      result = Pipeline.normalize_stage({:deploy, [when: condition], []})
      assert result.when_condition == condition
    end

    test "normalizes steps into Step structs" do
      steps = [[name: :unit, cmd: "mix test"]]
      result = Pipeline.normalize_stage({:test, [], steps})
      assert [%Step{name: :unit, cmd: "mix test"}] = result.steps
    end

    test "reverses raw step order (DSL accumulates in reverse)" do
      steps = [
        [name: :second, cmd: "echo second"],
        [name: :first, cmd: "echo first"]
      ]

      result = Pipeline.normalize_stage({:test, [], steps})
      assert [%Step{name: :first}, %Step{name: :second}] = result.steps
    end

    test "step defaults" do
      steps = [[name: :unit, cmd: "mix test"]]
      result = Pipeline.normalize_stage({:test, [], steps})
      [step] = result.steps

      assert step.mode == :inherit
      assert step.requires == []
      assert step.env == %{}
      assert step.module == nil
      assert step.config_block == nil
      assert step.allow_failure == false
    end

    test "extracts allow_failure from step opts" do
      steps = [[name: :flaky, cmd: "echo flaky", allow_failure: true]]
      result = Pipeline.normalize_stage({:test, [], steps})
      [step] = result.steps

      assert step.allow_failure == true
    end

    test "normalizes module step with config_block" do
      block = fn -> [app: "my-app"] end
      steps = [[name: :prod, module: SomeModule, config_block: block]]
      result = Pipeline.normalize_stage({:deploy, [], steps})
      [step] = result.steps

      assert step.module == SomeModule
      assert step.config_block == block
    end
  end

  describe "normalize_hook/1" do
    test "converts a keyword list to a Hook struct" do
      result = Pipeline.normalize_hook(name: :notify, cmd: "echo done")
      assert %Hook{} = result
    end

    test "extracts name and cmd" do
      result = Pipeline.normalize_hook(name: :notify, cmd: "echo done")
      assert result.name == :notify
      assert result.cmd == "echo done"
    end

    test "extracts module" do
      result = Pipeline.normalize_hook(name: :hook, module: SomeModule)
      assert result.module == SomeModule
    end

    test "extracts config_block" do
      block = fn -> [channel: "#deploys"] end
      result = Pipeline.normalize_hook(name: :hook, module: SomeModule, config_block: block)
      assert result.config_block == block
    end

    test "extracts env map" do
      result = Pipeline.normalize_hook(name: :hook, cmd: "echo hi", env: %{"FOO" => "bar"})
      assert result.env == %{"FOO" => "bar"}
    end

    test "defaults env to empty map when not specified" do
      result = Pipeline.normalize_hook(name: :hook, cmd: "echo hi")
      assert result.env == %{}
    end

    test "extracts timeout" do
      result = Pipeline.normalize_hook(name: :hook, cmd: "echo hi", timeout: 5_000)
      assert result.timeout == 5_000
    end

    test "defaults timeout to nil when not specified" do
      result = Pipeline.normalize_hook(name: :hook, cmd: "echo hi")
      assert result.timeout == nil
    end

    test "cmd is nil when not specified" do
      result = Pipeline.normalize_hook(name: :hook, module: SomeModule)
      assert result.cmd == nil
    end

    test "module is nil when not specified" do
      result = Pipeline.normalize_hook(name: :hook, cmd: "echo hi")
      assert result.module == nil
    end

    test "config_block is nil when not specified" do
      result = Pipeline.normalize_hook(name: :hook, cmd: "echo hi")
      assert result.config_block == nil
    end
  end
end
