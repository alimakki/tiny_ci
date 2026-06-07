defmodule TinyCI.Events.Sink.NDJSON do
  @moduledoc """
  `TinyCI.EventSink` that writes the run as newline-delimited JSON (one event per
  line) — the durable, machine-readable form of the event stream.

  Each line is the event's own JSON encoding with three envelope fields added:
  `seq` (monotonic), `type` (the `TinyCI.Events.type/1` vocabulary string), and
  `ts` (ISO-8601, replacing the struct's `timestamp` key). The `run_started`
  line additionally carries `schema_version`.

  ## Options

    * `:path`   — a filesystem path to write to, or `"-"` for stdout
    * `:device` — an already-open IO device to write to (used in tests)

  Exactly one of `:path` / `:device` is expected; `:device` wins if both are given.
  """

  @behaviour TinyCI.EventSink

  @impl TinyCI.EventSink
  def init(opts) do
    {device, owns?} = open(opts)
    {:ok, %{device: device, owns?: owns?}}
  end

  @impl TinyCI.EventSink
  def handle_event(seq, event, %{device: device} = state) do
    write_line(device, encode_line(seq, event))
    {:ok, state}
  end

  @impl TinyCI.EventSink
  def close(%{owns?: true, device: device}) do
    File.close(device)
    :ok
  end

  def close(%{owns?: false}), do: :ok

  defp open(opts) do
    cond do
      device = opts[:device] -> {device, false}
      opts[:path] in [nil, "-"] -> {:default, false}
      true -> {File.open!(opts[:path], [:write, :utf8]), true}
    end
  end

  defp encode_line(seq, event) do
    event
    |> Jason.encode!()
    |> Jason.decode!()
    |> envelope(seq, event)
    |> Jason.encode!()
  end

  defp envelope(map, seq, event) do
    type = TinyCI.Events.type(event)

    map
    |> Map.put("seq", seq)
    |> Map.put("type", type)
    |> Map.put("ts", map["timestamp"])
    |> Map.delete("timestamp")
    |> maybe_schema_version(type)
  end

  defp maybe_schema_version(map, "run_started"),
    do: Map.put(map, "schema_version", TinyCI.Events.schema_version())

  defp maybe_schema_version(map, _type), do: map

  defp write_line(:default, line), do: IO.puts(line)
  defp write_line(device, line), do: IO.puts(device, line)
end
