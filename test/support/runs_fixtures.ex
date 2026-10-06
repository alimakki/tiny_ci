defmodule TinyCI.RunsFixtures do
  @moduledoc """
  Helpers for tests that read or write the run store.

  The store location is application env, so a test that redirects it must be
  `async: false` and must put the previous value back. `redirect_runs_dir/1` does
  both halves of that, registering its own `on_exit/1`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  alias TinyCI.Events.Sink.NDJSON

  @ts ~U[2026-01-02 03:04:05.000000Z]

  @doc "Points `:runs_base_dir` at `dir` for the current test, restoring it on exit."
  @spec redirect_runs_dir(String.t()) :: :ok
  def redirect_runs_dir(dir) do
    previous = Application.get_env(:tiny_ci, :runs_base_dir)
    Application.put_env(:tiny_ci, :runs_base_dir, dir)
    on_exit(fn -> restore(previous) end)
  end

  defp restore(nil), do: Application.delete_env(:tiny_ci, :runs_base_dir)
  defp restore(previous), do: Application.put_env(:tiny_ci, :runs_base_dir, previous)

  @doc """
  A small passing run as events: one stage, one step with two output lines.
  """
  @spec passing_events(String.t()) :: [TinyCI.Events.t()]
  def passing_events(run_id) do
    alias TinyCI.Events.{
      PipelineCompleted,
      PipelineStarted,
      StageCompleted,
      StageStarted,
      StepCompleted,
      StepOutputLine,
      StepStarted
    }

    base = [run_id: run_id, timestamp: @ts]

    [
      struct!(
        PipelineStarted,
        base ++ [pipeline_name: :app, branch: "main", commit: "abc1234def"]
      ),
      struct!(StageStarted, base ++ [stage: :build]),
      struct!(StepStarted, base ++ [stage: :build, step: :compile]),
      struct!(StepOutputLine, base ++ [stage: :build, step: :compile, line: "one"]),
      struct!(StepOutputLine, base ++ [stage: :build, step: :compile, line: "two"]),
      struct!(
        StepCompleted,
        base ++ [stage: :build, step: :compile, status: :passed, duration_ms: 5]
      ),
      struct!(StageCompleted, base ++ [stage: :build, status: :passed, duration_ms: 6]),
      struct!(PipelineCompleted, base ++ [status: :passed, duration_ms: 7])
    ]
  end

  @doc "Encodes events as the NDJSON lines the recorder would have written."
  @spec ndjson_lines([TinyCI.Events.t()]) :: [String.t()]
  def ndjson_lines(events) do
    events
    |> Enum.with_index(1)
    |> Enum.map(fn {event, seq} -> NDJSON.encode_line(seq, event) end)
  end

  @doc """
  Writes `events.ndjson` (and optionally `meta.json`) for `run_id` straight into the
  store, without running anything. Returns the run directory.
  """
  @spec write_run(String.t(), String.t(), [TinyCI.Events.t()], keyword()) :: String.t()
  def write_run(root, run_id, events, opts \\ []) do
    dir = TinyCI.Runs.dir(root, run_id)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "events.ndjson"),
      Enum.map_join(ndjson_lines(events), "\n", & &1) <> "\n"
    )

    if Keyword.get(opts, :meta, true) do
      events
      |> ndjson_lines()
      |> Enum.map(&Jason.decode!/1)
      |> TinyCI.Runs.Projection.fold()
      |> TinyCI.Runs.Projection.finalize()
      |> then(&TinyCI.Runs.write_meta(dir, &1))
    end

    dir
  end
end
