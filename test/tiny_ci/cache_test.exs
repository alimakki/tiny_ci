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
      assert key == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
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

  describe "compute_key/2" do
    @describetag :tmp_dir

    test "includes explicit execution inputs in the cache identity", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mix.lock")
      File.write!(path, "locked dependencies")

      inputs = %{
        command: "mix test",
        action: nil,
        runtime: %{elixir: "1.19", otp: "28", os: "linux"},
        matrix: %{target: "debug"},
        env: %{"MIX_ENV" => "test"},
        working_dir: "/project/app"
      }

      assert {:ok, key} = Cache.compute_key(path, inputs)
      assert key =~ ~r/^[0-9a-f]{64}$/

      for {field, value} <- [
            command: "mix compile",
            action: {"BuildAction", [mode: :release]},
            runtime: %{elixir: "1.20", otp: "29", os: "darwin"},
            matrix: %{target: "release"},
            env: %{"MIX_ENV" => "prod"},
            working_dir: "/project/other"
          ] do
        assert {:ok, changed_key} = Cache.compute_key(path, Map.put(inputs, field, value))
        refute changed_key == key, "changing #{field} must change the cache key"
      end
    end

    test "is deterministic regardless of nested map insertion order", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mix.lock")
      File.write!(path, "locked dependencies")
      pairs = Enum.map(1..40, fn i -> {"ENV_#{i}", "value_#{i}"} end)
      first = %{env: Map.new(pairs), matrix: %{os: "linux", arch: "arm64"}}
      second = %{matrix: Map.new(arch: "arm64", os: "linux"), env: Map.new(Enum.reverse(pairs))}

      assert {:ok, key} = Cache.compute_key(path, first)
      assert {:ok, ^key} = Cache.compute_key(path, second)
    end

    test "identical file contents and inputs give identical keys across file paths", %{
      tmp_dir: tmp
    } do
      first = Path.join(tmp, "a.lock")
      second = Path.join(tmp, "b.lock")
      File.write!(first, "same")
      File.write!(second, "same")

      assert {:ok, key} = Cache.compute_key(first, %{command: "build"})
      assert {:ok, ^key} = Cache.compute_key(second, %{command: "build"})
    end

    test "still includes the nominated file contents", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mix.lock")
      File.write!(path, "before")
      assert {:ok, before} = Cache.compute_key(path, %{command: "build"})
      File.write!(path, "after")
      assert {:ok, after_key} = Cache.compute_key(path, %{command: "build"})

      refute before == after_key
    end

    test "keeps file contents and inputs unambiguously separated", %{tmp_dir: tmp} do
      path = Path.join(tmp, "mix.lock")
      File.write!(path, "ab")
      assert {:ok, first} = Cache.compute_key(path, "c")
      File.write!(path, "a")
      assert {:ok, second} = Cache.compute_key(path, "bc")

      refute first == second
    end

    test "returns file read errors", %{tmp_dir: tmp} do
      assert {:error, :enoent} = Cache.compute_key(Path.join(tmp, "missing"), %{command: "build"})
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

    @tag :tmp_dir
    test "restore leaves the destination untouched when the entry became incomplete", %{
      tmp_dir: tmp
    } do
      source = Path.join(tmp, "source")
      destination = Path.join(tmp, "destination")
      File.mkdir_p!(source)
      File.mkdir_p!(destination)
      File.write!(Path.join(source, "deps"), "cached")
      File.write!(Path.join(source, "build"), "cached build")
      File.write!(Path.join(destination, "deps"), "original")
      Cache.save(tmp, "incomplete", ["deps", "build"], source)
      assert Cache.hit?(tmp, "incomplete", ["deps", "build"])
      File.rm!(Path.join(Cache.cache_entry_dir(tmp, "incomplete"), "build"))

      assert :ok = Cache.restore(tmp, "incomplete", ["deps", "build"], destination)
      assert File.read!(Path.join(destination, "deps")) == "original"
    end
  end

  describe "restore_if_present/4" do
    @describetag :tmp_dir

    test "returns a hit only after restoring and touching a complete entry", %{tmp_dir: root} do
      File.write!(Path.join(root, "output"), "cached")
      Cache.save(root, "complete", ["output"], nil)
      meta_path = Path.join(Cache.cache_entry_dir(root, "complete"), ".meta.json")
      meta = Jason.decode!(File.read!(meta_path))
      File.write!(meta_path, Jason.encode!(%{meta | "last_used_at" => "2020-01-01T00:00:00Z"}))
      File.write!(Path.join(root, "output"), "changed")

      assert :hit = Cache.restore_if_present(root, "complete", ["output"], nil)
      assert File.read!(Path.join(root, "output")) == "cached"
      assert Jason.decode!(File.read!(meta_path))["last_used_at"] != "2020-01-01T00:00:00Z"
    end

    test "returns a miss if an entry disappears after an earlier hit", %{tmp_dir: root} do
      File.write!(Path.join(root, "output"), "cached")
      Cache.save(root, "evicted", ["output"], nil)
      assert Cache.hit?(root, "evicted", ["output"])
      File.rm_rf!(Cache.cache_entry_dir(root, "evicted"))
      File.write!(Path.join(root, "output"), "original")

      assert :miss = Cache.restore_if_present(root, "evicted", ["output"], nil)
      assert File.read!(Path.join(root, "output")) == "original"
    end

    test "does not partially restore or touch an incomplete entry", %{tmp_dir: root} do
      File.write!(Path.join(root, "output"), "cached")
      Cache.save(root, "partial", ["output"], nil)
      meta_path = Path.join(Cache.cache_entry_dir(root, "partial"), ".meta.json")
      meta = File.read!(meta_path)
      File.write!(Path.join(root, "output"), "original")

      assert :miss = Cache.restore_if_present(root, "partial", ["output", "missing"], nil)
      assert File.read!(Path.join(root, "output")) == "original"
      assert File.read!(meta_path) == meta
    end

    test "an entry without metadata is a miss", %{tmp_dir: root} do
      entry = Cache.cache_entry_dir(root, "legacy")
      File.mkdir_p!(entry)
      File.write!(Path.join(entry, "output"), "cached")

      assert :miss = Cache.restore_if_present(root, "legacy", ["output"], nil)
      refute File.exists?(Path.join(root, "output"))
    end

    test "checks completeness after acquiring the entry lock", %{tmp_dir: root} do
      File.write!(Path.join(root, "output"), "cached")
      Cache.save(root, "locked", ["output"], nil)
      entry = Cache.cache_entry_dir(root, "locked")
      lock = Path.join([Path.dirname(entry), ".lock", "locked"])
      parent = self()
      destination = Path.join(root, "destination")

      holder =
        Task.async(fn ->
          TinyCI.Cache.Lock.with_lock(lock, fn ->
            send(parent, :held)

            receive do
              :evict -> File.rm_rf!(entry)
            end
          end)
        end)

      assert_receive :held

      restorer =
        Task.async(fn ->
          send(parent, :restoring)
          Cache.restore_if_present(root, "locked", ["output"], destination)
        end)

      on_exit(fn ->
        Process.exit(holder.pid, :kill)
        Process.exit(restorer.pid, :kill)
      end)

      assert_receive :restoring
      ref = restorer.ref
      refute_receive {^ref, _}, 50
      send(holder.pid, :evict)
      Task.await(holder)
      assert Task.await(restorer) == :miss
      refute File.exists?(destination)
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
