defmodule TinyCI.CLI.ActionsTest do
  # async: false because the tests capture stderr, which is one global device.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  alias TinyCI.CLI
  alias TinyCI.Registry.{Entry, Index}

  @moduletag :tmp_dir

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

  defp write_index(tmp) do
    path = Path.join(tmp, "index.json")

    entry = %Entry{
      package: :acme_actions,
      version: "2.1.0",
      module: Acme.Deploy,
      name: "acme.deploy",
      summary: "Ships a release.",
      capabilities: [:network],
      tier: :verified
    }

    File.write!(path, Index.to_json(Index.new([entry])))
    path
  end

  describe "tiny_ci actions search" do
    test "searches a generated index", %{tmp_dir: tmp} do
      index = write_index(tmp)

      assert {0, stdout, ""} = invoke(["actions", "search", "deploy", "--index", index])
      assert stdout =~ "acme.deploy"
      assert stdout =~ "verified"
    end

    test "reports when nothing matches (still 0)", %{tmp_dir: tmp} do
      index = write_index(tmp)

      assert {0, stdout, ""} = invoke(["actions", "search", "zzz", "--index", index])
      assert stdout =~ "No actions found"
      assert stdout =~ "`actions index`"
    end

    test "an unreadable index is a failure (1)", %{tmp_dir: tmp} do
      missing = Path.join(tmp, "nope.json")

      assert {1, "", stderr} = invoke(["actions", "search", "x", "--index", missing])
      assert stderr =~ "Search failed"
    end
  end

  describe "tiny_ci actions index" do
    test "writes an index", %{tmp_dir: tmp} do
      out = Path.join(tmp, "actions.json")

      assert {0, stdout, ""} = invoke(["actions", "index", "--out", out])
      assert stdout =~ "action(s) to #{out}"
      assert {:ok, _index} = Index.from_json(File.read!(out))
    end

    test "an unreadable overlay is a failure (1)", %{tmp_dir: tmp} do
      overlay = Path.join(tmp, "nope.json")
      out = Path.join(tmp, "actions.json")

      assert {1, "", stderr} = invoke(["actions", "index", "--out", out, "--overlay", overlay])
      assert stderr =~ "Index generation failed"
    end
  end

  describe "tiny_ci actions audit" do
    test "prints the resolved action tree", %{tmp_dir: tmp} do
      path = Path.join(tmp, "tiny_ci.exs")
      File.write!(path, "stage :build do\n  step :run, cmd: \"echo hi\"\nend\n")

      assert {0, stdout, ""} = invoke(["actions", "audit", "--file", path])
      assert stdout =~ "No module actions"
    end

    test "a missing pipeline file is a failure (1)", %{tmp_dir: tmp} do
      missing = Path.join(tmp, "nope.exs")

      assert {1, "", stderr} = invoke(["actions", "audit", "--file", missing])
      assert stderr =~ "not found" or stderr =~ "Error"
    end
  end

  test "an unknown or missing actions command is a usage error (2)" do
    for argv <- [["actions"], ["actions", "bogus"]] do
      assert {2, "", stderr} = invoke(argv)
      assert stderr =~ "audit"
      assert stderr =~ "index"
      assert stderr =~ "search"
    end
  end
end
