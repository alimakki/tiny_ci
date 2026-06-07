defmodule TinyCI.Events.Sink.NDJSONTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias TinyCI.Events.Sink.NDJSON
  alias TinyCI.Events.{PipelineStarted, StageStarted}

  @ts ~U[2024-01-15 10:30:00.000000Z]
  @iso "2024-01-15T10:30:00.000000Z"

  defp run(opts, events) do
    {:ok, state} = NDJSON.init(opts)

    final =
      events
      |> Enum.with_index(1)
      |> Enum.reduce(state, fn {event, seq}, st ->
        {:ok, st} = NDJSON.handle_event(seq, event, st)
        st
      end)

    NDJSON.close(final)
  end

  test "writes one JSON object per line carrying seq, type, run_id, and ts" do
    {:ok, io} = StringIO.open("")

    run([device: io], [
      %PipelineStarted{run_id: "r1", timestamp: @ts, pipeline_name: :app},
      %StageStarted{run_id: "r1", timestamp: @ts, stage: :build}
    ])

    {_in, out} = StringIO.contents(io)
    lines = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert length(lines) == 2
    [first, second] = lines

    assert first["seq"] == 1
    assert first["type"] == "run_started"
    assert first["run_id"] == "r1"
    assert first["ts"] == @iso
    refute Map.has_key?(first, "timestamp")

    assert second["seq"] == 2
    assert second["type"] == "stage_started"
    assert second["stage"] == "build"
  end

  test "includes schema_version only on the run_started line" do
    {:ok, io} = StringIO.open("")

    run([device: io], [
      %PipelineStarted{run_id: "r1", timestamp: @ts, pipeline_name: :app},
      %StageStarted{run_id: "r1", timestamp: @ts, stage: :build}
    ])

    {_in, out} = StringIO.contents(io)
    [first, second] = out |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1)

    assert first["schema_version"] == TinyCI.Events.schema_version()
    refute Map.has_key?(second, "schema_version")
  end

  test "path \"-\" writes NDJSON to stdout" do
    out =
      capture_io(fn ->
        run([path: "-"], [%StageStarted{run_id: "r", timestamp: @ts, stage: :build}])
      end)

    line = out |> String.split("\n", trim: true) |> hd() |> Jason.decode!()
    assert line["type"] == "stage_started"
    assert line["seq"] == 1
  end

  test "path FILE writes a file whose every line parses as JSON" do
    path = Path.join(System.tmp_dir!(), "ndjson_#{System.unique_integer([:positive])}.ndjson")
    on_exit(fn -> File.rm(path) end)

    run([path: path], [
      %StageStarted{run_id: "r", timestamp: @ts, stage: :build},
      %StageStarted{run_id: "r", timestamp: @ts, stage: :test}
    ])

    lines = path |> File.read!() |> String.split("\n", trim: true)
    assert length(lines) == 2
    Enum.each(lines, fn line -> assert {:ok, _} = Jason.decode(line) end)
  end
end
