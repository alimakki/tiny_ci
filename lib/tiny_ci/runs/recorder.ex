defmodule TinyCI.Runs.Recorder do
  @moduledoc """
  `TinyCI.EventSink` that records a run to the run store.

  It writes every event, in the exact NDJSON envelope `--events` uses, to the run's
  `events.ndjson`, and folds the same events into a `TinyCI.Runs.Projection`. On
  close it writes that projection as `meta.json`. See `TinyCI.Runs` for the layout.

  ## Options

    * `:root`   — the project root the run belongs to
    * `:run_id` — the run's id

  ## Never fails the run

  A recording is a convenience, never a reason for a build to fail. If the run
  directory cannot be created, or a write fails part-way, the recorder prints one
  warning to stderr and disables itself: it ignores every later event and writes
  nothing more. `init/1` never raises, because the dispatcher does not guard it. A
  recording cut short this way has no `meta.json`, so it lists as interrupted.

  The warning goes to stderr rather than through `Logger`, which writes to stdout
  and would corrupt `--output json` and `--events -`. A run that emitted no events
  at all leaves nothing behind: its empty run directory is removed.

  The dispatcher redacts secrets before any sink sees an event, so a recording
  never contains a secret value.
  """

  @behaviour TinyCI.EventSink

  alias TinyCI.Events.Sink.NDJSON
  alias TinyCI.Runs
  alias TinyCI.Runs.Projection

  defstruct dir: nil, device: nil, projection: nil, disabled?: false

  @type t :: %__MODULE__{
          dir: String.t() | nil,
          device: File.io_device() | nil,
          projection: Projection.t() | nil,
          disabled?: boolean()
        }

  @impl TinyCI.EventSink
  def init(opts) do
    dir = Runs.dir(Keyword.fetch!(opts, :root), Keyword.fetch!(opts, :run_id))
    File.mkdir_p!(dir)
    device = File.open!(Path.join(dir, Runs.events_file()), [:write, :binary])
    {:ok, %__MODULE__{dir: dir, device: device, projection: Projection.new()}}
  rescue
    error -> {:ok, disable(%__MODULE__{}, Exception.message(error))}
  end

  @impl TinyCI.EventSink
  def handle_event(_seq, _event, %__MODULE__{disabled?: true} = state), do: {:ok, state}

  def handle_event(seq, event, %__MODULE__{} = state) do
    line = NDJSON.encode_line(seq, event)

    # `:file.write/2` returns an error tuple where `IO.binwrite/2` would raise.
    case :file.write(state.device, [line, ?\n]) do
      :ok ->
        {:ok, %{state | projection: Projection.apply(state.projection, Jason.decode!(line))}}

      {:error, reason} ->
        {:ok, disable(state, "write failed: #{inspect(reason)}")}
    end
  end

  @impl TinyCI.EventSink
  def close(%__MODULE__{disabled?: true}), do: :ok

  def close(%__MODULE__{projection: %Projection{last_seq: 0}} = state), do: discard(state)

  def close(%__MODULE__{} = state) do
    File.close(state.device)

    case Runs.write_meta(state.dir, Projection.finalize(state.projection)) do
      :ok ->
        :ok

      {:error, reason} ->
        warn("run recording incomplete: could not write meta.json: #{inspect(reason)}")
    end
  end

  # Nothing was emitted, so there is no run to record. `rm` and `rmdir` only, never
  # recursive: whatever the run id was, this can remove nothing but an empty
  # recording the recorder itself just created.
  defp discard(state) do
    File.close(state.device)
    File.rm(Path.join(state.dir, Runs.events_file()))
    File.rmdir(state.dir)
    :ok
  end

  defp disable(state, reason) do
    warn("run recording disabled: #{reason}")
    if state.device, do: File.close(state.device)
    %{state | disabled?: true, device: nil}
  end

  defp warn(message) do
    IO.puts(:stderr, [IO.ANSI.yellow(), "Warning: ", message, IO.ANSI.reset()])
  end
end
