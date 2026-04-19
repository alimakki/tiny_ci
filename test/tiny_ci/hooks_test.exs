defmodule TinyCI.HooksTest do
  use ExUnit.Case, async: true

  alias TinyCI.{Hook, Hooks}

  @base_context %{branch: "main", commit: "abc123", store: %{}}

  defmodule OkHook do
    @moduledoc false
    def run(_config, _ctx), do: :ok
  end

  defmodule FailHook do
    @moduledoc false
    def run(_config, _ctx), do: {:error, :boom}
  end

  defmodule ConfigCapture do
    @moduledoc false
    def run(config, _ctx) do
      send(self(), {:config_received, config})
      :ok
    end
  end

  defmodule ContextCapture do
    @moduledoc false
    def run(_config, ctx) do
      send(self(), {:context_received, ctx})
      :ok
    end
  end

  describe "run_hooks/3 with empty hooks" do
    test "returns :ok for empty on_success list" do
      hooks = %{on_success: [], on_failure: []}
      assert :ok = Hooks.run_hooks(hooks, :on_success, @base_context)
    end

    test "returns :ok for empty on_failure list" do
      hooks = %{on_success: [], on_failure: []}
      assert :ok = Hooks.run_hooks(hooks, :on_failure, @base_context)
    end

    test "handles missing event key gracefully" do
      assert :ok = Hooks.run_hooks(%{}, :on_success, @base_context)
    end
  end

  describe "run_hooks/3 with shell command hooks" do
    test "runs a passing shell command hook" do
      hooks = %{on_success: [%Hook{name: :pass, cmd: "true"}]}
      assert :ok = Hooks.run_hooks(hooks, :on_success, @base_context)
    end

    test "logs failure but continues when shell hook fails" do
      hooks = %{on_failure: [%Hook{name: :fail, cmd: "false"}]}

      # Should not raise even though hook fails
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert :ok = Hooks.run_hooks(hooks, :on_failure, @base_context)
      end)
    end

    test "runs multiple shell command hooks in order" do
      tmp = System.tmp_dir!()
      path_a = Path.join(tmp, "tiny_ci_hook_test_a_#{:os.getpid()}.txt")
      path_b = Path.join(tmp, "tiny_ci_hook_test_b_#{:os.getpid()}.txt")

      hooks = %{
        on_success: [
          %Hook{name: :write_a, cmd: "echo a > #{path_a}"},
          %Hook{name: :write_b, cmd: "echo b > #{path_b}"}
        ]
      }

      Hooks.run_hooks(hooks, :on_success, @base_context)

      assert File.exists?(path_a)
      assert File.exists?(path_b)
    after
      tmp = System.tmp_dir!()
      File.rm(Path.join(tmp, "tiny_ci_hook_test_a_#{:os.getpid()}.txt"))
      File.rm(Path.join(tmp, "tiny_ci_hook_test_b_#{:os.getpid()}.txt"))
    end

    test "passes TINY_CI_RESULT env var to shell hooks" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_result_#{:os.getpid()}.txt")

      hooks = %{on_success: [%Hook{name: :capture, cmd: ~s(echo "$TINY_CI_RESULT" > #{path})}]}
      Hooks.run_hooks(hooks, :on_success, @base_context)

      content = File.read!(path)
      assert content =~ "on_success"
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_result_#{:os.getpid()}.txt"))
    end

    test "passes TINY_CI_BRANCH env var to shell hooks" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_branch_#{:os.getpid()}.txt")
      context = Map.put(@base_context, :branch, "feature/test")

      hooks = %{on_success: [%Hook{name: :capture, cmd: ~s(echo "$TINY_CI_BRANCH" > #{path})}]}
      Hooks.run_hooks(hooks, :on_success, context)

      content = File.read!(path)
      assert content =~ "feature/test"
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_branch_#{:os.getpid()}.txt"))
    end

    test "passes TINY_CI_COMMIT env var to shell hooks" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_commit_#{:os.getpid()}.txt")
      context = Map.put(@base_context, :commit, "deadbeef")

      hooks = %{on_success: [%Hook{name: :capture, cmd: ~s(echo "$TINY_CI_COMMIT" > #{path})}]}
      Hooks.run_hooks(hooks, :on_success, context)

      content = File.read!(path)
      assert content =~ "deadbeef"
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_commit_#{:os.getpid()}.txt"))
    end

    test "store(:key) in hook env resolves to store value" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_store_#{:os.getpid()}.txt")
      context = Map.put(@base_context, :store, %{image_tag: "v1.2.3"})

      hooks = %{
        on_success: [
          %Hook{
            name: :capture,
            cmd: ~s(echo "$TAG" > #{path}),
            env: %{"TAG" => {:store, :image_tag}}
          }
        ]
      }

      Hooks.run_hooks(hooks, :on_success, context)

      content = File.read!(path)
      assert content =~ "v1.2.3"
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_store_#{:os.getpid()}.txt"))
    end

    test "store is not automatically injected into hook env" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_no_store_#{:os.getpid()}.txt")
      context = Map.put(@base_context, :store, %{secret: "s3cr3t"})

      hooks = %{
        on_success: [
          %Hook{name: :check, cmd: ~s(env > #{path})}
        ]
      }

      Hooks.run_hooks(hooks, :on_success, context)

      content = File.read!(path)
      refute content =~ "TINY_CI_STORE"
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_no_store_#{:os.getpid()}.txt"))
    end

    test "merges explicit env map with auto env vars" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_env_#{:os.getpid()}.txt")

      hooks = %{
        on_success: [
          %Hook{
            name: :capture,
            cmd: ~s(echo "$TINY_CI_RESULT-$MY_CUSTOM_VAR" > #{path}),
            env: %{"MY_CUSTOM_VAR" => "hello"}
          }
        ]
      }

      Hooks.run_hooks(hooks, :on_success, @base_context)

      content = File.read!(path)
      assert content =~ "on_success-hello"
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_env_#{:os.getpid()}.txt"))
    end

    test "hook with timeout passes when command completes in time" do
      hooks = %{on_success: [%Hook{name: :fast, cmd: "echo fast", timeout: 5_000}]}
      assert :ok = Hooks.run_hooks(hooks, :on_success, @base_context)
    end

    test "hook with timeout logs error when command exceeds timeout" do
      hooks = %{on_failure: [%Hook{name: :slow, cmd: "sleep 10", timeout: 100}]}

      stderr =
        ExUnit.CaptureIO.capture_io(:stderr, fn ->
          Hooks.run_hooks(hooks, :on_failure, @base_context)
        end)

      assert stderr =~ "timed out"
    end

    test "failure of one hook does not prevent subsequent hooks from running" do
      tmp = System.tmp_dir!()
      path = Path.join(tmp, "tiny_ci_hook_subsequent_#{:os.getpid()}.txt")

      hooks = %{
        on_failure: [
          %Hook{name: :fail_first, cmd: "false"},
          %Hook{name: :write_second, cmd: "echo ok > #{path}"}
        ]
      }

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Hooks.run_hooks(hooks, :on_failure, @base_context)
      end)

      assert File.exists?(path)
    after
      File.rm(Path.join(System.tmp_dir!(), "tiny_ci_hook_subsequent_#{:os.getpid()}.txt"))
    end
  end

  describe "run_hooks/3 with module hooks" do
    test "runs a passing module hook" do
      hooks = %{on_success: [%Hook{name: :ok_hook, module: OkHook}]}
      assert :ok = Hooks.run_hooks(hooks, :on_success, @base_context)
    end

    test "logs failure but continues when module hook returns error" do
      hooks = %{on_failure: [%Hook{name: :fail_hook, module: FailHook}]}

      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        assert :ok = Hooks.run_hooks(hooks, :on_failure, @base_context)
      end)
    end

    test "passes config from config_block to module hook" do
      hooks = %{
        on_success: [
          %Hook{
            name: :capture,
            module: ConfigCapture,
            config_block: fn -> [channel: "#deploys", env: "prod"] end
          }
        ]
      }

      Hooks.run_hooks(hooks, :on_success, @base_context)

      assert_received {:config_received, [channel: "#deploys", env: "prod"]}
    end

    test "passes empty config when no config_block" do
      hooks = %{on_success: [%Hook{name: :capture, module: ConfigCapture}]}
      Hooks.run_hooks(hooks, :on_success, @base_context)
      assert_received {:config_received, []}
    end

    test "enriches context with pipeline_result key" do
      hooks = %{on_success: [%Hook{name: :capture, module: ContextCapture}]}
      Hooks.run_hooks(hooks, :on_success, @base_context)

      assert_received {:context_received, ctx}
      assert ctx.pipeline_result == :on_success
    end

    test "pipeline_result is :on_failure when running failure hooks" do
      hooks = %{on_failure: [%Hook{name: :capture, module: ContextCapture}]}
      Hooks.run_hooks(hooks, :on_failure, @base_context)

      assert_received {:context_received, ctx}
      assert ctx.pipeline_result == :on_failure
    end

    test "context includes branch and commit from pipeline context" do
      context = %{branch: "feature/hooks", commit: "abc999", store: %{}}
      hooks = %{on_success: [%Hook{name: :capture, module: ContextCapture}]}
      Hooks.run_hooks(hooks, :on_success, context)

      assert_received {:context_received, ctx}
      assert ctx.branch == "feature/hooks"
      assert ctx.commit == "abc999"
    end

    test "only runs hooks for the specified event" do
      hooks = %{
        on_success: [%Hook{name: :success_hook, module: ContextCapture}],
        on_failure: [%Hook{name: :failure_hook, module: ContextCapture}]
      }

      Hooks.run_hooks(hooks, :on_success, @base_context)

      assert_received {:context_received, ctx}
      assert ctx.pipeline_result == :on_success

      # No second message (the on_failure hook did not run)
      refute_received {:context_received, _}
    end
  end
end
