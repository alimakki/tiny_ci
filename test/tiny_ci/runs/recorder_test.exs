defmodule TinyCI.Runs.RecorderTest do
  # async: false because the run store's location is application env, which every
  # test in the VM shares.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TinyCI.Events.Dispatcher
  alias TinyCI.Events.{StageStarted, StepOutputLine}
  alias TinyCI.Runs
  alias TinyCI.Runs.{Projection, Recorder}
  alias TinyCI.RunsFixtures

  @moduletag :tmp_dir

  @root "/work/app"
  @run_id "20260102_030405_abc1234_00000000000000000000000000000001"

  setup %{tmp_dir: tmp_dir} do
    RunsFixtures.redirect_runs_dir(tmp_dir)
    :ok
  end

  defp record(events, opts \\ [root: @root, run_id: @run_id]) do
    {:ok, state} = Recorder.init(opts)

    final =
      events
      |> Enum.with_index(1)
      |> Enum.reduce(state, fn {event, seq}, acc ->
        {:ok, acc} = Recorder.handle_event(seq, event, acc)
        acc
      end)

    {Recorder.close(final), final}
  end

  defp read_events(dir) do
    dir
    |> Path.join("events.ndjson")
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end

  describe "init/1, handle_event/3 and close/1" do
    test "write events.ndjson and meta.json under <base>/<project_id>/<run_id>" do
      {closed, _state} = record(RunsFixtures.passing_events(@run_id))
      assert closed == :ok

      dir = Runs.dir(@root, @run_id)
      assert File.regular?(Path.join(dir, "events.ndjson"))
      assert File.regular?(Path.join(dir, "meta.json"))
      assert dir == Path.join([Runs.base_dir(), TinyCI.Artifacts.project_id(@root), @run_id])
    end

    test "events.ndjson holds one decodable line per event, in seq order" do
      events = RunsFixtures.passing_events(@run_id)
      record(events)

      lines = read_events(Runs.dir(@root, @run_id))

      assert length(lines) == length(events)
      assert Enum.map(lines, & &1["seq"]) == Enum.to_list(1..length(events))
      assert hd(lines)["type"] == "run_started"
      assert hd(lines)["schema_version"] == 3
    end

    test "meta.json equals the projection of events.ndjson" do
      record(RunsFixtures.passing_events(@run_id))

      dir = Runs.dir(@root, @run_id)
      meta = dir |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

      folded =
        dir |> read_events() |> Projection.fold() |> Projection.finalize() |> Projection.to_json()

      assert meta == folded
      assert meta["status"] == "passed"
      assert meta["branch"] == "main"
    end

    test "leaves no staging file behind" do
      record(RunsFixtures.passing_events(@run_id))
      refute File.exists?(Path.join(Runs.dir(@root, @run_id), "meta.json.tmp"))
    end

    test "a stream that ends without run_finished is recorded as interrupted" do
      events = Enum.take(RunsFixtures.passing_events(@run_id), 3)
      record(events)

      meta = Runs.dir(@root, @run_id) |> Path.join("meta.json") |> File.read!() |> Jason.decode!()

      assert meta["status"] == "interrupted"
      assert [%{"status" => "interrupted"}] = meta["stages"]
    end
  end

  describe "a run that emitted nothing" do
    test "leaves no directory behind" do
      {:ok, state} = Recorder.init(root: @root, run_id: @run_id)
      assert File.dir?(Runs.dir(@root, @run_id))

      assert :ok = Recorder.close(state)

      refute File.exists?(Runs.dir(@root, @run_id))
      assert Runs.list(@root) == []
    end
  end

  describe "never failing the run" do
    test "warns on stderr, not stdout, so machine-readable output stays clean" do
      blocker = Path.join(Application.get_env(:tiny_ci, :runs_base_dir), "blocker")
      File.write!(blocker, "a file, not a directory")
      Application.put_env(:tiny_ci, :runs_base_dir, Path.join(blocker, "runs"))

      stdout =
        capture_io(fn ->
          stderr = capture_io(:stderr, fn -> Recorder.init(root: @root, run_id: @run_id) end)
          assert stderr =~ "Warning: run recording disabled"
        end)

      assert stdout == ""
    end

    test "an unwritable base dir disables the recorder with one warning, without raising" do
      blocker = Path.join(Application.get_env(:tiny_ci, :runs_base_dir), "blocker")
      File.write!(blocker, "a file, not a directory")
      Application.put_env(:tiny_ci, :runs_base_dir, Path.join(blocker, "runs"))

      log =
        capture_io(:stderr, fn ->
          {:ok, state} = Recorder.init(root: @root, run_id: @run_id)
          assert %Recorder{disabled?: true} = state

          event = %StageStarted{run_id: @run_id, timestamp: DateTime.utc_now(), stage: :a}
          assert {:ok, %Recorder{disabled?: true}} = Recorder.handle_event(1, event, state)
          assert :ok = Recorder.close(state)
        end)

      assert log =~ "run recording disabled"
      assert length(Regex.scan(~r/run recording disabled/, log)) == 1
    end

    test "a write error mid-run disables the recorder and writes no meta.json" do
      {:ok, state} = Recorder.init(root: @root, run_id: @run_id)
      File.close(state.device)

      event = %StepOutputLine{
        run_id: @run_id,
        timestamp: DateTime.utc_now(),
        stage: :a,
        step: :b,
        line: "x"
      }

      log =
        capture_io(:stderr, fn ->
          assert {:ok, %Recorder{disabled?: true} = disabled} =
                   Recorder.handle_event(1, event, state)

          assert :ok = Recorder.close(disabled)
        end)

      assert log =~ "run recording disabled"
      refute File.exists?(Path.join(Runs.dir(@root, @run_id), "meta.json"))
    end

    test "missing options disable the recorder rather than crash the dispatcher" do
      log =
        capture_io(:stderr, fn -> assert {:ok, %Recorder{disabled?: true}} = Recorder.init([]) end)

      assert log =~ "run recording disabled"
    end
  end

  describe "as a dispatcher sink" do
    test "records a run emitted through a real dispatcher" do
      {:ok, dispatcher} = Dispatcher.start_link([{Recorder, root: @root, run_id: @run_id}])
      Enum.each(RunsFixtures.passing_events(@run_id), &Dispatcher.emit(dispatcher, &1))
      Dispatcher.stop(dispatcher)

      assert {:ok, %Projection{status: :passed}} = Runs.projection(@root, @run_id)
    end

    test "masks secret values, because the dispatcher redacts before any sink" do
      {:ok, dispatcher} =
        Dispatcher.start_link([{Recorder, root: @root, run_id: @run_id}],
          redact: ["hunter2-token"]
        )

      Dispatcher.emit(dispatcher, %StepOutputLine{
        run_id: @run_id,
        timestamp: DateTime.utc_now(),
        stage: :a,
        step: :b,
        line: "token=hunter2-token"
      })

      Dispatcher.stop(dispatcher)

      raw = Runs.dir(@root, @run_id) |> Path.join("events.ndjson") |> File.read!()
      refute raw =~ "hunter2-token"
      assert raw =~ "token=***"
    end

    test "a disabled recorder does not stop the other sinks or the run" do
      blocker = Path.join(Application.get_env(:tiny_ci, :runs_base_dir), "blocker")
      File.write!(blocker, "x")
      Application.put_env(:tiny_ci, :runs_base_dir, Path.join(blocker, "runs"))

      capture_io(:stderr, fn ->
        {:ok, dispatcher} =
          Dispatcher.start_link([
            {Recorder, root: @root, run_id: @run_id},
            {TinyCI.TestSink, pid: self()}
          ])

        event = %StageStarted{run_id: @run_id, timestamp: DateTime.utc_now(), stage: :a}
        assert :ok = Dispatcher.emit(dispatcher, event)
        assert_received {:event, ^event}
        assert :ok = Dispatcher.stop(dispatcher)
      end)
    end
  end
end
