defmodule Mix.Tasks.TinyCi.CacheTest do
  # async: false — points the cache at a temp dir through global application env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TinyCI.Cache

  setup do
    tmp = System.tmp_dir!() |> Path.join("tiny_ci_cache_task_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    Application.put_env(:tiny_ci, :cache_base_dir, Path.join(tmp, "cache"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  defp seed_entry(tmp, key) do
    work = Path.join(tmp, "work-#{key}")
    File.mkdir_p!(Path.join(work, "deps"))
    File.write!(Path.join(work, "deps/file"), "1234567890")
    Cache.save(tmp, key, ["deps"], work)
  end

  test "stats prints a one-line summary", %{tmp: tmp} do
    seed_entry(tmp, "k1")
    seed_entry(tmp, "k2")

    out = capture_io(fn -> Mix.Tasks.TinyCi.Cache.run(["stats"]) end)
    assert out =~ "2 entries"
    assert out =~ "1 project"
  end

  test "prune prints what it removed", %{tmp: tmp} do
    seed_entry(tmp, "k1")
    seed_entry(tmp, "k2")

    out = capture_io(fn -> Mix.Tasks.TinyCi.Cache.run(["prune", "--max-bytes", "0"]) end)
    assert out =~ "Removed 2 entries"
    assert Cache.stats().entries == 0
  end

  test "clean still removes the project's entries", %{tmp: tmp} do
    seed_entry(tmp, "k1")
    out = capture_io(fn -> Mix.Tasks.TinyCi.Cache.run(["clean", "--root", tmp]) end)
    assert out =~ "Cache cleared"
    assert Cache.stats().entries == 0
  end
end
