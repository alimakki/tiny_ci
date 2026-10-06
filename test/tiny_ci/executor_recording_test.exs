defmodule TinyCI.ExecutorRecordingTest do
  # async: false because the run store's location is application env, which every
  # test in the VM shares. (Kept apart from executor_test.exs, which is async.)
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TinyCI.{Executor, Runs, Stage, Step}
  alias TinyCI.Events.{CacheLookup, PipelineStarted}
  alias TinyCI.Runs.Projection
  alias TinyCI.RunsFixtures

  @moduletag :tmp_dir
  @silent [listener: TinyCI.Listener.Silent, output: :buffered]

  setup %{tmp_dir: tmp_dir} do
    store = Path.join(tmp_dir, "store")
    root = Path.join(tmp_dir, "project")
    File.mkdir_p!(root)
    RunsFixtures.redirect_runs_dir(store)
    {:ok, store: store, root: root}
  end

  defp passing_stage,
    do: %Stage{name: :build, mode: :serial, steps: [%Step{name: :hello, cmd: "echo hi"}]}

  defp failing_stage,
    do: %Stage{name: :build, mode: :serial, steps: [%Step{name: :bad, cmd: "echo nope; false"}]}

  defp context(root),
    do: %{store: %{}, root: root, branch: "feat", commit: "abc1234", base_ref: "main"}

  describe "run_pipeline/3 recording" do
    test "records a run whose context has a root", %{root: root} do
      assert {:ok, _} = Executor.run_pipeline([passing_stage()], context(root), @silent)

      assert [run] = Runs.list(root)

      assert %Projection{
               status: :passed,
               branch: "feat",
               commit: "abc1234",
               base_ref: "main",
               root: ^root,
               schema_version: 3
             } = run

      dir = Runs.dir(root, run.run_id)
      assert File.regular?(Path.join(dir, "events.ndjson"))
      assert File.regular?(Path.join(dir, "meta.json"))
    end

    test "records under the run id the run announced", %{root: root} do
      opts = @silent ++ [extra_sinks: [{TinyCI.TestSink, pid: self()}]]
      Executor.run_pipeline([passing_stage()], context(root), opts)

      assert_received {:event, %PipelineStarted{run_id: run_id}}
      assert [%Projection{run_id: ^run_id}] = Runs.list(root)
    end

    test "the recording folds to what the run did", %{root: root} do
      Executor.run_pipeline([passing_stage()], context(root), @silent)

      assert [%Projection{stages: [stage]}] = Runs.list(root)
      assert %{name: "build", status: :passed, steps: [%{name: "hello", output: "hi\n"}]} = stage
    end

    test "a failing run is recorded as failed", %{root: root} do
      assert {:error, _, _} = Executor.run_pipeline([failing_stage()], context(root), @silent)

      assert [%Projection{status: :failed, stages: [%{status: :failed, steps: [step]}]}] =
               Runs.list(root)

      assert step.output =~ "nope"
    end

    test "records when record: is nil, as the Mix task passes it", %{root: root} do
      Executor.run_pipeline([passing_stage()], context(root), @silent ++ [record: nil])
      assert [_] = Runs.list(root)
    end

    test "record: false writes nothing", %{root: root, store: store} do
      assert {:ok, _} =
               Executor.run_pipeline([passing_stage()], context(root), @silent ++ [record: false])

      assert Runs.list(root) == []
      refute File.exists?(store)
    end

    test "a context with no root writes nothing", %{store: store} do
      assert {:ok, _} = Executor.run_pipeline([passing_stage()], %{store: %{}}, @silent)
      refute File.exists?(store)
    end

    test "separate runs get separate recordings", %{root: root} do
      Executor.run_pipeline([passing_stage()], context(root), @silent)
      Executor.run_pipeline([failing_stage()], context(root), @silent)

      assert [:failed, :passed] |> Enum.sort() ==
               Runs.list(root) |> Enum.map(& &1.status) |> Enum.sort()

      assert length(Runs.list(root)) == 2
    end
  end

  describe "execute/4 on its own" do
    test "writes nothing, even when the context has a root", %{root: root, store: store} do
      assert %TinyCI.StageResult{status: :passed} =
               Executor.execute(
                 passing_stage(),
                 %{store: %{}, root: root},
                 :buffered,
                 TinyCI.Listener.Silent
               )

      refute File.exists?(store)
    end
  end

  describe "an invalid control spec" do
    test "raises without leaving a dispatcher or a recording behind", %{root: root} do
      links = Process.info(self(), :links)

      assert_raise ArgumentError, ~r/invalid control breakpoints/, fn ->
        Executor.run_pipeline(
          [passing_stage()],
          context(root),
          @silent ++ [control: [breakpoints: ["garbage"]]]
        )
      end

      assert Process.info(self(), :links) == links
      # Not just "lists nothing": an empty run directory would list as nothing too.
      assert File.ls(Runs.project_dir(root)) in [{:ok, []}, {:error, :enoent}]
    end
  end

  describe "cache lookups in a matrix stage" do
    test "carry the combination they ran in", %{root: root, tmp_dir: tmp_dir} do
      previous = Application.get_env(:tiny_ci, :cache_base_dir)
      Application.put_env(:tiny_ci, :cache_base_dir, Path.join(tmp_dir, "cache"))

      on_exit(fn ->
        if previous,
          do: Application.put_env(:tiny_ci, :cache_base_dir, previous),
          else: Application.delete_env(:tiny_ci, :cache_base_dir)
      end)

      File.write!(Path.join(root, "mix.lock"), "# lockfile")

      stage = %Stage{
        name: :compat,
        mode: :serial,
        matrix: [v: ["a", "b"]],
        steps: [
          %Step{name: :deps, cmd: "mkdir -p deps", cache: %{paths: ["deps"], key: "mix.lock"}}
        ]
      }

      opts = @silent ++ [record: false, extra_sinks: [{TinyCI.TestSink, pid: self()}]]
      assert {:ok, _} = Executor.run_pipeline([stage], context(root), opts)

      assert_received {:event, %CacheLookup{matrix_combination: [v: "a"]}}
      assert_received {:event, %CacheLookup{matrix_combination: [v: "b"]}}
    end
  end

  describe "a recorder that cannot write" do
    test "does not change the run's result", %{root: root, tmp_dir: tmp_dir} do
      blocker = Path.join(tmp_dir, "blocker")
      File.write!(blocker, "not a directory")
      Application.put_env(:tiny_ci, :runs_base_dir, Path.join(blocker, "runs"))

      log =
        capture_io(:stderr, fn ->
          assert {:ok, [%TinyCI.StageResult{status: :passed}]} =
                   Executor.run_pipeline([passing_stage()], context(root), @silent)

          assert {:error, {:stage_failed, :build, :failed}, _} =
                   Executor.run_pipeline([failing_stage()], context(root), @silent)
        end)

      assert log =~ "run recording disabled"
    end
  end
end
