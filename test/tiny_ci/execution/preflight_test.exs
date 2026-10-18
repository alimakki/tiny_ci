defmodule TinyCI.Execution.PreflightTest do
  # async: false because one test clears a fixture module from the code server and
  # sets an environment variable that its @on_load hook observes.
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias TinyCI.{Hook, Stage, Step}
  alias TinyCI.Execution.Preflight

  defp stage_with_module(module) do
    %Stage{
      name: :build,
      steps: [%Step{name: :deploy, module: module}]
    }
  end

  describe "check/4" do
    test "a trusted run is not restricted" do
      assert :ok =
               Preflight.check(%{trust: :trusted}, [stage_with_module(MyApp.Deploy)], %{
                 on_success: [%Hook{name: :notify, module: MyApp.Notify}]
               })
    end

    test "an untrusted run with only shell steps is allowed" do
      stage = %Stage{name: :build, steps: [%Step{name: :test, cmd: "true"}]}
      assert :ok = Preflight.check(%{trust: :untrusted}, [stage], %{})
    end

    test "an untrusted run names a non-builtin module step and its stage" do
      assert {:error, {:untrusted_actions, [detail]}} =
               Preflight.check(%{trust: :untrusted}, [stage_with_module(MyApp.Deploy)], %{},
                 classify: fn _ -> :first_party end
               )

      assert %{kind: :step, stage: :build, name: :deploy, module: MyApp.Deploy} = detail
    end

    test "an untrusted run names module hooks" do
      hooks = %{on_failure: [%Hook{name: :alert, module: MyApp.Alert}]}

      assert {:error, {:untrusted_actions, [detail]}} =
               Preflight.check(%{trust: :untrusted}, [], hooks,
                 classify: fn _ -> :third_party end
               )

      assert %{kind: :hook, name: :alert, module: MyApp.Alert} = detail
    end

    test "an untrusted run rejects a working directory outside the workspace",
         %{tmp_dir: tmp_dir} do
      outside = Path.dirname(tmp_dir)
      stage = %Stage{name: :build, steps: [%Step{name: :one, cmd: "true", working_dir: outside}]}

      assert {:error, {:unsafe_pipeline_paths, [detail]}} =
               Preflight.check(%{trust: :untrusted, root: tmp_dir}, [stage], %{})

      assert %{kind: :step, stage: :build, name: :one} = detail
    end

    test "an untrusted run rejects a relative working directory that escapes" do
      stage = %Stage{
        name: :build,
        steps: [%Step{name: :one, cmd: "true", working_dir: "../outside"}]
      }

      assert {:error, {:unsafe_pipeline_paths, [detail]}} =
               Preflight.check(%{trust: :untrusted, root: "/tmp/project"}, [stage], %{})

      assert detail.path == "../outside"
    end

    test "an untrusted run accepts a working directory under the workspace",
         %{tmp_dir: tmp_dir} do
      stage = %Stage{
        name: :build,
        steps: [%Step{name: :one, cmd: "true", working_dir: Path.join(tmp_dir, "app")}]
      }

      assert :ok = Preflight.check(%{trust: :untrusted, root: tmp_dir}, [stage], %{})
    end

    test "an untrusted run rejects a working directory that is a symlink outside",
         %{tmp_dir: tmp_dir} do
      outside = Path.join(Path.dirname(tmp_dir), "outside_#{System.unique_integer([:positive])}")
      File.mkdir_p!(outside)
      File.ln_s!(outside, Path.join(tmp_dir, "link"))
      on_exit(fn -> File.rm_rf(outside) end)

      stage = %Stage{name: :build, steps: [%Step{name: :one, cmd: "true", working_dir: "link"}]}

      assert {:error, {:unsafe_pipeline_paths, [detail]}} =
               Preflight.check(%{trust: :untrusted, root: tmp_dir}, [stage], %{})

      assert detail.path == "link"
    end

    test "builtin actions are allowed in an untrusted run" do
      assert :ok =
               Preflight.check(%{trust: :untrusted}, [stage_with_module(MyApp.Deploy)], %{},
                 classify: fn _ -> :builtin end
               )
    end

    test "every refusal is listed, not just the first" do
      stages = [
        stage_with_module(MyApp.One),
        %Stage{name: :test, steps: [%Step{name: :two, module: MyApp.Two}]}
      ]

      hooks = %{on_success: [%Hook{name: :three, module: MyApp.Three}]}

      assert {:error, {:untrusted_actions, details}} =
               Preflight.check(%{trust: :untrusted}, stages, hooks,
                 classify: fn _ -> :third_party end
               )

      assert length(details) == 3
    end

    test "classification defaults to no-load and refuses an unloaded module" do
      path = Path.join(System.tmp_dir!(), "tiny_ci_on_load_#{System.unique_integer([:positive])}")
      previous = System.get_env("TINY_CI_ON_LOAD_MARKER")
      System.put_env("TINY_CI_ON_LOAD_MARKER", path)
      on_exit(fn -> restore_env("TINY_CI_ON_LOAD_MARKER", previous) end)

      :code.purge(TinyCI.UnloadedActionFixture)
      :code.delete(TinyCI.UnloadedActionFixture)

      refute :code.is_loaded(TinyCI.UnloadedActionFixture)
      refute File.exists?(path)

      assert {:error, {:untrusted_actions, [detail]}} =
               Preflight.check(
                 %{trust: :untrusted},
                 [stage_with_module(TinyCI.UnloadedActionFixture)],
                 %{}
               )

      assert detail.class == :unknown
      refute :code.is_loaded(TinyCI.UnloadedActionFixture)
      refute File.exists?(path)
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
