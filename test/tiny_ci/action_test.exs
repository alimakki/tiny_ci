defmodule TinyCI.ActionTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action
  alias TinyCI.Action.Metadata
  alias TinyCI.{Hook, PipelineSpec, Stage, Step}

  defmodule ProperAction do
    @moduledoc false
    use TinyCI.Action

    @impl TinyCI.Action
    def execute(_config, _ctx), do: :ok

    @impl TinyCI.Action
    def metadata do
      %Metadata{name: "proper", version: "1.0.0", capabilities: [:network]}
    end
  end

  defmodule LegacyAction do
    @moduledoc false
    # Old convention: exports execute/2 but does not `use TinyCI.Action`.
    def execute(_config, _ctx), do: {:ok, %{ran: true}}
  end

  defmodule NotAnAction do
    @moduledoc false
    def something_else(_), do: :ok
  end

  defmodule ProperHook do
    @moduledoc false
    def run(_config, _ctx), do: :ok
  end

  describe "behaviour" do
    test "ProperAction satisfies the execute/2 callback" do
      assert ProperAction.execute([], %TinyCI.Context{}) == :ok
    end

    test "metadata/0 is optional — a module may omit it" do
      assert function_exported?(LegacyAction, :metadata, 0) == false
    end
  end

  describe "implements?/1" do
    test "true for a module that exports execute/2 via the behaviour" do
      assert Action.implements?(ProperAction)
    end

    test "true for a legacy module exporting execute/2 by convention" do
      assert Action.implements?(LegacyAction)
    end

    test "false for a module that does not export execute/2" do
      refute Action.implements?(NotAnAction)
    end

    test "false for a module that does not exist" do
      refute Action.implements?(:no_such_module_anywhere)
    end
  end

  describe "behaviour_adopted?/1" do
    test "true when the module uses @behaviour TinyCI.Action" do
      assert Action.behaviour_adopted?(ProperAction)
    end

    test "false for a legacy module that only follows the convention" do
      refute Action.behaviour_adopted?(LegacyAction)
    end
  end

  describe "metadata/1" do
    test "returns the declared metadata struct" do
      assert %Metadata{name: "proper", capabilities: [:network]} = Action.metadata(ProperAction)
    end

    test "returns nil when the module declares no metadata" do
      assert Action.metadata(LegacyAction) == nil
    end

    test "returns nil for a non-existent module" do
      assert Action.metadata(:no_such_module_anywhere) == nil
    end
  end

  describe "validate_spec/1" do
    defp spec_with_step(module) do
      %PipelineSpec{
        name: :p,
        stages: [%Stage{name: :deploy, steps: [%Step{name: :go, module: module}]}],
        hooks: %{on_success: [], on_failure: []}
      }
    end

    defp spec_with_hook(hook) do
      %PipelineSpec{
        name: :p,
        stages: [],
        hooks: %{on_success: [hook], on_failure: []}
      }
    end

    test "ok when every module step implements the behaviour" do
      assert Action.validate_spec(spec_with_step(ProperAction)) == :ok
    end

    test "ok for legacy convention module steps (back-compat)" do
      assert Action.validate_spec(spec_with_step(LegacyAction)) == :ok
    end

    test "ok for shell-command steps with no module" do
      spec = %PipelineSpec{
        name: :p,
        stages: [%Stage{name: :test, steps: [%Step{name: :unit, cmd: "mix test"}]}],
        hooks: %{on_success: [], on_failure: []}
      }

      assert Action.validate_spec(spec) == :ok
    end

    test "error with a descriptive message when a step module lacks execute/2" do
      assert {:error, {:invalid_action, [msg]}} =
               Action.validate_spec(spec_with_step(NotAnAction))

      assert msg =~ "go"
      assert msg =~ "deploy"
      assert msg =~ "execute/2"
      assert msg =~ inspect(NotAnAction)
    end

    test "error when a step module cannot be loaded" do
      assert {:error, {:invalid_action, [msg]}} =
               Action.validate_spec(spec_with_step(NoSuchActionModule))

      assert msg =~ "NoSuchActionModule"
    end

    test "ok when a module hook exports run/2" do
      hook = %Hook{name: :notify, module: ProperHook}
      assert Action.validate_spec(spec_with_hook(hook)) == :ok
    end

    test "ok for shell-command hooks with no module" do
      hook = %Hook{name: :notify, cmd: "echo done"}
      assert Action.validate_spec(spec_with_hook(hook)) == :ok
    end

    test "error when a module hook does not export run/2" do
      hook = %Hook{name: :notify, module: NotAnAction}

      assert {:error, {:invalid_action, [msg]}} = Action.validate_spec(spec_with_hook(hook))
      assert msg =~ "notify"
      assert msg =~ "run/2"
    end
  end
end
