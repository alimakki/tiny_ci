defmodule TinyCI.CLI.RunsTest do
  # async: false because the run store's location is application env, and because
  # the tests capture stderr, which is one global device.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  alias TinyCI.CLI
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

  defp invoke(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:code, CLI.run(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:code, code}
    assert_received {:stdout, stdout}
    {code, stdout, stderr}
  end

  defp record_run(root) do
    assert {0, _stdout, ""} = invoke(["run", "--root", root])
    assert {0, json, ""} = invoke(["runs", "--root", root, "--output", "json"])
    [%{"run_id" => run_id}] = Jason.decode!(json)
    run_id
  end

  describe "tiny_ci runs" do
    test "says so when nothing has been recorded", %{root: root} do
      assert {0, stdout, ""} = invoke(["runs", "--root", root])
      assert stdout =~ "No runs recorded"
    end

    test "lists a run that `tiny_ci run` recorded", %{root: root} do
      run_id = record_run(root)

      assert {0, stdout, ""} = invoke(["runs", "--root", root])
      assert stdout =~ run_id
      assert stdout =~ "passed"
    end

    test "list is the default command, and also spelled out", %{root: root} do
      record_run(root)

      assert invoke(["runs", "--root", root]) == invoke(["runs", "list", "--root", root])
    end

    test "show prints one run", %{root: root} do
      run_id = record_run(root)

      assert {0, stdout, ""} = invoke(["runs", "show", run_id, "--root", root])
      assert stdout =~ "Run #{run_id}"
      assert stdout =~ "hello"
    end

    test "prune removes the oldest runs", %{root: root} do
      record_run(root)

      assert {0, stdout, ""} = invoke(["runs", "prune", "--keep", "0", "--root", root])
      assert stdout =~ "Removed 1 run"
    end

    test "show of an unknown run is a failure (1) with a message", %{root: root} do
      assert {1, "", stderr} = invoke(["runs", "show", "nope", "--root", root])
      assert stderr =~ ~s(Run "nope" not found)
    end

    test "bad usage exits 2", %{root: root} do
      for {argv, message} <- [
            {["runs", "show"], "Usage: runs show RUN_ID"},
            {["runs", "frobnicate"], "Unknown command: frobnicate"},
            {["runs", "--bogus"], "Invalid option: --bogus"},
            {["runs", "--limit", "0"], "--limit must be a positive integer"},
            {["runs", "--output", "xml"], "Unknown --output format"},
            {["runs", "prune", "--keep", "-1"], "--keep must be a non-negative integer"}
          ] do
        assert {2, "", stderr} = invoke(argv ++ ["--root", root])
        assert stderr =~ message
      end
    end
  end
end
