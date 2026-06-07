defmodule TinyCI.EventSink do
  @moduledoc """
  Behaviour for consumers of the structured run event stream.

  A sink is registered with `TinyCI.Events.Dispatcher` at the start of a run.
  The dispatcher calls `init/1` once, `handle_event/3` for every event (in
  monotonic `seq` order), and `close/1` once when the run ends.

  This is the realization of the build plan's `handle_event/1` idea, extended
  with the per-event `seq` and an opaque `state` so sinks can be stateful
  (e.g. an NDJSON sink holding an open file, or the console sink buffering
  per-step output until a stage finishes). A sink that needs neither may ignore
  both and treat `handle_event/3` as `handle_event/1`.

  ## Example

      defmodule MySink do
        @behaviour TinyCI.EventSink

        @impl true
        def init(_opts), do: {:ok, %{count: 0}}

        @impl true
        def handle_event(_seq, _event, state), do: {:ok, %{state | count: state.count + 1}}

        @impl true
        def close(_state), do: :ok
      end
  """

  @typedoc "Opaque, sink-specific state threaded across callbacks."
  @type state :: term()

  @doc """
  Called once before any events are delivered. Returns the initial sink state.
  """
  @callback init(opts :: keyword()) :: {:ok, state()}

  @doc """
  Called for each emitted event, in monotonically increasing `seq` order.

  `seq` starts at 1 for the first event of a run. Returns the updated state.
  """
  @callback handle_event(seq :: pos_integer(), event :: TinyCI.Events.t(), state()) ::
              {:ok, state()}

  @doc """
  Called once when the run ends. Flush/close any resources here.
  """
  @callback close(state()) :: :ok
end
