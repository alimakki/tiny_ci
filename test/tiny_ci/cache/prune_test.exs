defmodule TinyCI.Cache.PruneTest do
  # async: false — points the cache at a temp dir through global application env.
  use ExUnit.Case, async: false

  alias TinyCI.Cache

  setup do
    tmp = System.tmp_dir!() |> Path.join("tiny_ci_prune_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    Application.put_env(:tiny_ci, :cache_base_dir, Path.join(tmp, "cache"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  # Builds a committed entry by hand with explicit metadata so tests control
  # `last_used_at` and `bytes` without touching the clock.
  defp put_entry(root, key, last_used_at, bytes) do
    dir = Cache.cache_entry_dir(root, key)
    File.mkdir_p!(Path.join(dir, "deps"))
    File.write!(Path.join(dir, "deps/payload"), String.duplicate("x", bytes))

    meta = %{
      "saved_at" => last_used_at,
      "last_used_at" => last_used_at,
      "paths" => ["deps"],
      "bytes" => bytes
    }

    File.write!(Path.join(dir, ".meta.json"), Jason.encode!(meta))
    dir
  end

  defp iso(days_ago) do
    DateTime.utc_now() |> DateTime.add(-days_ago * 86_400, :second) |> DateTime.to_iso8601()
  end

  describe "prune/1" do
    test "removes entries older than max_age_days", %{tmp: root} do
      old = put_entry(root, "old", iso(40), 10)
      fresh = put_entry(root, "fresh", iso(1), 10)

      assert %{removed: 1, bytes_freed: 10} = Cache.prune(max_age_days: 30)
      refute File.dir?(old)
      assert File.dir?(fresh)
    end

    test "removes least recently used entries until under max_bytes", %{tmp: root} do
      lru = put_entry(root, "lru", iso(3), 100)
      mid = put_entry(root, "mid", iso(2), 100)
      mru = put_entry(root, "mru", iso(1), 100)

      assert %{removed: 2, bytes_freed: 200} = Cache.prune(max_bytes: 150, max_age_days: 365)
      refute File.dir?(lru)
      refute File.dir?(mid)
      assert File.dir?(mru)
    end

    test "prunes across projects", %{tmp: tmp} do
      a = put_entry(Path.join(tmp, "a"), "k", iso(40), 5)
      b = put_entry(Path.join(tmp, "b"), "k", iso(40), 5)

      assert %{removed: 2} = Cache.prune(max_age_days: 30)
      refute File.dir?(a)
      refute File.dir?(b)
    end

    test "removes staging directories older than an hour", %{tmp: root} do
      tmp_dir = Path.join([Cache.base_dir(), Cache.project_id(root), ".tmp"])
      stale = Path.join(tmp_dir, "k-stale")
      recent = Path.join(tmp_dir, "k-recent")
      File.mkdir_p!(stale)
      File.mkdir_p!(recent)
      File.touch!(stale, System.os_time(:second) - 7200)

      Cache.prune([])
      refute File.dir?(stale)
      assert File.dir?(recent)
    end

    test "never removes an entry whose lock is held", %{tmp: root} do
      locked = put_entry(root, "locked", iso(40), 10)
      File.mkdir_p!(Path.join([Cache.base_dir(), Cache.project_id(root), ".lock", "locked"]))

      assert %{removed: 0} = Cache.prune(max_age_days: 30)
      assert File.dir?(locked)
    end
  end

  describe "stats/0" do
    test "counts entries, bytes, and projects", %{tmp: tmp} do
      put_entry(Path.join(tmp, "a"), "k1", iso(1), 10)
      put_entry(Path.join(tmp, "a"), "k2", iso(1), 20)
      put_entry(Path.join(tmp, "b"), "k1", iso(1), 5)

      assert Cache.stats() == %{entries: 3, bytes: 35, projects: 2}
    end

    test "is empty when the cache directory does not exist" do
      assert Cache.stats() == %{entries: 0, bytes: 0, projects: 0}
    end
  end
end
