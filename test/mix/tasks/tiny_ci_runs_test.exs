defmodule Mix.Tasks.TinyCi.RunsTest do
  # async: false because the run store's location is application env, and the run
  # task writes into it.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.TinyCi.{Run, Runs}
  alias TinyCI.Events.RunDiverged
  alias TinyCI.RunsFixtures

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    root = Path.join(tmp_dir, "project")
    File.mkdir_p!(root)
    RunsFixtures.redirect_runs_dir(Path.join(tmp_dir, "store"))

    File.write!(Path.join(root, "tiny_ci.exs"), """
    stage :build, mode: :serial do
      step :hello, cmd: "echo hello-from-run"
    end
    """)

    {:ok, root: root}
  end

  defp run_pipeline(root, extra \\ []) do
    capture_io(fn ->
      assert :ok = Run.run(["--file", Path.join(root, "tiny_ci.exs"), "--root", root] ++ extra)
    end)
  end

  defp runs(args), do: capture_io(fn -> Runs.run(args) end)

  # One tolerated failure (noisy) and one real failure with 60 lines of output.
  defp failing_events(id) do
    alias TinyCI.Events.{
      PipelineCompleted,
      PipelineStarted,
      StageCompleted,
      StageStarted,
      StepCompleted,
      StepStarted
    }

    base = [run_id: id, timestamp: ~U[2026-01-01 00:00:00.000000Z]]
    output = Enum.map_join(1..60, "\n", &"line #{&1}") <> "\n"

    [
      struct!(PipelineStarted, base ++ [pipeline_name: :app]),
      struct!(StageStarted, base ++ [stage: :test]),
      struct!(StepStarted, base ++ [stage: :test, step: :flaky]),
      struct!(
        StepCompleted,
        base ++
          [
            stage: :test,
            step: :flaky,
            status: :failed,
            duration_ms: 1,
            output: "tolerated-noise\n",
            allowed_failure: true
          ]
      ),
      struct!(StepStarted, base ++ [stage: :test, step: :unit]),
      struct!(
        StepCompleted,
        base ++ [stage: :test, step: :unit, status: :failed, duration_ms: 2, output: output]
      ),
      struct!(StageCompleted, base ++ [stage: :test, status: :failed, duration_ms: 3]),
      struct!(PipelineCompleted, base ++ [status: :failed, duration_ms: 4])
    ]
  end

  defp only_run_id(root) do
    [run] = TinyCI.Runs.list(root)
    run.run_id
  end

  describe "recording through mix tiny_ci.run" do
    test "a run leaves events.ndjson and meta.json in the run store", %{root: root} do
      run_pipeline(root)

      dir = TinyCI.Runs.dir(root, only_run_id(root))
      assert File.regular?(Path.join(dir, "events.ndjson"))
      assert File.regular?(Path.join(dir, "meta.json"))
    end

    test "--no-record leaves nothing", %{root: root} do
      run_pipeline(root, ["--no-record"])
      assert TinyCI.Runs.list(root) == []
    end

    test "--dry-run leaves nothing", %{root: root} do
      run_pipeline(root, ["--dry-run"])
      assert TinyCI.Runs.list(root) == []
    end

    test "a failing run is recorded too", %{root: root} do
      File.write!(Path.join(root, "tiny_ci.exs"), """
      stage :bad, mode: :serial do
        step :boom, cmd: "echo before-the-end; exit 3"
      end
      """)

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert_raise Mix.Error, fn ->
            Run.run(["--file", Path.join(root, "tiny_ci.exs"), "--root", root])
          end
        end)
      end)

      assert [%{status: :failed}] = TinyCI.Runs.list(root)
    end
  end

  describe "runs (list)" do
    test "lists a recorded run with its status, pipeline and id", %{root: root} do
      run_pipeline(root)

      out = runs(["--root", root])

      assert out =~ only_run_id(root)
      assert out =~ "passed"
      assert out =~ "STATUS"
      assert out =~ "PIPELINE"
    end

    test "says so when nothing has been recorded", %{root: root} do
      assert runs(["--root", root]) =~ "No runs recorded"
    end

    test "--output json prints a parseable list of projections", %{root: root} do
      run_pipeline(root)

      assert [%{"run_id" => run_id, "status" => "passed", "stages" => [%{"name" => "build"}]}] =
               root |> then(&runs(["--root", &1, "--output", "json"])) |> Jason.decode!()

      assert run_id == only_run_id(root)
    end

    test "--output json is an empty list when there are no runs", %{root: root} do
      assert runs(["--root", root, "--output", "json"]) |> Jason.decode!() == []
    end

    test "--limit caps the number of runs, newest first", %{root: root} do
      Enum.each(1..3, fn n ->
        id = "2026010#{n}_000000_abc1234_" <> String.pad_leading("#{n}", 32, "0")
        RunsFixtures.write_run(root, id, RunsFixtures.passing_events(id))
      end)

      out = runs(["--root", root, "--limit", "2"])

      assert out =~ "20260103_"
      assert out =~ "20260102_"
      refute out =~ "20260101_"
    end

    test "an unfinished recording is listed as interrupted", %{root: root} do
      id = "20260101_000000_abc1234_" <> String.duplicate("0", 32)
      events = Enum.take(RunsFixtures.passing_events(id), 3)
      RunsFixtures.write_run(root, id, events, meta: false)

      assert runs(["--root", root]) =~ "interrupted"
    end

    test "rejects an unknown output format and unknown commands", %{root: root} do
      assert_raise Mix.Error, ~r/Unknown --output format/, fn ->
        runs(["--root", root, "--output", "xml"])
      end

      assert_raise Mix.Error, ~r/Unknown command/, fn -> runs(["frobnicate"]) end

      for bad <- ["0", "-3"] do
        assert_raise Mix.Error, ~r/--limit must be a positive integer/, fn ->
          runs(["--root", root, "--limit=#{bad}"])
        end
      end

      assert_raise Mix.Error, ~r/Invalid option/, fn -> runs(["--root", root, "--bogus"]) end
    end
  end

  describe "runs show" do
    test "prints the run's identity and the stage tree", %{root: root} do
      run_pipeline(root)
      id = only_run_id(root)

      out = runs(["show", id, "--root", root])

      assert out =~ id
      assert out =~ "Pipeline Summary"
      assert out =~ "build"
      assert out =~ "hello"
      assert out =~ "passed"
    end

    test "--output json prints the run's projection", %{root: root} do
      run_pipeline(root)
      id = only_run_id(root)

      json = runs(["show", id, "--root", root, "--output", "json"]) |> Jason.decode!()

      assert %{"run_id" => ^id, "status" => "passed", "stages" => [stage]} = json
      assert %{"name" => "build", "steps" => [%{"name" => "hello", "output" => output}]} = stage
      assert output =~ "hello-from-run"
    end

    test "--events prints the raw recording, one JSON object per line", %{root: root} do
      run_pipeline(root)
      id = only_run_id(root)

      lines = runs(["show", id, "--root", root, "--events"]) |> String.split("\n", trim: true)
      decoded = Enum.map(lines, &Jason.decode!/1)

      assert hd(decoded)["type"] == "run_started"
      assert List.last(decoded)["type"] == "run_finished"
      assert Enum.map(decoded, & &1["seq"]) == Enum.to_list(1..length(decoded))
    end

    test "prints why a step failed, but not the noise of a tolerated failure", %{root: root} do
      id = "20260101_000000_abc1234_" <> String.duplicate("0", 32)
      RunsFixtures.write_run(root, id, failing_events(id))

      out = runs(["show", id, "--root", root])

      assert out =~ "Output of failed step test/unit:"
      refute out =~ "tolerated-noise"
    end

    test "shows only the last 50 lines of a failed step's output", %{root: root} do
      id = "20260101_000000_abc1234_" <> String.duplicate("0", 32)
      RunsFixtures.write_run(root, id, failing_events(id))

      out = runs(["show", id, "--root", root])

      assert out =~ "10 earlier lines omitted"
      assert out =~ "  line 11\n"
      assert out =~ "  line 60\n"
      refute out =~ "  line 10\n"
    end

    test "says an unfinished run was interrupted", %{root: root} do
      id = "20260101_000000_abc1234_" <> String.duplicate("0", 32)
      events = Enum.take(RunsFixtures.passing_events(id), 3)
      RunsFixtures.write_run(root, id, events, meta: false)

      assert runs(["show", id, "--root", root]) =~ "interrupted"
    end

    test "flags a run that manual control altered", %{root: root} do
      id = "20260101_000000_abc1234_" <> String.duplicate("0", 32)

      events =
        RunsFixtures.passing_events(id) ++
          [%RunDiverged{run_id: id, timestamp: DateTime.utc_now(), reason: :skip}]

      RunsFixtures.write_run(root, id, events)

      assert runs(["show", id, "--root", root]) =~ "divergent"
    end

    test "fails clearly for an unknown run, a missing id, and an unsafe id", %{root: root} do
      assert_raise Mix.Error, ~r/not found/, fn -> runs(["show", "nope", "--root", root]) end
      assert_raise Mix.Error, ~r/RUN_ID/, fn -> runs(["show", "--root", root]) end
      assert_raise Mix.Error, ~r/not found/, fn -> runs(["show", "../x", "--root", root]) end
    end
  end

  describe "runs prune" do
    test "--keep 0 removes every run", %{root: root} do
      run_pipeline(root)
      run_pipeline(root)
      assert length(TinyCI.Runs.list(root)) == 2

      out = runs(["prune", "--keep", "0", "--root", root])

      assert out =~ "Removed 2 runs"
      assert TinyCI.Runs.list(root) == []
    end

    test "--keep N keeps the newest N", %{root: root} do
      Enum.each(1..3, fn n ->
        id = "2026010#{n}_000000_abc1234_" <> String.pad_leading("#{n}", 32, "0")
        RunsFixtures.write_run(root, id, RunsFixtures.passing_events(id))
      end)

      assert runs(["prune", "--keep", "1", "--root", root]) =~ "Removed 2 runs"
      assert [%{run_id: "20260103" <> _}] = TinyCI.Runs.list(root)
    end

    test "defaults to keeping 200 and removes nothing here", %{root: root} do
      run_pipeline(root)
      assert runs(["prune", "--root", root]) =~ "Removed 0 runs"
      assert length(TinyCI.Runs.list(root)) == 1
    end

    test "rejects a keep that is not a non-negative integer", %{root: root} do
      assert_raise Mix.Error, ~r/--keep must be a non-negative integer/, fn ->
        runs(["prune", "--keep=-1", "--root", root])
      end

      assert_raise Mix.Error, ~r/Invalid option/, fn ->
        runs(["prune", "--keep", "many", "--root", root])
      end
    end

    test "rejects a misspelt flag instead of silently pruning nothing", %{root: root} do
      run_pipeline(root)

      assert_raise Mix.Error, ~r/Invalid option/, fn ->
        runs(["prune", "--kepp=0", "--root", root])
      end

      assert length(TinyCI.Runs.list(root)) == 1
    end
  end
end
