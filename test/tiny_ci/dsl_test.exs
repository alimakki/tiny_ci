defmodule TinyCI.DSLTest do
  use ExUnit.Case, async: true

  defmodule SimplePipeline do
    use TinyCI.DSL

    stage :build do
      step(:compile, cmd: "echo compile")
      step(:check, cmd: "echo check")
    end
  end

  defmodule ParallelPipeline do
    use TinyCI.DSL

    stage :test, mode: :parallel do
      step(:unit, cmd: "echo unit")
      step(:lint, cmd: "echo lint")
    end
  end

  defmodule SerialPipeline do
    use TinyCI.DSL

    stage :deploy, mode: :serial do
      step(:migrate, cmd: "echo migrate")
      step(:release, cmd: "echo release")
    end
  end

  defmodule MultiStagePipeline do
    use TinyCI.DSL

    stage :test do
      step(:unit, cmd: "echo test")
    end

    stage :build do
      step(:compile, cmd: "echo build")
    end
  end

  defmodule GenericConfigPipeline do
    use TinyCI.DSL

    stage :deploy, mode: :serial do
      step :prod, module: TinyCI.DSLTest.DummyStep do
        set(:app, "my-app")
        set(:strategy, :heroku)
      end
    end
  end

  defmodule SingleSetPipeline do
    use TinyCI.DSL

    stage :notify, mode: :serial do
      step :slack, module: TinyCI.DSLTest.DummyStep do
        set(:channel, "#deploys")
      end
    end
  end

  defmodule ManySetPipeline do
    use TinyCI.DSL

    stage :deploy, mode: :serial do
      step :full, module: TinyCI.DSLTest.DummyStep do
        set(:app, "my-app")
        set(:region, "us-east-1")
        set(:replicas, 3)
        set(:verbose, true)
      end
    end
  end

  defmodule TimeoutPipeline do
    use TinyCI.DSL

    stage :test, mode: :serial do
      step(:fast, cmd: "echo fast", timeout: 5_000)
      step(:slow, cmd: "sleep 60", timeout: 60_000)
      step(:no_timeout, cmd: "echo ok")
    end
  end

  defmodule ConditionalPipeline do
    use TinyCI.DSL

    stage :deploy, when: when_branch("main") do
      step(:release, cmd: "echo deploy")
    end
  end

  defmodule MultiConditionalPipeline do
    use TinyCI.DSL

    stage :test do
      step(:unit, cmd: "echo test")
    end

    stage :deploy, when: when_branch("main") do
      step(:release, cmd: "echo deploy")
    end
  end

  defmodule EnvPipeline do
    use TinyCI.DSL

    stage :test, mode: :serial do
      step(:check, cmd: "echo ok", env: %{"TINY_CI_FOO" => "bar", "TINY_CI_BAZ" => "qux"})
      step(:no_env, cmd: "echo plain")
    end
  end

  defmodule ModuleOnlyPipeline do
    use TinyCI.DSL

    stage :deploy, mode: :serial do
      step(:go, module: TinyCI.DSLTest.DummyStep)
    end
  end

  defmodule AllowFailurePipeline do
    use TinyCI.DSL

    stage :test, mode: :serial do
      step(:flaky, cmd: "echo flaky", allow_failure: true)
      step(:critical, cmd: "echo critical")
    end
  end

  defmodule MixedModePipeline do
    use TinyCI.DSL

    stage :test, mode: :parallel do
      step(:unit, cmd: "echo unit")
      step(:lint, cmd: "echo lint")
    end

    stage :deploy, mode: :serial do
      step(:release, cmd: "echo release")
    end
  end

  defmodule DummyStep do
    @moduledoc false
    def execute(_config, _ctx), do: :ok
  end

  defmodule DummyHook do
    @moduledoc false
    def run(_config, _ctx), do: :ok
  end

  defmodule SuccessHookPipeline do
    use TinyCI.DSL

    on_success(:notify, cmd: "echo passed")
    on_failure(:alert, cmd: "echo failed")

    stage :test do
      step(:unit, cmd: "echo test")
    end
  end

  defmodule ModuleHookPipeline do
    use TinyCI.DSL

    on_success :hook, module: TinyCI.DSLTest.DummyHook do
      set(:channel, "#deploys")
      set(:env, "prod")
    end

    stage :test do
      step(:unit, cmd: "echo test")
    end
  end

  defmodule MultiHookPipeline do
    use TinyCI.DSL

    on_success(:first, cmd: "echo first")
    on_success(:second, cmd: "echo second")
    on_failure(:fail_notify, cmd: "echo failed")

    stage :test do
      step(:unit, cmd: "echo test")
    end
  end

  defmodule NoHookPipeline do
    use TinyCI.DSL

    stage :test do
      step(:unit, cmd: "echo test")
    end
  end

  describe "__pipeline__/0" do
    test "produces a list of stages" do
      stages = SimplePipeline.__pipeline__()
      assert is_list(stages)
      assert length(stages) == 1
    end

    test "stages are TinyCI.Stage structs" do
      [stage] = SimplePipeline.__pipeline__()
      assert %TinyCI.Stage{} = stage
    end

    test "preserves stage name" do
      [stage] = SimplePipeline.__pipeline__()
      assert stage.name == :build
    end

    test "preserves step order" do
      [stage] = SimplePipeline.__pipeline__()
      assert [%{name: :compile}, %{name: :check}] = stage.steps
    end

    test "steps are TinyCI.Step structs" do
      [stage] = SimplePipeline.__pipeline__()
      assert Enum.all?(stage.steps, &match?(%TinyCI.Step{}, &1))
    end

    test "preserves cmd option on steps" do
      [stage] = SimplePipeline.__pipeline__()
      assert [%{cmd: "echo compile"}, %{cmd: "echo check"}] = stage.steps
    end

    test "multiple stages are ordered correctly" do
      stages = MultiStagePipeline.__pipeline__()
      assert [%{name: :test}, %{name: :build}] = stages
    end
  end

  describe "stage modes" do
    test "defaults to :parallel" do
      [stage] = SimplePipeline.__pipeline__()
      assert stage.mode == :parallel
    end

    test "respects explicit :parallel mode" do
      [stage] = ParallelPipeline.__pipeline__()
      assert stage.mode == :parallel
    end

    test "respects :serial mode" do
      [stage] = SerialPipeline.__pipeline__()
      assert stage.mode == :serial
    end
  end

  describe "set/2 generic config macro" do
    test "collects key-value pairs into the step config_block" do
      [stage] = GenericConfigPipeline.__pipeline__()
      [step] = stage.steps
      assert is_function(step.config_block, 0)
      config = step.config_block.()
      assert config == [app: "my-app", strategy: :heroku]
    end

    test "works with a single set call" do
      [stage] = SingleSetPipeline.__pipeline__()
      [step] = stage.steps
      config = step.config_block.()
      assert config == [channel: "#deploys"]
    end

    test "preserves order of multiple set calls" do
      [stage] = ManySetPipeline.__pipeline__()
      [step] = stage.steps
      config = step.config_block.()
      assert config == [app: "my-app", region: "us-east-1", replicas: 3, verbose: true]
    end

    test "supports arbitrary value types" do
      [stage] = ManySetPipeline.__pipeline__()
      [step] = stage.steps
      config = step.config_block.()
      assert Keyword.get(config, :replicas) == 3
      assert Keyword.get(config, :verbose) == true
      assert Keyword.get(config, :region) == "us-east-1"
    end

    test "step with set has correct module assigned" do
      [stage] = GenericConfigPipeline.__pipeline__()
      [step] = stage.steps
      assert step.module == TinyCI.DSLTest.DummyStep
    end

    test "step with set has correct name" do
      [stage] = GenericConfigPipeline.__pipeline__()
      [step] = stage.steps
      assert step.name == :prod
    end
  end

  describe "timeout option" do
    test "preserves timeout on steps" do
      [stage] = TimeoutPipeline.__pipeline__()
      steps = Map.new(stage.steps, &{&1.name, &1})

      assert steps[:fast].timeout == 5_000
      assert steps[:slow].timeout == 60_000
    end

    test "defaults to nil when no timeout specified" do
      [stage] = TimeoutPipeline.__pipeline__()
      no_timeout_step = Enum.find(stage.steps, &(&1.name == :no_timeout))

      assert no_timeout_step.timeout == nil
    end
  end

  describe "compile-time validation" do
    test "warns on duplicate step names" do
      code = """
      defmodule TinyCI.DSLTest.DuplicateSteps do
        use TinyCI.DSL

        stage :test do
          step :unit, cmd: "mix test"
          step :unit, cmd: "mix test --cover"
        end
      end
      """

      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string(code)
        end)

      assert warnings =~ "duplicate step name :unit"
    after
      :code.purge(TinyCI.DSLTest.DuplicateSteps)
      :code.delete(TinyCI.DSLTest.DuplicateSteps)
    end

    test "warns on step missing cmd and module" do
      code = """
      defmodule TinyCI.DSLTest.MissingCmdModule do
        use TinyCI.DSL

        stage :test do
          step :empty, env: %{"FOO" => "bar"}
        end
      end
      """

      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string(code)
        end)

      assert warnings =~ ":empty"
      assert warnings =~ "cmd"
      assert warnings =~ "module"
    after
      :code.purge(TinyCI.DSLTest.MissingCmdModule)
      :code.delete(TinyCI.DSLTest.MissingCmdModule)
    end

    test "warns on step with both cmd and module" do
      code = """
      defmodule TinyCI.DSLTest.BothCmdModule do
        use TinyCI.DSL

        stage :test do
          step :ambiguous, cmd: "echo hi", module: SomeModule
        end
      end
      """

      warnings =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Code.compile_string(code)
        end)

      assert warnings =~ ":ambiguous"
      assert warnings =~ "both"
    after
      :code.purge(TinyCI.DSLTest.BothCmdModule)
      :code.delete(TinyCI.DSLTest.BothCmdModule)
    end

    test "no warnings for valid pipeline" do
      code = """
      defmodule TinyCI.DSLTest.ValidPipeline do
        use TinyCI.DSL

        stage :test do
          step :unit, cmd: "mix test"
        end
      end
      """

      {_result, diagnostics} =
        Code.with_diagnostics(fn ->
          Code.compile_string(code)
        end)

      warnings = Enum.filter(diagnostics, &(&1.severity == :warning))
      assert warnings == []
    after
      :code.purge(TinyCI.DSLTest.ValidPipeline)
      :code.delete(TinyCI.DSLTest.ValidPipeline)
    end
  end

  describe "when_branch/1 condition macro" do
    test "attaches a when_condition function to the stage" do
      [stage] = ConditionalPipeline.__pipeline__()
      assert is_function(stage.when_condition, 1)
    end

    test "condition returns true when branch matches" do
      [stage] = ConditionalPipeline.__pipeline__()
      assert stage.when_condition.(%{branch: "main"})
    end

    test "condition returns false when branch does not match" do
      [stage] = ConditionalPipeline.__pipeline__()
      refute stage.when_condition.(%{branch: "develop"})
    end

    test "unconditional stages have nil when_condition" do
      [test_stage, _deploy_stage] = MultiConditionalPipeline.__pipeline__()
      assert test_stage.when_condition == nil
    end

    test "conditional and unconditional stages coexist correctly" do
      [test_stage, deploy_stage] = MultiConditionalPipeline.__pipeline__()
      assert test_stage.name == :test
      assert test_stage.when_condition == nil
      assert deploy_stage.name == :deploy
      assert is_function(deploy_stage.when_condition, 1)
    end
  end

  describe "when_env/1 condition macro" do
    test "attaches a when_condition that checks for an environment variable" do
      System.put_env("TINY_CI_TEST_WHEN_ENV", "1")

      code = """
      defmodule TinyCI.DSLTest.WhenEnvPipeline do
        use TinyCI.DSL

        stage :deploy, when: when_env("TINY_CI_TEST_WHEN_ENV") do
          step :release, cmd: "echo deploy"
        end
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)

      [stage] = apply(TinyCI.DSLTest.WhenEnvPipeline, :__pipeline__, [])
      assert is_function(stage.when_condition, 1)
      assert stage.when_condition.(%{})
    after
      System.delete_env("TINY_CI_TEST_WHEN_ENV")
      :code.purge(TinyCI.DSLTest.WhenEnvPipeline)
      :code.delete(TinyCI.DSLTest.WhenEnvPipeline)
    end

    test "condition returns false when env var is not set" do
      System.delete_env("TINY_CI_TEST_MISSING_VAR")

      code = """
      defmodule TinyCI.DSLTest.WhenEnvMissing do
        use TinyCI.DSL

        stage :deploy, when: when_env("TINY_CI_TEST_MISSING_VAR") do
          step :release, cmd: "echo deploy"
        end
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)

      [stage] = apply(TinyCI.DSLTest.WhenEnvMissing, :__pipeline__, [])
      refute stage.when_condition.(%{})
    after
      :code.purge(TinyCI.DSLTest.WhenEnvMissing)
      :code.delete(TinyCI.DSLTest.WhenEnvMissing)
    end
  end

  describe "when_file_changed/1 condition macro" do
    test "condition returns true when changed files match the glob" do
      code = """
      defmodule TinyCI.DSLTest.WhenFileChanged do
        use TinyCI.DSL

        stage :test, when: when_file_changed("lib/**/*.ex") do
          step :unit, cmd: "mix test"
        end
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)

      [stage] = apply(TinyCI.DSLTest.WhenFileChanged, :__pipeline__, [])
      assert is_function(stage.when_condition, 1)

      ctx = %{changed_files: ["lib/tiny_ci/executor.ex", "README.md"]}
      assert stage.when_condition.(ctx)
    after
      :code.purge(TinyCI.DSLTest.WhenFileChanged)
      :code.delete(TinyCI.DSLTest.WhenFileChanged)
    end

    test "condition returns false when no changed files match" do
      code = """
      defmodule TinyCI.DSLTest.WhenFileChangedNoMatch do
        use TinyCI.DSL

        stage :test, when: when_file_changed("lib/**/*.ex") do
          step :unit, cmd: "mix test"
        end
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)

      [stage] = apply(TinyCI.DSLTest.WhenFileChangedNoMatch, :__pipeline__, [])

      ctx = %{changed_files: ["README.md", "mix.exs"]}
      refute stage.when_condition.(ctx)
    after
      :code.purge(TinyCI.DSLTest.WhenFileChangedNoMatch)
      :code.delete(TinyCI.DSLTest.WhenFileChangedNoMatch)
    end

    test "condition returns false when changed_files is empty" do
      code = """
      defmodule TinyCI.DSLTest.WhenFileChangedEmpty do
        use TinyCI.DSL

        stage :test, when: when_file_changed("**/*.ex") do
          step :unit, cmd: "mix test"
        end
      end
      """

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string(code)
      end)

      [stage] = apply(TinyCI.DSLTest.WhenFileChangedEmpty, :__pipeline__, [])

      ctx = %{changed_files: []}
      refute stage.when_condition.(ctx)
    after
      :code.purge(TinyCI.DSLTest.WhenFileChangedEmpty)
      :code.delete(TinyCI.DSLTest.WhenFileChangedEmpty)
    end
  end

  describe "env option on steps" do
    test "preserves env map on step" do
      [stage] = EnvPipeline.__pipeline__()
      check_step = Enum.find(stage.steps, &(&1.name == :check))
      assert check_step.env == %{"TINY_CI_FOO" => "bar", "TINY_CI_BAZ" => "qux"}
    end

    test "defaults env to empty map when not specified" do
      [stage] = EnvPipeline.__pipeline__()
      no_env_step = Enum.find(stage.steps, &(&1.name == :no_env))
      assert no_env_step.env == %{}
    end
  end

  describe "module step without do block" do
    test "assigns module to the step" do
      [stage] = ModuleOnlyPipeline.__pipeline__()
      [step] = stage.steps
      assert step.module == TinyCI.DSLTest.DummyStep
    end

    test "has nil config_block" do
      [stage] = ModuleOnlyPipeline.__pipeline__()
      [step] = stage.steps
      assert step.config_block == nil
    end

    test "has nil cmd" do
      [stage] = ModuleOnlyPipeline.__pipeline__()
      [step] = stage.steps
      assert step.cmd == nil
    end
  end

  describe "allow_failure option" do
    test "preserves allow_failure: true on step" do
      [stage] = AllowFailurePipeline.__pipeline__()
      flaky = Enum.find(stage.steps, &(&1.name == :flaky))
      assert flaky.allow_failure == true
    end

    test "defaults allow_failure to false" do
      [stage] = AllowFailurePipeline.__pipeline__()
      critical = Enum.find(stage.steps, &(&1.name == :critical))
      assert critical.allow_failure == false
    end
  end

  describe "mixed mode stages" do
    test "each stage retains its own mode" do
      [test_stage, deploy_stage] = MixedModePipeline.__pipeline__()
      assert test_stage.mode == :parallel
      assert deploy_stage.mode == :serial
    end

    test "steps belong to the correct stages" do
      [test_stage, deploy_stage] = MixedModePipeline.__pipeline__()
      assert Enum.map(test_stage.steps, & &1.name) == [:unit, :lint]
      assert Enum.map(deploy_stage.steps, & &1.name) == [:release]
    end
  end

  describe "__hooks__/0" do
    test "returns a map with on_success and on_failure keys" do
      hooks = SuccessHookPipeline.__hooks__()
      assert %{on_success: _, on_failure: _} = hooks
    end

    test "on_success list contains Hook structs" do
      %{on_success: hooks} = SuccessHookPipeline.__hooks__()
      assert Enum.all?(hooks, &match?(%TinyCI.Hook{}, &1))
    end

    test "on_failure list contains Hook structs" do
      %{on_failure: hooks} = SuccessHookPipeline.__hooks__()
      assert Enum.all?(hooks, &match?(%TinyCI.Hook{}, &1))
    end

    test "cmd hook has correct name and cmd" do
      %{on_success: [hook]} = SuccessHookPipeline.__hooks__()
      assert hook.name == :notify
      assert hook.cmd == "echo passed"
    end

    test "on_failure hook has correct name and cmd" do
      %{on_failure: [hook]} = SuccessHookPipeline.__hooks__()
      assert hook.name == :alert
      assert hook.cmd == "echo failed"
    end

    test "module hook has correct module and config_block" do
      %{on_success: [hook]} = ModuleHookPipeline.__hooks__()
      assert hook.module == TinyCI.DSLTest.DummyHook
      assert is_function(hook.config_block, 0)
      config = hook.config_block.()
      assert config == [channel: "#deploys", env: "prod"]
    end

    test "preserves declaration order for multiple hooks" do
      %{on_success: hooks} = MultiHookPipeline.__hooks__()
      assert [%{name: :first}, %{name: :second}] = hooks
    end

    test "hooks are empty lists when no hooks are defined" do
      hooks = NoHookPipeline.__hooks__()
      assert hooks.on_success == []
      assert hooks.on_failure == []
    end

    test "stages are unaffected by hook declarations" do
      stages = SuccessHookPipeline.__pipeline__()
      assert [%TinyCI.Stage{name: :test}] = stages
    end
  end
end
