defmodule TinyCI.DiscoveryTest do
  use ExUnit.Case, async: true

  alias TinyCI.{Discovery, PipelineSpec}

  @tmp_dir "test/tmp/discovery"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)

    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    {:ok, project_root: @tmp_dir}
  end

  describe "find_pipeline/1" do
    test "finds tiny_ci.exs in project root", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")
      File.write!(path, "stage :test do\n  step :unit, cmd: \"echo hi\"\nend")

      assert {:ok, ^path} = Discovery.find_pipeline(root)
    end

    test "finds .tiny_ci/pipeline.exs", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      path = Path.join(dir, "pipeline.exs")
      File.write!(path, "stage :test do\n  step :unit, cmd: \"echo hi\"\nend")

      assert {:ok, ^path} = Discovery.find_pipeline(root)
    end

    test "prefers tiny_ci.exs over .tiny_ci/pipeline.exs", %{project_root: root} do
      root_path = Path.join(root, "tiny_ci.exs")
      File.write!(root_path, "stage :test do\n  step :unit, cmd: \"echo hi\"\nend")

      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "pipeline.exs"),
        "stage :test do\n  step :unit, cmd: \"echo hi\"\nend"
      )

      assert {:ok, ^root_path} = Discovery.find_pipeline(root)
    end

    test "returns error when no pipeline file exists", %{project_root: root} do
      assert {:error, :not_found} = Discovery.find_pipeline(root)
    end
  end

  describe "find_pipeline_by_name/2" do
    test "finds .tiny_ci/<name>.exs by name", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      path = Path.expand(Path.join(dir, "deploy.exs"))
      File.write!(path, "")

      assert {:ok, ^path} = Discovery.find_pipeline_by_name(root, "deploy")
    end

    test "finds nested .tiny_ci/<sub>/<name>.exs by slash-separated name", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci/jobs")
      File.mkdir_p!(dir)
      path = Path.expand(Path.join(dir, "release.exs"))
      File.write!(path, "")

      assert {:ok, ^path} = Discovery.find_pipeline_by_name(root, "jobs/release")
    end

    test "returns error when named pipeline file does not exist", %{project_root: root} do
      assert {:error, :not_found} = Discovery.find_pipeline_by_name(root, "nonexistent")
    end

    test "prevents path traversal via .. segments", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)

      # Create a file outside .tiny_ci/ that the traversal would hit
      outside = Path.join(root, "secret.exs")
      File.write!(outside, "")

      assert {:error, :not_found} = Discovery.find_pipeline_by_name(root, "../secret")
    end
  end

  describe "list_pipelines/1" do
    test "returns empty list when .tiny_ci/ does not exist", %{project_root: root} do
      assert [] = Discovery.list_pipelines(root)
    end

    test "returns empty list when .tiny_ci/ is empty", %{project_root: root} do
      File.mkdir_p!(Path.join(root, ".tiny_ci"))
      assert [] = Discovery.list_pipelines(root)
    end

    test "lists a single pipeline by name", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      path = Path.join(dir, "ci.exs")
      File.write!(path, "")

      assert [{"ci", ^path}] = Discovery.list_pipelines(root)
    end

    test "lists multiple pipelines sorted alphabetically by name", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      path_ci = Path.join(dir, "ci.exs")
      path_deploy = Path.join(dir, "deploy.exs")
      path_pipeline = Path.join(dir, "pipeline.exs")
      File.write!(path_ci, "")
      File.write!(path_deploy, "")
      File.write!(path_pipeline, "")

      assert [{"ci", ^path_ci}, {"deploy", ^path_deploy}, {"pipeline", ^path_pipeline}] =
               Discovery.list_pipelines(root)
    end

    test "lists nested pipelines with slash-separated names", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(Path.join(dir, "jobs"))
      path_top = Path.join(dir, "ci.exs")
      path_nested = Path.join(dir, "jobs/release.exs")
      File.write!(path_top, "")
      File.write!(path_nested, "")

      assert [{"ci", ^path_top}, {"jobs/release", ^path_nested}] =
               Discovery.list_pipelines(root)
    end

    test "excludes non-.exs files", %{project_root: root} do
      dir = Path.join(root, ".tiny_ci")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "pipeline.exs"), "")
      File.write!(Path.join(dir, "README.md"), "")
      File.write!(Path.join(dir, "notes.txt"), "")

      assert [{"pipeline", _}] = Discovery.list_pipelines(root)
    end
  end

  describe "load_pipeline/1" do
    test "interprets a new-format pipeline file and returns PipelineSpec", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      name :test_pipeline

      stage :test, mode: :serial do
        step :hello, cmd: "echo hello"
      end
      """)

      assert {:ok, %PipelineSpec{name: :test_pipeline, stages: [stage]}} =
               Discovery.load_pipeline(path)

      assert stage.name == :test
      assert [%{name: :hello}] = stage.steps
    end

    test "returns error for non-existent file" do
      assert {:error, :file_not_found} = Discovery.load_pipeline("/nonexistent/tiny_ci.exs")
    end

    test "returns error for file with syntax errors", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")
      File.write!(path, "stage :test do end end")

      assert {:error, {:parse_error, _}} = Discovery.load_pipeline(path)
    end

    test "returns validation error for disallowed constructs", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      defmodule BadPipeline do
        stage :test do
          step :unit, cmd: "mix test"
        end
      end
      """)

      assert {:error, {:validation_error, msgs}} = Discovery.load_pipeline(path)
      assert Enum.any?(msgs, &(&1 =~ "defmodule"))
    end

    test "derives pipeline name from filename when no name directive", %{project_root: root} do
      path = Path.join(root, "deploy.exs")

      File.write!(path, """
      stage :release, mode: :serial do
        step :build, cmd: "make build"
      end
      """)

      assert {:ok, %PipelineSpec{name: :deploy}} = Discovery.load_pipeline(path)
    end
  end
end
