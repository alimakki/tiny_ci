defmodule TinyCI.Events.Dispatcher do
  @moduledoc """
  Per-run event dispatcher: assigns a monotonic `seq` to every event and fans it
  out to the registered `TinyCI.EventSink`s.

  One dispatcher is started per pipeline run (its pid is carried on the run
  context — see `TinyCI.Events.emit/2`), so concurrent runs never share state and
  `async: true` tests stay isolated. Because every `emit/2` is serialized through
  this single process, `seq` is strictly monotonic even when parallel stages,
  steps, and matrix combinations emit concurrently.

  Sinks are isolated from the run: an exception in one sink is caught and logged,
  and never affects pipeline pass/fail or the other sinks.
  """

  use GenServer

  require Logger

  @typedoc "A sink spec: a module implementing `TinyCI.EventSink` plus its init opts."
  @type sink_spec :: {module(), keyword()}

  @doc """
  Starts a dispatcher for the given sink specs.

  Each spec is `{sink_module, opts}`; `sink_module.init(opts)` is called once
  here to obtain the sink's initial state.
  """
  @spec start_link([sink_spec()]) :: GenServer.on_start()
  def start_link(sink_specs) when is_list(sink_specs) do
    GenServer.start_link(__MODULE__, sink_specs)
  end

  @doc """
  Emits an event: stamps the next `seq` and delivers it to every sink in order.

  Synchronous, so callers (and parallel tasks) observe ordering and no events are
  lost when the run stops immediately afterwards.
  """
  @spec emit(pid(), TinyCI.Events.t()) :: :ok
  def emit(dispatcher, event) when is_pid(dispatcher) do
    GenServer.call(dispatcher, {:emit, event})
  end

  @doc """
  Closes every sink (flushing/closing resources) and stops the dispatcher.
  """
  @spec stop(pid()) :: :ok
  def stop(dispatcher) when is_pid(dispatcher) do
    GenServer.stop(dispatcher)
  end

  @impl GenServer
  def init(sink_specs) do
    Process.flag(:trap_exit, true)
    sinks = Enum.map(sink_specs, fn {mod, opts} -> {mod, init_sink(mod, opts)} end)
    {:ok, %{seq: 0, sinks: sinks}}
  end

  @impl GenServer
  def handle_call({:emit, event}, _from, %{seq: seq, sinks: sinks} = state) do
    next = seq + 1
    sinks = Enum.map(sinks, fn sink -> deliver(sink, next, event) end)
    {:reply, :ok, %{state | seq: next, sinks: sinks}}
  end

  @impl GenServer
  def terminate(_reason, %{sinks: sinks}) do
    Enum.each(sinks, &close_sink/1)
    :ok
  end

  defp init_sink(mod, opts) do
    {:ok, state} = mod.init(opts)
    state
  end

  defp deliver({mod, sink_state}, seq, event) do
    {:ok, new_state} = mod.handle_event(seq, event, sink_state)
    {mod, new_state}
  rescue
    error ->
      Logger.error("event sink #{inspect(mod)} raised: #{Exception.message(error)}")
      {mod, sink_state}
  end

  defp close_sink({mod, sink_state}) do
    mod.close(sink_state)
  rescue
    error ->
      Logger.error("event sink #{inspect(mod)} raised on close: #{Exception.message(error)}")
      :ok
  end
end
