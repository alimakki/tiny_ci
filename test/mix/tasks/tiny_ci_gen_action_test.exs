defmodule Mix.Tasks.TinyCi.Gen.ActionTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.TinyCi.Gen.Action

  doctest Mix.Tasks.TinyCi.Gen.Action

  @tmp_dir "test/tmp/gen_action"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  describe "path helpers" do
    test "module_path/1 derives the lib path from the module name" do
      assert Action.module_path("MyApp.Deploy") == "lib/my_app/deploy.ex"
    end

    test "test_path/1 derives the test path from the module name" do
      assert Action.test_path("MyApp.Deploy") == "test/my_app/deploy_test.exs"
    end

    test "paths handle deeply nested module names" do
      assert Action.module_path("MyApp.Steps.DeployToProd") ==
               "lib/my_app/steps/deploy_to_prod.ex"
    end
  end

  describe "run/1" do
    test "generates a compiling action module and a passing test stub" do
      File.cd!(@tmp_dir, fn ->
        capture_io(fn -> Action.run(["MyApp.Deploy"]) end)

        module_file = "lib/my_app/deploy.ex"
        test_file = "test/my_app/deploy_test.exs"

        assert File.exists?(module_file)
        assert File.exists?(test_file)

        # The generated module compiles and implements the contract.
        [{mod, _bin}] = Code.compile_file(module_file)

        assert mod == MyApp.Deploy
        assert TinyCI.Action.implements?(mod)
        assert TinyCI.Action.behaviour_adopted?(mod)
        assert mod.execute([], %TinyCI.Context{}) == :ok
        assert %TinyCI.Action.Metadata{} = mod.metadata()

        # The generated test stub compiles too.
        test_src = File.read!(test_file)
        assert test_src =~ "defmodule MyApp.DeployTest"
        assert test_src =~ "use ExUnit.Case"
      end)
    after
      :code.purge(MyApp.Deploy)
      :code.delete(MyApp.Deploy)
    end

    test "raises when no module name is given" do
      assert_raise Mix.Error, fn ->
        capture_io(fn -> Action.run([]) end)
      end
    end
  end
end
