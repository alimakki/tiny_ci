defmodule TinyCI.RunsTest do
  # async: false because the run store's location is application env, which every
  # test in the VM shares.
  use ExUnit.Case, async: false

  alias TinyCI.Runs
  alias TinyCI.Runs.Projection
  alias TinyCI.RunsFixtures

  @moduletag :tmp_dir

  doctest TinyCI.Runs

  @root "/work/app"

  setup %{tmp_dir: tmp_dir} do
    RunsFixtures.redirect_runs_dir(tmp_dir)
    :ok
  end

  # Ids sort chronologically as strings, like `Artifacts.generate_run_id/1`'s.
  defp run_id(n) do
    "20260101_0000#{String.pad_leading(Integer.to_string(n), 2, "0")}_abc1234_" <>
      String.pad_leading(Integer.to_string(n), 32, "0")
  end

  defp write(n, opts \\ []),
    do: RunsFixtures.write_run(@root, run_id(n), RunsFixtures.passing_events(run_id(n)), opts)

  describe "base_dir/0" do
    test "prefers the configured directory", %{tmp_dir: tmp_dir} do
      assert Runs.base_dir() == tmp_dir
    end

    test "falls back to XDG_DATA_HOME, then ~/.local/share" do
      Application.delete_env(:tiny_ci, :runs_base_dir)
      previous = System.get_env("XDG_DATA_HOME")

      on_exit(fn ->
        if previous,
          do: System.put_env("XDG_DATA_HOME", previous),
          else: System.delete_env("XDG_DATA_HOME")
      end)

      System.put_env("XDG_DATA_HOME", "/xdg/data")
      assert Runs.base_dir() == "/xdg/data/tiny_ci/runs"

      System.delete_env("XDG_DATA_HOME")

      assert Runs.base_dir() ==
               Path.join([System.user_home!(), ".local/share", "tiny_ci", "runs"])
    end
  end

  describe "dir/2" do
    test "nests the run under the project, and expands the root first" do
      assert Runs.dir("some/relative", "r1") == Runs.dir(Path.expand("some/relative"), "r1")
      assert Runs.dir(@root, "r1") == Path.join(Runs.project_dir(@root), "r1")
      assert Runs.project_dir("/a") != Runs.project_dir("/b")
    end
  end

  describe "list/2" do
    test "returns the newest runs first, honouring limit" do
      Enum.each(1..3, &write/1)

      assert [run_id(3), run_id(2), run_id(1)] == Enum.map(Runs.list(@root), & &1.run_id)
      assert [run_id(3), run_id(2)] == Enum.map(Runs.list(@root, limit: 2), & &1.run_id)
    end

    test "defaults to 20 runs" do
      Enum.each(1..22, &write/1)
      assert length(Runs.list(@root)) == 20
    end

    test "returns projections read from meta.json" do
      write(1)

      assert [%Projection{status: :passed, branch: "main", pipeline: "app"}] = Runs.list(@root)
    end

    test "prefers meta.json over folding the recording" do
      dir = write(1)
      meta = Path.join(dir, "meta.json")

      File.write!(
        meta,
        meta
        |> File.read!()
        |> Jason.decode!()
        |> Map.put("branch", "from-meta")
        |> Jason.encode!()
      )

      assert [%Projection{branch: "from-meta"}] = Runs.list(@root)
      assert {:ok, %Projection{branch: "main"}} = Runs.projection(@root, run_id(1))
    end

    test "a run directory with events but no meta lists as interrupted" do
      events = Enum.take(RunsFixtures.passing_events(run_id(1)), 3)
      RunsFixtures.write_run(@root, run_id(1), events, meta: false)

      assert [%Projection{status: :interrupted, run_id: run_id}] = Runs.list(@root)
      assert run_id == run_id(1)
    end

    test "a corrupt meta.json falls back to folding the recording" do
      dir = write(1)
      File.write!(Path.join(dir, "meta.json"), "{\"status\": \"pass")

      assert [%Projection{status: :passed}] = Runs.list(@root)
    end

    test "a meta.json of the wrong shape falls back to the recording" do
      dir = write(1)
      File.write!(Path.join(dir, "meta.json"), ~s({"status": "passed", "stages": 5}))

      assert [%Projection{status: :passed, stages: [_]}] = Runs.list(@root)
    end

    test "one unreadable recording does not take the listing down" do
      write(2)
      unreadable = write(1, meta: false)
      events = Path.join(unreadable, "events.ndjson")
      File.chmod!(events, 0o000)
      on_exit(fn -> File.chmod(events, 0o644) end)

      # (As root the file stays readable; either way the listing must not raise.)
      assert run_id(2) in Enum.map(Runs.list(@root), & &1.run_id)
    end

    test "skips directories that hold no recording, and stray files" do
      write(2)
      File.mkdir_p!(Runs.dir(@root, run_id(3)))
      File.write!(Path.join(Runs.project_dir(@root), "stray.txt"), "x")

      assert [run_id(2)] == Enum.map(Runs.list(@root), & &1.run_id)
    end

    test "an empty recording still lists, named by its directory" do
      dir = Runs.dir(@root, run_id(1))
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "events.ndjson"), "")

      assert [%Projection{status: :interrupted, run_id: run_id}] = Runs.list(@root)
      assert run_id == run_id(1)
    end

    test "is empty for a project with no runs, and keeps projects apart" do
      assert Runs.list(@root) == []

      write(1)
      assert Runs.list("/work/other") == []
    end
  end

  describe "load/2" do
    test "streams decoded event maps in order" do
      write(1)

      assert {:ok, events} = Runs.load(@root, run_id(1))
      events = Enum.to_list(events)

      assert Enum.map(events, & &1["seq"]) == Enum.to_list(1..length(events))
      assert hd(events)["type"] == "run_started"
    end

    test "skips blank lines and a truncated final line" do
      dir = write(1, meta: false)
      path = Path.join(dir, "events.ndjson")
      File.write!(path, File.read!(path) <> "\n\n{\"seq\": 99, \"type\": \"step_outp")

      {:ok, events} = Runs.load(@root, run_id(1))
      events = Enum.to_list(events)

      assert length(events) == length(RunsFixtures.passing_events(run_id(1)))
      assert Enum.all?(events, &is_map/1)
    end

    test "is not_found for a missing run" do
      assert Runs.load(@root, "nope") == {:error, :not_found}
    end

    test "refuses anything that is not a bare directory name" do
      write(1)

      for bad <- ["", ".", "..", "../#{run_id(1)}", "a/b", "/etc/passwd", nil] do
        assert Runs.load(@root, bad) == {:error, :not_found}, "accepted #{inspect(bad)}"
      end
    end
  end

  describe "projection/2" do
    test "folds the recording" do
      write(1)

      assert {:ok, %Projection{status: :passed, run_id: run_id}} =
               Runs.projection(@root, run_id(1))

      assert run_id == run_id(1)
    end

    test "reports a recording with no run_finished as interrupted" do
      events = Enum.take(RunsFixtures.passing_events(run_id(1)), 3)
      RunsFixtures.write_run(@root, run_id(1), events, meta: false)

      assert {:ok, %Projection{status: :interrupted}} = Runs.projection(@root, run_id(1))
    end

    test "is not_found for a missing run" do
      assert Runs.projection(@root, "nope") == {:error, :not_found}
    end
  end

  describe "prune/2" do
    test "keeps the newest N runs and removes the rest" do
      Enum.each(1..5, &write/1)

      assert Runs.prune(@root, keep: 2) == %{removed: 3}
      assert [run_id(5), run_id(4)] == Enum.map(Runs.list(@root), & &1.run_id)
      refute File.exists?(Runs.dir(@root, run_id(1)))
    end

    test "keep: 0 removes every run" do
      Enum.each(1..3, &write/1)

      assert Runs.prune(@root, keep: 0) == %{removed: 3}
      assert Runs.list(@root) == []
    end

    test "removes nothing when there are fewer runs than the default keep of 200" do
      Enum.each(1..3, &write/1)
      assert Runs.prune(@root) == %{removed: 0}
      assert length(Runs.list(@root)) == 3
    end

    test "leaves stray files and other projects alone" do
      write(1)
      RunsFixtures.write_run("/work/other", run_id(1), RunsFixtures.passing_events(run_id(1)))
      stray = Path.join(Runs.project_dir(@root), "stray.txt")
      File.write!(stray, "x")

      assert Runs.prune(@root, keep: 0) == %{removed: 1}
      assert File.exists?(stray)
      assert [_] = Runs.list("/work/other")
    end

    test "is a no-op for a project with no runs" do
      assert Runs.prune(@root, keep: 0) == %{removed: 0}
    end

    test "rejects a keep that is not a non-negative integer" do
      for bad <- [-1, "2", nil, 1.5] do
        assert_raise ArgumentError, fn -> Runs.prune(@root, keep: bad) end
      end
    end
  end
end
