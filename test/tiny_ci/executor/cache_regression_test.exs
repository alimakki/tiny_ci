defmodule TinyCI.Executor.CacheRegressionTest do
  # The cache location is configured through global application environment.
  use ExUnit.Case, async: false

  alias TinyCI.{Executor, RegressionActions, Stage, Step}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.fetch_env(:tiny_ci, :cache_base_dir)
    Application.put_env(:tiny_ci, :cache_base_dir, Path.join(root, "cache"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "mix.lock"), "locked")
    File.write!(Path.join(root, "deps/item"), "cached")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tiny_ci, :cache_base_dir, value)
        :error -> Application.delete_env(:tiny_ci, :cache_base_dir)
      end
    end)
  end

  defp run(root, attrs) do
    step = struct!(Step, [name: :cached, cache: %{paths: ["deps"], key: "mix.lock"}] ++ attrs)

    Executor.execute(
      %Stage{name: :cached, steps: [step]},
      %{root: root},
      :buffered,
      console: false
    )
  end

  # An imaged run: the fake backend is the test seam, the injected digest keeps
  # Docker out of the test. Cache identity is computed by the executor from the
  # resolved environment, exactly as it would be for a real container backend.
  defp run_imaged(root, attrs, opts) do
    step = struct!(Step, [name: :cached, cache: %{paths: ["deps"], key: "mix.lock"}] ++ attrs)
    stage = %Stage{name: :cached, steps: [step], image: Keyword.fetch!(opts, :image)}

    Executor.execute(
      stage,
      %{root: root},
      :buffered,
      console: false,
      backend: TinyCI.ExecutionFixtures.RecordingBackend,
      digest: Keyword.get(opts, :digest, :ref),
      available?: fn -> true end,
      extra_sinks: [{TinyCI.TestSink, pid: self()}]
    )
  end

  defp cache_result do
    assert_receive {:event, %TinyCI.Events.CacheLookup{result: result}}
    result
  end

  defp cache_key do
    assert_receive {:event, %TinyCI.Events.CacheLookup{key: key}}
    key
  end

  test "a changed command cannot reuse a passing result", %{tmp_dir: root} do
    assert run(root, cmd: "true").status == :passed
    assert run(root, cmd: "false").status == :failed
  end

  test "a changed effective environment invalidates the cache", %{tmp_dir: root} do
    cmd = "test \"$VALUE\" = good"
    assert run(root, cmd: cmd, env: %{"VALUE" => "good"}).status == :passed
    assert run(root, cmd: cmd, env: %{"VALUE" => "bad"}).status == :failed
  end

  test "a changed working directory invalidates the cache", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "other"))
    assert run(root, cmd: "test -d deps").status == :passed
    assert run(root, cmd: "test -d deps", working_dir: "other").status == :failed
  end

  test "module caches never discard action store writes", %{tmp_dir: root} do
    for _ <- 1..2 do
      assert %{status: :passed, store: %{tag: "new"}} = run(root, module: RegressionActions)
    end
  end

  describe "image identity" do
    test "a different image cannot reuse a key", %{tmp_dir: root} do
      run_imaged(root, [cmd: "true"], image: "alpine:3.22", digest: "sha256:a")
      assert cache_result() == :miss

      run_imaged(root, [cmd: "true"], image: "alpine:3.21", digest: "sha256:b")
      assert cache_result() == :miss
    end

    test "the same digest reuses a key", %{tmp_dir: root} do
      run_imaged(root, [cmd: "true"], image: "alpine:3.22", digest: "sha256:a")
      assert cache_result() == :miss

      run_imaged(root, [cmd: "true"], image: "alpine:3.22", digest: "sha256:a")
      assert cache_result() == :hit
    end

    test "a digest change under the same tag is a miss", %{tmp_dir: root} do
      run_imaged(root, [cmd: "true"], image: "alpine:latest", digest: "sha256:old")
      assert cache_result() == :miss

      run_imaged(root, [cmd: "true"], image: "alpine:latest", digest: "sha256:new")
      assert cache_result() == :miss
    end

    test "a container step key ignores the host environment", %{tmp_dir: root} do
      on_exit(fn -> System.delete_env("TINY_CI_CACHE_HOST_ONLY") end)

      System.put_env("TINY_CI_CACHE_HOST_ONLY", "before")
      run_imaged(root, [cmd: "true"], image: "alpine:3.22", digest: "sha256:a")
      assert cache_result() == :miss

      System.put_env("TINY_CI_CACHE_HOST_ONLY", "after")
      run_imaged(root, [cmd: "true"], image: "alpine:3.22", digest: "sha256:a")
      assert cache_result() == :hit
    end

    test "a module step key does not inherit the image identity", %{tmp_dir: root} do
      run_imaged(root, [module: RegressionActions], image: "alpine:3.22", digest: "sha256:a")
      first = cache_key()

      run_imaged(root, [module: RegressionActions], image: "elixir:1.18", digest: "sha256:b")
      second = cache_key()

      assert first == second
    end

    test "a plain host pipeline still hits exactly as before", %{tmp_dir: root} do
      assert %{step_results: [%{cache_status: :miss}]} = run(root, cmd: "true")
      assert %{step_results: [%{cache_status: :hit}]} = run(root, cmd: "true")
    end
  end

  describe "toolchain identity" do
    test "a changed toolchain fingerprint is a miss", %{tmp_dir: root} do
      step = %Step{name: :cached, cmd: "true", cache: %{paths: ["deps"], key: "mix.lock"}}

      toolchain = fn fingerprint ->
        [
          console: false,
          backend: TinyCI.ExecutionFixtures.RecordingBackend,
          toolchain: fn _name ->
            {:ok, %{env: %{}, tools: [], fingerprint: fingerprint}}
          end,
          extra_sinks: [{TinyCI.TestSink, pid: self()}]
        ]
      end

      stage = %Stage{name: :cached, environment: "ci", steps: [step]}

      Executor.execute(stage, %{root: root}, :buffered, toolchain.("fp-a"))
      assert cache_result() == :miss

      Executor.execute(stage, %{root: root}, :buffered, toolchain.("fp-a"))
      assert cache_result() == :hit

      Executor.execute(stage, %{root: root}, :buffered, toolchain.("fp-b"))
      assert cache_result() == :miss
    end

    test "a changed toolchain env value is a miss", %{tmp_dir: root} do
      step = %Step{name: :cached, cmd: "true", cache: %{paths: ["deps"], key: "mix.lock"}}
      stage = %Stage{name: :cached, environment: "ci", steps: [step]}

      toolchain = fn env ->
        [
          console: false,
          backend: TinyCI.ExecutionFixtures.RecordingBackend,
          toolchain: fn _name ->
            {:ok, %{env: env, tools: [{"elixir", "1.20.3"}], fingerprint: "fp"}}
          end,
          extra_sinks: [{TinyCI.TestSink, pid: self()}]
        ]
      end

      Executor.execute(stage, %{root: root}, :buffered, toolchain.(%{"MIX_ENV" => "dev"}))
      assert cache_result() == :miss

      Executor.execute(stage, %{root: root}, :buffered, toolchain.(%{"MIX_ENV" => "prod"}))
      assert cache_result() == :miss

      Executor.execute(stage, %{root: root}, :buffered, toolchain.(%{"MIX_ENV" => "prod"}))
      assert cache_result() == :hit
    end
  end
end
