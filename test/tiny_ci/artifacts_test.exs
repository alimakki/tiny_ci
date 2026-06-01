defmodule TinyCI.ArtifactsTest do
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
      assert run_id == "20240115_103000_abc1234"
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
