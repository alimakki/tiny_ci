defmodule TinyCI.CLI.CacheTest do
  # async: false — points the cache at a temp dir through global application env,
  # and captures stderr, which is one global device.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  alias TinyCI.CLI
  alias TinyCI.Cache

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env(:tiny_ci, :cache_base_dir)
    Application.put_env(:tiny_ci, :cache_base_dir, Path.join(tmp, "cache"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tiny_ci, :cache_base_dir, value)
        :error -> Application.delete_env(:tiny_ci, :cache_base_dir)
      end
    end)

    seed_entry(tmp, "k1")
    seed_entry(tmp, "k2")
    :ok
  end

  defp seed_entry(tmp, key) do
    work = Path.join(tmp, "work-#{key}")
    File.mkdir_p!(Path.join(work, "deps"))
    File.write!(Path.join(work, "deps/file"), "1234567890")
    Cache.save(tmp, key, ["deps"], work)
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

  test "stats prints a one-line summary" do
    assert {0, stdout, ""} = invoke(["cache", "stats"])
    assert stdout =~ "2 entries"
    assert stdout =~ "1 project"
  end

  test "prune prints what it removed" do
    assert {0, stdout, ""} = invoke(["cache", "prune", "--max-bytes", "0"])
    assert stdout =~ "Removed 2 entries"
    assert Cache.stats().entries == 0
  end

  test "clean removes the project's entries", %{tmp_dir: tmp} do
    assert {0, stdout, ""} = invoke(["cache", "clean", "--root", tmp])
    assert stdout =~ "Cache cleared"
    assert Cache.stats().entries == 0
  end

  test "an unknown or missing command is a usage error (2)" do
    for argv <- [["cache"], ["cache", "bogus"], ["cache", "stats", "extra"]] do
      assert {2, "", stderr} = invoke(argv)
      assert stderr =~ "Unknown or missing command"
      assert stderr =~ "Usage: cache clean"
    end
  end
end
