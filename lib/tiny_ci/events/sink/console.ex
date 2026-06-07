defmodule TinyCI.Events.Sink.Console do
  @moduledoc """
  `TinyCI.EventSink` that renders human-readable run progress by consuming events.

  This is how the human console output becomes a *consumer* of the event stream.
  It currently renders the stage-lifecycle headers (`stage_started`) and skip
  notices (`stage_skipped`) — the stateless, order-tolerant parts of the progress
  output. The order-sensitive renderings (buffered per-step output, matrix output,
  retry attempt notices) remain on the legacy `TinyCI.Listener` for now; see
  `docs/events.md` and the T1 task notes for the deferred deep reroute.

  Registered automatically for a run unless `listener: TinyCI.Listener.Silent` is
  given, in which case no console sink is attached (suppressing progress output).
  """

  @behaviour TinyCI.EventSink

  alias TinyCI.Events.{StageSkipped, StageStarted}

  @impl TinyCI.EventSink
  def init(_opts), do: {:ok, %{}}

  @impl TinyCI.EventSink
  def handle_event(_seq, %StageStarted{stage: stage}, state) do
    IO.puts("Stage: #{stage}")
    {:ok, state}
  end

  def handle_event(_seq, %StageSkipped{reason: reason}, state) do
    IO.puts("  Skipped (#{reason})")
    {:ok, state}
  end

  def handle_event(_seq, _event, state), do: {:ok, state}

  @impl TinyCI.EventSink
  def close(_state), do: :ok
end
