defmodule TinyCI.CacheTest do
  # async: false — points the cache at a temp dir through global application env.
  use ExUnit.Case, async: false

  alias TinyCI.Cache

  setup do
    tmp = System.tmp_dir!() |> Path.join("tiny_ci_cache_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    Application.put_env(:tiny_ci, :cache_base_dir, Path.join(tmp, "cache"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "compute_key/1" do
    test "returns sha256 hex of file contents", %{tmp: tmp} do
      path = Path.join(tmp, "mix.lock")
      File.write!(path, "hello")
      {:ok, key} = Cache.compute_key(path)
      assert byte_size(key) == 64
      assert String.match?(key, ~r/^[0-9a-f]+$/)
    end

    test "same contents produce same key", %{tmp: tmp} do
      p1 = Path.join(tmp, "a.lock")
      p2 = Path.join(tmp, "b.lock")
      File.write!(p1, "contents")
      File.write!(p2, "contents")
      {:ok, k1} = Cache.compute_key(p1)
      {:ok, k2} = Cache.compute_key(p2)
      assert k1 == k2
    end

    test "different contents produce different keys", %{tmp: tmp} do
      p1 = Path.join(tmp, "a.lock")
      p2 = Path.join(tmp, "b.lock")
      File.write!(p1, "aaa")
      File.write!(p2, "bbb")
      {:ok, k1} = Cache.compute_key(p1)
      {:ok, k2} = Cache.compute_key(p2)
      assert k1 != k2
    end

    test "returns error for missing file" do
      assert {:error, _} = Cache.compute_key("/nonexistent/file.lock")
    end
  end

  describe "hit?/3" do
    test "returns false when cache entry does not exist", %{tmp: tmp} do
      assert Cache.hit?(tmp, "nonexistentkey", ["deps"]) == false
    end

    test "returns true when all paths exist in cache", %{tmp: tmp} do
      root = tmp
      key = "abc123"
      work = Path.join(tmp, "work")
      File.mkdir_p!(Path.join(work, "deps"))
      File.write!(Path.join(work, "_build"), "data")
      Cache.save(root, key, ["deps", "_build"], work)

      assert Cache.hit?(root, key, ["deps", "_build"]) == true
    end

    test "returns false when only some paths are cached", %{tmp: tmp} do
      root = tmp
      key = "partial"
      work = Path.join(tmp, "work")
      File.mkdir_p!(Path.join(work, "deps"))
      Cache.save(root, key, ["deps"], work)

      assert Cache.hit?(root, key, ["deps", "_build"]) == false
    end

    test "an entry without metadata is a miss", %{tmp: tmp} do
      root = tmp
      key = "legacy"
      entry_dir = Cache.cache_entry_dir(root, key)
      File.mkdir_p!(Path.join(entry_dir, "deps"))

      assert Cache.hit?(root, key, ["deps"]) == false
    end
  end

  describe "atomicity" do
    defp write_tree(base, files) do
      Enum.each(files, fn {rel, content} ->
        path = Path.join(base, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end)

      base
    end

    defp tmp_entries(root) do
      dir = Path.join([Cache.base_dir(), Cache.project_id(root), ".tmp"])
      if File.dir?(dir), do: File.ls!(dir), else: []
    end

    test "save publishes atomically with metadata", %{tmp: tmp} do
      root = tmp
      work = write_tree(Path.join(tmp, "work"), %{"deps/a.ex" => "a", "out.txt" => "o"})

      assert :ok = Cache.save(root, "k1", ["deps", "out.txt", "missing"], work)

      meta = Path.join(Cache.cache_entry_dir(root, "k1"), ".meta.json")
      assert File.exists?(meta)
      decoded = Jason.decode!(File.read!(meta))
      assert decoded["paths"] == ["deps", "out.txt"]
      assert is_integer(decoded["bytes"]) and decoded["bytes"] > 0
      assert {:ok, _, _} = DateTime.from_iso8601(decoded["saved_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(decoded["last_used_at"])
      assert tmp_entries(root) == []
    end

    test "an interrupted save is invisible", %{tmp: tmp} do
      root = tmp
      work = write_tree(Path.join(tmp, "work"), %{"deps/a.ex" => "a"})

      stage = Cache.stage_entry(root, "k2", ["deps"], work)
      assert File.exists?(Path.join(stage, "deps/a.ex"))
      refute Cache.hit?(root, "k2", ["deps"])

      assert :ok = Cache.commit_entry(root, "k2", stage)
      assert Cache.hit?(root, "k2", ["deps"])
      assert tmp_entries(root) == []
    end

    test "a second save replaces the entry wholesale", %{tmp: tmp} do
      root = tmp
      first = write_tree(Path.join(tmp, "w1"), %{"deps/one.ex" => "1"})
      second = write_tree(Path.join(tmp, "w2"), %{"deps/two.ex" => "2"})

      Cache.save(root, "k3", ["deps"], first)
      Cache.save(root, "k3", ["deps"], second)

      entry = Cache.cache_entry_dir(root, "k3")
      assert File.exists?(Path.join(entry, "deps/two.ex"))
      refute File.exists?(Path.join(entry, "deps/one.ex"))
      assert tmp_entries(root) == []
    end

    test "concurrent saves of one key leave one consistent entry", %{tmp: tmp} do
      root = tmp

      works =
        for i <- 1..4 do
          write_tree(Path.join(tmp, "w#{i}"), %{
            "deps/shared.ex" => "from #{i}",
            "deps/marker-#{i}" => "#{i}"
          })
        end

      works
      |> Enum.map(fn work -> Task.async(fn -> Cache.save(root, "k4", ["deps"], work) end) end)
      |> Task.await_many(30_000)

      entry = Path.join(Cache.cache_entry_dir(root, "k4"), "deps")
      markers = entry |> File.ls!() |> Enum.filter(&String.starts_with?(&1, "marker-"))
      assert [<<"marker-", i::binary>>] = markers
      assert File.read!(Path.join(entry, "shared.ex")) == "from #{i}"
      assert Cache.hit?(root, "k4", ["deps"])
      assert tmp_entries(root) == []
    end

    test "restore touches last_used_at", %{tmp: tmp} do
      root = tmp
      work = write_tree(Path.join(tmp, "work"), %{"deps/a.ex" => "a"})
      Cache.save(root, "k5", ["deps"], work)

      meta_path = Path.join(Cache.cache_entry_dir(root, "k5"), ".meta.json")
      old = Jason.decode!(File.read!(meta_path))
      File.write!(meta_path, Jason.encode!(%{old | "last_used_at" => "2020-01-01T00:00:00Z"}))

      Cache.restore(root, "k5", ["deps"], Path.join(tmp, "restored"))

      touched = Jason.decode!(File.read!(meta_path))
      assert touched["saved_at"] == old["saved_at"]
      assert touched["last_used_at"] != "2020-01-01T00:00:00Z"
      assert File.read!(Path.join(tmp, "restored/deps/a.ex")) == "a"
    end
  end

  describe "save/4 and restore/4" do
    test "saves a directory and restores it to a new location", %{tmp: tmp} do
      root = tmp
      key = "savekey"
      working_dir = Path.join(tmp, "project")
      restore_dir = Path.join(tmp, "restored")
      File.mkdir_p!(working_dir)
      File.mkdir_p!(restore_dir)

      File.mkdir_p!(Path.join(working_dir, "deps/my_dep"))
      File.write!(Path.join(working_dir, "deps/my_dep/module.ex"), "defmodule Foo do end")

      Cache.save(root, key, ["deps"], working_dir)
      assert Cache.hit?(root, key, ["deps"])

      Cache.restore(root, key, ["deps"], restore_dir)

      assert File.exists?(Path.join(restore_dir, "deps/my_dep/module.ex"))

      assert File.read!(Path.join(restore_dir, "deps/my_dep/module.ex")) ==
               "defmodule Foo do end"
    end

    test "saves a file (not directory) correctly", %{tmp: tmp} do
      root = tmp
      key = "filekey"
      working_dir = Path.join(tmp, "work")
      restore_dir = Path.join(tmp, "restore")
      File.mkdir_p!(working_dir)
      File.mkdir_p!(restore_dir)
      File.write!(Path.join(working_dir, "output.txt"), "result")

      Cache.save(root, key, ["output.txt"], working_dir)
      Cache.restore(root, key, ["output.txt"], restore_dir)

      assert File.read!(Path.join(restore_dir, "output.txt")) == "result"
    end

    test "skips paths that do not exist in working_dir", %{tmp: tmp} do
      root = tmp
      key = "skipkey"
      working_dir = Path.join(tmp, "empty_work")
      File.mkdir_p!(working_dir)

      assert :ok = Cache.save(root, key, ["nonexistent"], working_dir)
    end

    test "restore replaces existing destination", %{tmp: tmp} do
      root = tmp
      key = "replacekey"
      src_dir = Path.join(tmp, "src")
      dst_dir = Path.join(tmp, "dst")
      File.mkdir_p!(src_dir)
      File.mkdir_p!(dst_dir)

      File.mkdir_p!(Path.join(src_dir, "deps"))
      File.write!(Path.join(src_dir, "deps/new.ex"), "new")
      File.write!(Path.join(dst_dir, "deps"), "old_file_not_dir")

      Cache.save(root, key, ["deps"], src_dir)
      Cache.restore(root, key, ["deps"], dst_dir)

      assert File.read!(Path.join(dst_dir, "deps/new.ex")) == "new"
    end
  end

  describe "clean/1" do
    test "removes all cache entries for the project", %{tmp: tmp} do
      root = tmp
      entry_dir = Cache.cache_entry_dir(root, "somekey")
      File.mkdir_p!(entry_dir)
      File.write!(Path.join(entry_dir, "marker"), "x")

      assert File.dir?(entry_dir)
      Cache.clean(root)
      refute File.dir?(Path.join(Cache.base_dir(), Cache.project_id(root)))
    end

    test "is a no-op when no cache exists", %{tmp: tmp} do
      assert :ok = Cache.clean(tmp)
    end
  end

  describe "project_id/1" do
    test "returns a 16-character hex string" do
      id = Cache.project_id("/some/path")
      assert byte_size(id) == 16
      assert String.match?(id, ~r/^[0-9a-f]+$/)
    end

    test "different roots produce different IDs" do
      assert Cache.project_id("/a") != Cache.project_id("/b")
    end
  end
end
