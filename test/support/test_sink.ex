defmodule TinyCI.TestSink do
  @moduledoc """
  An event sink that forwards every event to a test process as `{:event, event}`.

  Attach it with `extra_sinks: [{TinyCI.TestSink, pid: self()}]` on
  `TinyCI.Executor.run_pipeline/3` and assert on the stream with `assert_receive`.
  """

  @behaviour TinyCI.EventSink

  @impl true
  def init(opts), do: {:ok, %{pid: Keyword.fetch!(opts, :pid)}}

  @impl true
  def handle_event(_seq, event, %{pid: pid} = state) do
    send(pid, {:event, event})
    {:ok, state}
  end

  @impl true
  def close(_state), do: :ok
end
