defmodule TinyCI.ExecutorContainerTest do
  @moduledoc """
  End-to-end untrusted runs through `TinyCI.Executor` and the container backend.
  """

  use ExUnit.Case, async: true

  alias TinyCI.{Executor, Stage, Step}
  alias TinyCI.Execution.Backend.Container
  alias TinyCI.Events.PipelineStarted

  @moduletag :container
  @moduletag :tmp_dir

  defp image, do: "alpine:3.22"

  setup_all do
    {:ok, runtime} = Container.runtime()
    ensure_image(runtime, image())
    :ok
  end

  defp opts do
    [
      console: false,
      output: :buffered,
      record: false,
      image: image(),
      pipeline_name: :isolated
    ]
  end

  defp run_with_run_id(stages, context, extra_opts \\ []) do
    opts = opts() ++ extra_opts ++ [extra_sinks: [{TinyCI.TestSink, pid: self()}]]
    result = Executor.run_pipeline(stages, context, opts)
    assert_receive {:event, %PipelineStarted{run_id: run_id}}
    {result, run_id}
  end

  test "an untrusted shell pipeline runs inside the container", %{tmp_dir: tmp_dir} do
    stage = %Stage{
      name: :build,
      mode: :serial,
      steps: [
        %Step{name: :inside, cmd: "cat /etc/alpine-release; pwd"},
        %Step{name: :workspace, cmd: "echo made > /workspace/from_run"}
      ]
    }

    context = %{
      root: tmp_dir,
      run_id: "run_untrusted_#{System.unique_integer([:positive])}",
      trust: :untrusted
    }

    {result, run_id} = run_with_run_id([stage], context)
    assert {:ok, [%{status: :passed, step_results: [inside, workspace]}]} = result
    assert containers_for(run_id) == []

    assert inside.output =~ ~r/^\d+\.\d+/
    assert inside.output =~ "/workspace"
    assert workspace.status == :passed
    assert File.read!(Path.join(tmp_dir, "from_run")) == "made\n"
    refute File.exists?("/workspace/from_run")
  end

  test "a trusted run with an image uses the container backend", %{tmp_dir: tmp_dir} do
    stage = %Stage{
      name: :build,
      mode: :serial,
      steps: [%Step{name: :inside, cmd: "cat /etc/alpine-release"}]
    }

    context = %{root: tmp_dir, run_id: "run_trusted_image", trust: :trusted}

    assert {:ok, [%{status: :passed, step_results: [result]}]} =
             Executor.run_pipeline([stage], context, opts())

    assert result.output =~ ~r/^\d+\.\d+/
  end

  test "the host environment is not passed into an untrusted run", %{tmp_dir: tmp_dir} do
    name = "TINY_CI_HOST_ONLY_#{System.unique_integer([:positive])}"
    System.put_env(name, "leaked")
    on_exit(fn -> System.delete_env(name) end)

    stage = %Stage{
      name: :build,
      mode: :serial,
      steps: [%Step{name: :env, cmd: "printenv #{name} || echo absent"}]
    }

    context = %{
      root: tmp_dir,
      run_id: "run_env_#{System.unique_integer([:positive])}",
      trust: :untrusted
    }

    assert {:ok, [%{status: :passed, step_results: [result]}]} =
             Executor.run_pipeline([stage], context, opts())

    assert result.output == "absent\n"
  end

  test "a failed run leaves no container", %{tmp_dir: tmp_dir} do
    stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :boom, cmd: "exit 7"}]}

    context = %{
      root: tmp_dir,
      run_id: "run_fail_#{System.unique_integer([:positive])}",
      trust: :untrusted
    }

    {{:error, _, _}, run_id} = run_with_run_id([stage], context)
    assert containers_for(run_id) == []
  end

  test "a timed-out run leaves no container", %{tmp_dir: tmp_dir} do
    stage = %Stage{
      name: :build,
      mode: :serial,
      steps: [%Step{name: :slow, cmd: "sleep 30", timeout: 200}]
    }

    context = %{
      root: tmp_dir,
      run_id: "run_timeout_#{System.unique_integer([:positive])}",
      trust: :untrusted
    }

    {{:error, _, _}, run_id} = run_with_run_id([stage], context)
    assert containers_for(run_id) == []
  end

  test "a shell hook runs in a container in an untrusted run", %{tmp_dir: tmp_dir} do
    stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :ok, cmd: "true"}]}
    hooks = %{on_success: [%TinyCI.Hook{name: :notify, cmd: "echo hook > /workspace/from_hook"}]}

    context = %{
      root: tmp_dir,
      run_id: "run_hook_#{System.unique_integer([:positive])}",
      trust: :untrusted
    }

    {result, run_id} = run_with_run_id([stage], context, hooks: hooks)
    assert {:ok, [%{status: :passed}]} = result
    assert File.read!(Path.join(tmp_dir, "from_hook")) == "hook\n"
    assert containers_for(run_id) == []
  end

  test "network: false is enforced on stages", %{tmp_dir: tmp_dir} do
    stage = %Stage{
      name: :build,
      mode: :serial,
      network: false,
      steps: [%Step{name: :route, cmd: "cat /proc/net/route"}]
    }

    context = %{
      root: tmp_dir,
      run_id: "run_net_#{System.unique_integer([:positive])}",
      trust: :untrusted
    }

    assert {:ok, [%{status: :passed, step_results: [result]}]} =
             Executor.run_pipeline([stage], context, opts())

    refute result.output =~ ~r/^[^\t]+\t00000000\t/m
  end

  test "a pipeline image is inherited and a stage image replaces it", %{tmp_dir: tmp_dir} do
    {:ok, runtime} = Container.runtime()
    override = "alpine:3.21"
    ensure_image(runtime, override)

    inherited = %Stage{
      name: :inherited,
      mode: :serial,
      steps: [%Step{name: :release, cmd: "cat /etc/alpine-release"}]
    }

    overridden = %Stage{
      name: :overridden,
      mode: :serial,
      image: override,
      steps: [%Step{name: :release, cmd: "cat /etc/alpine-release"}]
    }

    context = %{
      root: tmp_dir,
      run_id: "run_image_#{System.unique_integer([:positive])}",
      trust: :trusted
    }

    {result, run_id} = run_with_run_id([inherited, overridden], context, pipeline_image: image())

    assert {:ok, [%{step_results: [inherited_result]}, %{step_results: [overridden_result]}]} =
             result

    assert String.starts_with?(inherited_result.output, "3.22")
    assert String.starts_with?(overridden_result.output, "3.21")
    assert containers_for(run_id) == []
  end

  test "matrix combinations share the stage's resolved image", %{tmp_dir: tmp_dir} do
    stage = %Stage{
      name: :compat,
      mode: :serial,
      matrix: [variant: ["a", "b"]],
      # Rootless Podman can race two fresh user namespaces; serialising the two
      # combinations keeps this smoke test deterministic without weakening what
      # it proves (both sessions come from the same resolved image).
      max_parallel: 1,
      steps: [%Step{name: :release, cmd: "cat /etc/alpine-release"}]
    }

    context = %{
      root: tmp_dir,
      run_id: "run_matrix_image_#{System.unique_integer([:positive])}",
      trust: :trusted
    }

    {result, run_id} = run_with_run_id([stage], context, pipeline_image: image())

    assert {:ok, [%{status: :passed, matrix_runs: [first, second]}]} = result

    outputs =
      Enum.map([first, second], fn run ->
        assert [%{output: output}] = run.step_results
        output
      end)

    assert [a, b] = outputs
    assert a == b
    assert String.starts_with?(a, "3.22")
    assert containers_for(run_id) == []
  end

  defp ensure_image(runtime, image) do
    case System.cmd(runtime.command, ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _} ->
        case System.cmd(runtime.command, ["pull", image], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("could not pull #{image} (#{status}): #{output}")
        end
    end
  end

  defp containers_for(run_id) do
    {:ok, runtime} = Container.runtime()

    {output, 0} =
      System.cmd(
        runtime.command,
        ["ps", "-a", "--filter", "label=tiny_ci.run_id=#{run_id}", "--format", "{{.ID}}"],
        stderr_to_stdout: true
      )

    output |> String.split("\n", trim: true)
  end
end
