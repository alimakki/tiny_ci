defmodule TinyCI.Provenance.CollectorTest do
  use ExUnit.Case, async: true

  alias TinyCI.Provenance.Collector
  alias TinyCI.Events.{PipelineCompleted, PipelineStarted}

  test "accumulates events into the agent in emission order" do
    {:ok, agent} = Agent.start_link(fn -> [] end)

    started = %PipelineStarted{run_id: "r", timestamp: DateTime.utc_now(), pipeline_name: :p}

    completed = %PipelineCompleted{
      run_id: "r",
      timestamp: DateTime.utc_now(),
      status: :passed,
      duration_ms: 1
    }

    {:ok, state} = Collector.init(agent: agent)
    {:ok, state} = Collector.handle_event(1, started, state)
    {:ok, state} = Collector.handle_event(2, completed, state)
    :ok = Collector.close(state)

    events = Collector.events(agent)
    assert [%PipelineStarted{}, %PipelineCompleted{}] = events

    Agent.stop(agent)
  end

  test "events/1 returns [] for an empty run" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    assert Collector.events(agent) == []
    Agent.stop(agent)
  end
end
