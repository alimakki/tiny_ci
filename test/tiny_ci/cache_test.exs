defmodule TinyCI.CacheTest do
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
      entry_dir = Cache.cache_entry_dir(root, key)
      File.mkdir_p!(Path.join(entry_dir, "deps"))
      File.write!(Path.join(entry_dir, "_build"), "data")

      assert Cache.hit?(root, key, ["deps", "_build"]) == true
    end

    test "returns false when only some paths are cached", %{tmp: tmp} do
      root = tmp
      key = "partial"
      entry_dir = Cache.cache_entry_dir(root, key)
      File.mkdir_p!(Path.join(entry_dir, "deps"))

      assert Cache.hit?(root, key, ["deps", "_build"]) == false
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
