defmodule TinyCI.ArtifactsTest do
  # async: false because artifact storage is configured through application env.
  use ExUnit.Case, async: false

  alias TinyCI.Artifacts

  setup do
    tmp = System.tmp_dir!() |> Path.join("tiny_ci_artifacts_test_#{:rand.uniform(999_999)}")
    File.mkdir_p!(tmp)
    Application.put_env(:tiny_ci, :artifacts_base_dir, Path.join(tmp, "artifacts"))
    on_exit(fn -> File.rm_rf!(tmp) end)
    {:ok, tmp: tmp}
  end

  describe "project_id/1" do
    test "returns a 16-character hex string" do
      id = Artifacts.project_id("/some/path")
      assert byte_size(id) == 16
      assert String.match?(id, ~r/^[0-9a-f]+$/)
    end

    test "different roots produce different IDs" do
      assert Artifacts.project_id("/a") != Artifacts.project_id("/b")
    end

    test "same root always produces same ID" do
      assert Artifacts.project_id("/foo/bar") == Artifacts.project_id("/foo/bar")
    end
  end

  describe "generate_run_id/1" do
    test "returns a string with timestamp and commit components" do
      ctx = %{
        timestamp: ~U[2024-01-15 10:30:00Z],
        commit: "abc1234def567"
      }

      run_id = Artifacts.generate_run_id(ctx)
      assert run_id =~ ~r/^20240115_103000_abc1234_[0-9a-f]{32}$/
    end

    test "repeated calls with identical contexts have distinct IDs" do
      context = %{timestamp: ~U[2024-01-15 10:30:00Z], commit: "abc1234def567"}
      ids = Enum.map(1..100, fn _ -> Artifacts.generate_run_id(context) end)

      assert length(Enum.uniq(ids)) == 100
    end

    test "concurrent calls with identical contexts have distinct IDs" do
      context = %{timestamp: ~U[2024-01-15 10:30:00Z], commit: "abc1234def567"}

      ids =
        1..100
        |> Enum.map(fn _ -> Task.async(fn -> Artifacts.generate_run_id(context) end) end)
        |> Task.await_many()

      assert length(Enum.uniq(ids)) == 100
    end

    test "handles a nil commit" do
      run_id = Artifacts.generate_run_id(%{timestamp: ~U[2024-06-01 00:00:00Z], commit: nil})

      assert run_id =~ ~r/^20240601_000000_unknown_[0-9a-f]{32}$/
    end

    test "falls back gracefully when context keys are absent" do
      run_id = Artifacts.generate_run_id(%{timestamp: ~U[2024-06-01 00:00:00Z]})
      assert String.starts_with?(run_id, "20240601_000000_")
    end

    test "lexicographic order matches chronological order" do
      early = Artifacts.generate_run_id(%{timestamp: ~U[2024-01-01 00:00:00Z], commit: "aaa"})
      late = Artifacts.generate_run_id(%{timestamp: ~U[2024-12-31 23:59:59Z], commit: "bbb"})
      assert early < late
    end
  end

  describe "run_artifacts_dir/2" do
    test "returns path under base_dir / project_id / run_id", %{tmp: tmp} do
      root = tmp
      run_id = "20240115_103000_abc1234"
      dir = Artifacts.run_artifacts_dir(root, run_id)
      assert String.contains?(dir, run_id)
      assert String.starts_with?(dir, Artifacts.base_dir())
    end
  end

  describe "persist/3" do
    @describetag :tmp_dir

    test "copies a file to the artifact directory", %{tmp: tmp} do
      src_base = Path.join(tmp, "src")
      run_dir = Path.join(tmp, "run")
      File.mkdir_p!(src_base)
      File.write!(Path.join(src_base, "output.txt"), "result")

      artifact = %{name: "build", paths: ["output.txt"], required: false}

      assert {:ok, artifact_path} = Artifacts.persist(artifact, src_base, run_dir)
      assert File.exists?(Path.join(artifact_path, "output.txt"))
      assert File.read!(Path.join(artifact_path, "output.txt")) == "result"
    end

    test "copies a directory recursively", %{tmp: tmp} do
      src_base = Path.join(tmp, "src")
      run_dir = Path.join(tmp, "run")
      File.mkdir_p!(Path.join(src_base, "_build/prod"))
      File.write!(Path.join(src_base, "_build/prod/app"), "binary")

      artifact = %{name: "release", paths: ["_build"], required: false}

      assert {:ok, artifact_path} = Artifacts.persist(artifact, src_base, run_dir)
      assert File.exists?(Path.join(artifact_path, "_build/prod/app"))
    end

    test "returns warning for missing optional paths", %{tmp: tmp} do
      src_base = Path.join(tmp, "src")
      run_dir = Path.join(tmp, "run")
      File.mkdir_p!(src_base)

      artifact = %{name: "build", paths: ["missing.txt"], required: false}

      assert {:warning, _artifact_path, ["missing.txt"]} =
               Artifacts.persist(artifact, src_base, run_dir)
    end

    test "returns error for missing required paths", %{tmp: tmp} do
      src_base = Path.join(tmp, "src")
      run_dir = Path.join(tmp, "run")
      File.mkdir_p!(src_base)

      artifact = %{name: "build", paths: ["critical.bin"], required: true}

      assert {:error, {:missing_required, "build", ["critical.bin"]}} =
               Artifacts.persist(artifact, src_base, run_dir)
    end

    test "partial: copies found paths even when some are missing (optional)", %{tmp: tmp} do
      src_base = Path.join(tmp, "src")
      run_dir = Path.join(tmp, "run")
      File.mkdir_p!(src_base)
      File.write!(Path.join(src_base, "present.txt"), "here")

      artifact = %{name: "build", paths: ["present.txt", "absent.txt"], required: false}

      assert {:warning, artifact_path, ["absent.txt"]} =
               Artifacts.persist(artifact, src_base, run_dir)

      assert File.exists?(Path.join(artifact_path, "present.txt"))
    end

    test "copies found paths while reporting missing required paths", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src")
      run = Path.join(tmp, "run")
      File.mkdir_p!(src)
      File.write!(Path.join(src, "present"), "keep")

      artifact = %{name: "build", paths: ["present", "missing"], required: true}

      assert {:error, {:missing_required, "build", ["missing"]}} =
               Artifacts.persist(artifact, src, run)

      assert File.read!(Path.join(run, "build/present")) == "keep"
    end

    test "preserves conventional nested and dot-relative paths", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src")
      File.mkdir_p!(Path.join(src, "_build/prod"))
      File.write!(Path.join(src, "_build/prod/app"), "binary")
      artifact = %{name: "release/build", paths: ["./_build/prod"], required: true}

      assert {:ok, path} = Artifacts.persist(artifact, src, Path.join(tmp, "run"))
      assert File.read!(Path.join(path, "_build/prod/app")) == "binary"
    end

    for name <- ["../outside", "nested/../../outside", "/absolute", "", "."] do
      test "rejects unsafe artifact name #{inspect(name)}", %{tmp_dir: tmp} do
        name = unquote(name)
        src = Path.join(tmp, "src")
        run = Path.join(tmp, "run")
        File.mkdir_p!(src)
        File.write!(Path.join(src, "output"), "data")
        artifact = %{name: name, paths: ["output"], required: false}

        assert {:error, {:unsafe_path, ^name, ^name}} = Artifacts.persist(artifact, src, run)
        refute File.exists?(run)
        refute File.exists?(Path.join(tmp, "outside"))
      end
    end

    for path <- ["../secret", "nested/../../secret", "/etc/passwd"] do
      test "rejects unsafe declared path #{inspect(path)} before copying anything", %{
        tmp_dir: tmp
      } do
        path = unquote(path)
        src = Path.join(tmp, "src")
        run = Path.join(tmp, "run")
        File.mkdir_p!(Path.join(src, "nested"))
        File.write!(Path.join(src, "present"), "data")
        File.write!(Path.join(tmp, "secret"), "private")
        artifact = %{name: "build", paths: ["present", path], required: false}

        assert {:error, {:unsafe_path, "build", ^path}} = Artifacts.persist(artifact, src, run)
        refute File.exists?(run)
      end
    end

    for {link, target} <- [
          {"output", "../outside"},
          {"output", "../absent"},
          {"output/leak", "../../outside"}
        ] do
      test "rejects escaping source symlink #{link} -> #{target}", %{tmp_dir: tmp} do
        src = Path.join(tmp, "src")
        run = Path.join(tmp, "run")
        link = Path.join(src, unquote(link))
        File.mkdir_p!(Path.dirname(link))
        File.write!(Path.join(tmp, "outside"), "private")
        File.ln_s!(unquote(target), link)
        artifact = %{name: "build", paths: ["output"], required: true}

        assert {:error, {:unsafe_path, "build", "output"}} =
                 Artifacts.persist(artifact, src, run)

        refute File.exists?(run)
      end
    end

    test "rejects a source path through an escaping symlinked directory", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src")
      outside = Path.join(tmp, "src-other")
      File.mkdir_p!(src)
      File.mkdir_p!(outside)
      File.write!(Path.join(outside, "secret"), "private")
      File.ln_s!(outside, Path.join(src, "linked"))
      artifact = %{name: "build", paths: ["linked/secret"], required: false}

      assert {:error, {:unsafe_path, "build", "linked/secret"}} =
               Artifacts.persist(artifact, src, Path.join(tmp, "run"))
    end

    for link <- ["build", "build/output", "build/output/file"] do
      test "rejects escaping destination symlink #{link}", %{tmp_dir: tmp} do
        src = Path.join(tmp, "src")
        run = Path.join(tmp, "run")
        outside = Path.join(tmp, "run-other")
        File.mkdir_p!(Path.join(src, "output"))
        File.write!(Path.join(src, "output/file"), "replacement")
        File.mkdir_p!(outside)
        File.write!(Path.join(outside, "file"), "original")
        link = Path.join(run, unquote(link))
        File.mkdir_p!(Path.dirname(link))

        target =
          if unquote(link) == "build/output/file", do: Path.join(outside, "file"), else: outside

        File.ln_s!(target, link)
        artifact = %{name: "build", paths: ["output"], required: false}

        assert {:error, {:unsafe_path, "build", _path}} = Artifacts.persist(artifact, src, run)
        assert File.read!(Path.join(outside, "file")) == "original"
        assert File.ls!(outside) == ["file"]
      end
    end

    test "rejects a symlinked run directory", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src")
      run = Path.join(tmp, "run")
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(src)
      File.mkdir_p!(outside)
      File.write!(Path.join(src, "output"), "data")
      File.ln_s!(outside, run)
      artifact = %{name: "build", paths: ["output"], required: false}

      assert {:error, {:unsafe_path, "build", _path}} = Artifacts.persist(artifact, src, run)
      assert File.ls!(outside) == []
    end

    test "copies symlinks whose targets remain inside the source root", %{tmp_dir: tmp} do
      src = Path.join(tmp, "src")
      File.mkdir_p!(Path.join(src, "output"))
      File.mkdir_p!(Path.join(src, "target"))
      File.write!(Path.join(src, "target/file"), "data")
      File.ln_s!("../target", Path.join(src, "output/relative"))
      File.ln_s!(Path.join(src, "target/file"), Path.join(src, "output/absolute"))
      artifact = %{name: "build", paths: ["output"], required: true}

      assert {:ok, path} = Artifacts.persist(artifact, src, Path.join(tmp, "run"))
      assert File.read!(Path.join(path, "output/relative/file")) == "data"
      assert File.read!(Path.join(path, "output/absolute")) == "data"
    end

    test "reports symlink cycles without raising or publishing a partial artifact", %{
      tmp_dir: tmp
    } do
      src = Path.join(tmp, "src")
      run = Path.join(tmp, "run")
      File.mkdir_p!(Path.join(src, "output"))
      File.ln_s!(".", Path.join(src, "output/loop"))
      artifact = %{name: "build", paths: ["output"], required: false}

      assert {:error, {:unsafe_path, "build", "output"}} = Artifacts.persist(artifact, src, run)
      refute File.exists?(run)
    end
  end

  describe "list_runs/1" do
    test "returns empty list when no runs exist", %{tmp: tmp} do
      assert Artifacts.list_runs(tmp) == []
    end

    test "lists runs sorted oldest-first", %{tmp: tmp} do
      root = tmp
      pid = Artifacts.project_id(root)
      project_dir = Path.join([Artifacts.base_dir(), pid])

      for run_id <- ["20240101_000000_aaa", "20240201_000000_bbb", "20240301_000000_ccc"] do
        run_dir = Path.join(project_dir, run_id)
        File.mkdir_p!(Path.join(run_dir, "myartifact"))
      end

      runs = Artifacts.list_runs(root)
      run_ids = Enum.map(runs, fn {id, _} -> id end)
      assert run_ids == ["20240101_000000_aaa", "20240201_000000_bbb", "20240301_000000_ccc"]
    end

    test "lists artifact names within each run", %{tmp: tmp} do
      root = tmp
      pid = Artifacts.project_id(root)
      run_dir = Path.join([Artifacts.base_dir(), pid, "20240115_103000_abc1234"])
      File.mkdir_p!(Path.join(run_dir, "build"))
      File.mkdir_p!(Path.join(run_dir, "docs"))

      [{_run_id, artifact_names}] = Artifacts.list_runs(root)
      assert "build" in artifact_names
      assert "docs" in artifact_names
    end
  end
end
