defmodule TinyCI.Provenance.Collector do
  @moduledoc """
  A `TinyCI.EventSink` that accumulates a run's events into an `Agent`, so
  provenance is built from the observed **event stream** (T1) rather than from
  executor internals.

  The run driver starts an `Agent` (holding a list), passes it as
  `init/1`'s `:agent` option, and after the run reads the events back with
  `events/1`. The sink itself is stateless beyond the agent reference; the agent
  outlives the dispatcher so the events survive `close/1`.
  """

  @behaviour TinyCI.EventSink

  @impl true
  def init(opts) do
    {:ok, Keyword.fetch!(opts, :agent)}
  end

  @impl true
  def handle_event(_seq, event, agent) do
    Agent.update(agent, &[event | &1])
    {:ok, agent}
  end

  @impl true
  def close(_agent), do: :ok

  @doc "Returns the collected events for the run, in emission order."
  @spec events(pid()) :: [TinyCI.Events.t()]
  def events(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()
end
