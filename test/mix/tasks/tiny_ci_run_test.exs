defmodule Mix.Tasks.TinyCi.RunTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @tmp_dir "test/tmp/mix_task"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    {:ok, project_root: @tmp_dir}
  end

  describe "run/1" do
    test "runs a passing pipeline and prints success", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :greet, mode: :serial do
        step :hello, cmd: "echo hello"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "runs a failing pipeline and returns error", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :fail, mode: :serial do
        step :boom, cmd: "exit 1"
      end
      """)

      stderr =
        capture_io(:stderr, fn ->
          _stdout =
            capture_io(fn ->
              result = Mix.Tasks.TinyCi.Run.run(["--file", path])
              assert result == {:error, :pipeline_failed}
            end)
        end)

      assert stderr =~ "Pipeline failed"
    end

    test "returns error when no pipeline file found" do
      stderr =
        capture_io(:stderr, fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", "/nonexistent/path/tiny_ci.exs"])
          assert result == {:error, :no_pipeline}
        end)

      assert stderr =~ "not found"
    end

    test "accepts --file flag to specify pipeline path", %{project_root: root} do
      path = Path.join(root, "custom_pipeline.exs")

      File.write!(path, """
      stage :custom, mode: :serial do
        step :echo, cmd: "echo custom"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "discovers pipeline from conventional location", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :found, mode: :serial do
        step :echo, cmd: "echo discovered"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "selects pipeline by positional name from .tiny_ci/", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      path = Path.join(dir, "ci.exs")

      File.write!(path, """
      stage :greet, mode: :serial do
        step :hello, cmd: "echo hello"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root, "ci"])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "selects nested pipeline by slash-separated name", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci/jobs")
      File.mkdir_p!(dir)
      path = Path.join(dir, "release.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :compile, cmd: "echo compiled"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root, "jobs/release"])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "returns error when named pipeline does not exist", %{project_root: root} do
      stderr =
        capture_io(:stderr, fn ->
          _stdout =
            capture_io(fn ->
              result = Mix.Tasks.TinyCi.Run.run(["--root", root, "nonexistent"])
              assert result == {:error, :no_pipeline}
            end)
        end)

      assert stderr =~ "nonexistent"
    end

    test "named pipeline works with --dry-run", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      path = Path.join(dir, "ci.exs")

      File.write!(path, """
      stage :test, mode: :serial do
        step :unit, cmd: "mix test"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root, "--dry-run", "ci"])
          assert result == :ok
        end)

      assert output =~ "Dry Run"
      refute output =~ "Pipeline completed successfully"
    end

    test "--list prints available pipelines", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "ci.exs"), "")
      File.write!(Path.join(dir, "deploy.exs"), "")

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root, "--list"])
          assert result == :ok
        end)

      assert output =~ "ci"
      assert output =~ "deploy"
    end

    test "--list shows message when no pipelines are available", %{project_root: root} do
      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root, "--list"])
          assert result == :ok
        end)

      assert output =~ "No pipelines"
    end

    test "dry-run shows plan without executing", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :test, mode: :parallel do
        step :unit, cmd: "mix test"
        step :lint, cmd: "mix credo"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--dry-run"])
          assert result == :ok
        end)

      assert output =~ "Dry Run"
      assert output =~ ":test"
      assert output =~ ":unit"
      assert output =~ ":lint"
      refute output =~ "Pipeline completed successfully"
      refute output =~ "Pipeline failed"
    end

    test "returns validation error for legacy defmodule format", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      defmodule MyPipeline do
        use TinyCI.DSL

        stage :test do
          step :unit, cmd: "mix test"
        end
      end
      """)

      stderr =
        capture_io(:stderr, fn ->
          _stdout =
            capture_io(fn ->
              result = Mix.Tasks.TinyCi.Run.run(["--file", path])
              assert result == {:error, :no_pipeline}
            end)
        end)

      assert stderr =~ "defmodule"
    end
  end
end
