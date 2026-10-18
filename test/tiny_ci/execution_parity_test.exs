defmodule TinyCI.ExecutionParityTest do
  @moduledoc """
  Invariant I1: mode changes defaults and policy, never the execution code path.

  A local run and a server-trusted run must produce the same structured results
  and the same ordered event stream. `async: false` because the runner mode is
  application environment, which every test in the VM shares.
  """

  use ExUnit.Case, async: false

  alias TinyCI.{Execution, Executor, Stage, StageResult, Step, StepResult}
  alias TinyCI.Events.{PipelineCompleted, PipelineStarted, StageStarted}

  @silent [console: false, output: :buffered, record: false]

  setup do
    previous = Application.get_env(:tiny_ci, :mode)

    on_exit(fn ->
      if previous do
        Application.put_env(:tiny_ci, :mode, previous)
      else
        Application.delete_env(:tiny_ci, :mode)
      end
    end)

    :ok
  end

  defp put_mode(mode), do: Application.put_env(:tiny_ci, :mode, mode)

  defp run_with_events(stages, context) do
    opts = @silent ++ [extra_sinks: [{TinyCI.TestSink, pid: self()}]]
    result = Executor.run_pipeline(stages, context, opts)
    {result, drain_events([])}
  end

  defp drain_events(acc) do
    receive do
      {:event, event} -> drain_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp normalize_result({:ok, results}), do: {:ok, Enum.map(results, &normalize/1)}

  defp normalize_result({:error, reason, results}),
    do: {:error, reason, Enum.map(results, &normalize/1)}

  defp normalize(%StageResult{} = result) do
    %{result | duration_ms: nil, step_results: Enum.map(result.step_results, &normalize_step/1)}
  end

  defp normalize_step(%StepResult{} = result), do: %{result | duration_ms: nil}

  defp normalize_event(%module{} = event) do
    event
    |> Map.drop([:run_id, :timestamp, :duration_ms])
    |> Map.put(:__struct__, module)
  end

  defp assert_parity(stages) do
    put_mode(:local)
    assert Execution.default_trust() == :trusted
    {local_result, local_events} = run_with_events(stages, %{root: File.cwd!()})

    put_mode(:server)
    assert Execution.default_trust() == :untrusted

    {server_result, server_events} =
      run_with_events(stages, %{root: File.cwd!(), trust: :trusted})

    assert normalize_result(local_result) == normalize_result(server_result)
    assert local_events != []

    assert Enum.map(local_events, &normalize_event/1) ==
             Enum.map(server_events, &normalize_event/1)
  end

  describe "local/server parity" do
    test "a passing shell pipeline is identical in both modes" do
      assert_parity([
        %Stage{
          name: :build,
          mode: :serial,
          steps: [
            %Step{name: :one, cmd: "echo one"},
            %Step{name: :two, cmd: "echo two"}
          ]
        }
      ])
    end

    test "a failing shell pipeline is identical in both modes" do
      assert_parity([
        %Stage{
          name: :build,
          mode: :serial,
          steps: [%Step{name: :bad, cmd: "echo nope; false"}]
        }
      ])
    end
  end

  describe "server mode policy" do
    test "an invocation with no explicit trust fails closed before any stage" do
      put_mode(:server)

      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "true"}]}
      opts = @silent ++ [extra_sinks: [{TinyCI.TestSink, pid: self()}]]

      assert {:error, {:execution_unavailable, :no_default_image}, []} =
               Executor.run_pipeline([stage], %{root: File.cwd!()}, opts)

      assert_receive {:event, %PipelineStarted{}}
      assert_receive {:event, %PipelineCompleted{status: :failed}}
      refute_received {:event, %StageStarted{}}
    end

    test "a trusted invocation stays on the same executor path in server mode" do
      put_mode(:server)
      assert Execution.default_trust() == :untrusted

      stage = %Stage{name: :build, mode: :serial, steps: [%Step{name: :one, cmd: "echo ok"}]}

      assert {:ok, [%StageResult{status: :passed}]} =
               Executor.run_pipeline([stage], %{root: File.cwd!(), trust: :trusted}, @silent)
    end
  end
end
