defmodule RunTaskLocalAction do
  @moduledoc false
  def execute(_config, _ctx), do: {:ok, %{ran: true}}
end

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

    test "supply-chain verification allows a first-party/local module action",
         %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :run, module: RunTaskLocalAction
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

    test "resolves working_dir relative to the project root, not the pipeline file's dir",
         %{project_root: root} do
      # Regression: a pipeline in `.tiny_ci/` must resolve relative paths against
      # the project root, not `.tiny_ci/`. A `working_dir` that exists under root
      # (but not under `.tiny_ci/`) proves the anchor.
      File.mkdir_p!(Path.join(root, ".tiny_ci"))
      File.mkdir_p!(Path.join(root, "subproject"))

      File.write!(Path.join(root, ".tiny_ci/wd.exs"), """
      stage :wd, mode: :serial do
        step :pwd, cmd: "pwd", working_dir: "subproject"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--root", root, "wd"])
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

    test "--filter runs only the specified stage", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :compile, cmd: "echo compiled"
      end
      stage :test, mode: :serial do
        step :unit, cmd: "echo tested"
      end
      stage :deploy, mode: :serial do
        step :release, cmd: "exit 1"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--filter", ":test"])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
      assert output =~ "test"
      refute output =~ "deploy"
    end

    test "--filter with multiple stages runs only listed stages", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :compile, cmd: "echo compiled"
      end
      stage :test, mode: :serial do
        step :unit, cmd: "echo tested"
      end
      stage :deploy, mode: :serial do
        step :release, cmd: "exit 1"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--filter", ":build,:test"])
          assert result == :ok
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "--filter with unknown stage name prints error and returns error", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :compile, cmd: "echo compiled"
      end
      """)

      stderr =
        capture_io(:stderr, fn ->
          _stdout =
            capture_io(fn ->
              result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--filter", ":nonexistent"])
              assert result == {:error, :no_pipeline}
            end)
        end)

      assert stderr =~ "nonexistent"
      assert stderr =~ "build"
    end

    test "--dry-run --filter shows only filtered stages", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :compile, cmd: "echo compiled"
      end
      stage :test, mode: :serial do
        step :unit, cmd: "echo tested"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--dry-run", "--filter", ":test"])
          assert result == :ok
        end)

      assert output =~ "Dry Run"
      assert output =~ ":test"
      refute output =~ ":build"
    end

    test "--output json produces valid JSON with status field", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :test, mode: :serial do
        step :unit, cmd: "echo hello"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--output", "json"])
          assert result == :ok
        end)

      assert {:ok, json} = Jason.decode(output)
      assert json["status"] == "passed"
      assert is_list(json["stages"])
      assert is_integer(json["duration_ms"])
    end

    test "--output json suppresses human-readable output", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :test, mode: :serial do
        step :unit, cmd: "echo hello"
      end
      """)

      output =
        capture_io(fn ->
          Mix.Tasks.TinyCi.Run.run(["--file", path, "--output", "json"])
        end)

      refute output =~ "Pipeline completed successfully"
      refute output =~ "Stage:"
      refute output =~ "Found pipeline"
    end

    test "--output json on failed pipeline has status failed and returns error", %{
      project_root: root
    } do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :test, mode: :serial do
        step :fail, cmd: "exit 1"
      end
      """)

      output =
        capture_io(fn ->
          result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--output", "json"])
          assert result == {:error, :pipeline_failed}
        end)

      assert {:ok, json} = Jason.decode(output)
      assert json["status"] == "failed"
    end

    test "--output json includes stage details", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :build, mode: :serial do
        step :compile, cmd: "echo compiled"
      end
      """)

      output =
        capture_io(fn ->
          Mix.Tasks.TinyCi.Run.run(["--file", path, "--output", "json"])
        end)

      {:ok, json} = Jason.decode(output)
      stage = hd(json["stages"])
      assert stage["name"] == "build"
      assert stage["status"] == "passed"
      assert hd(stage["steps"])["name"] == "compile"
    end

    test "unknown --output value prints error and returns error", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :test, mode: :serial do
        step :unit, cmd: "echo hello"
      end
      """)

      stderr =
        capture_io(:stderr, fn ->
          _stdout =
            capture_io(fn ->
              result = Mix.Tasks.TinyCi.Run.run(["--file", path, "--output", "xml"])
              assert result == {:error, :no_pipeline}
            end)
        end)

      assert stderr =~ "xml"
      assert stderr =~ "json"
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

  describe "--events" do
    test "writes a valid NDJSON event stream to a file", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")
      events_path = Path.join(root, "run.ndjson")

      File.write!(path, """
      stage :greet, mode: :serial do
        step :hello, cmd: "echo hello"
      end
      """)

      capture_io(fn ->
        assert :ok = Mix.Tasks.TinyCi.Run.run(["--file", path, "--events", events_path])
      end)

      lines = events_path |> File.read!() |> String.split("\n", trim: true)
      decoded = Enum.map(lines, &Jason.decode!/1)

      # Every line is valid JSON carrying the envelope fields.
      Enum.each(decoded, fn event ->
        assert is_integer(event["seq"])
        assert is_binary(event["type"])
        assert is_binary(event["run_id"])
        assert is_binary(event["ts"])
      end)

      types = Enum.map(decoded, & &1["type"])
      assert "run_started" in types
      assert "run_finished" in types
      assert "stage_started" in types
      assert "step_finished" in types

      # seq is monotonic across the stream.
      seqs = Enum.map(decoded, & &1["seq"])
      assert seqs == Enum.sort(seqs)
      assert Enum.uniq(seqs) == seqs

      # schema_version rides only on the run_started line.
      run_started = Enum.find(decoded, &(&1["type"] == "run_started"))
      assert run_started["schema_version"] == TinyCI.Events.schema_version()
    end

    test "writes the event stream to stdout with -", %{project_root: root} do
      path = Path.join(root, "tiny_ci.exs")

      File.write!(path, """
      stage :greet, mode: :serial do
        step :hello, cmd: "echo hello"
      end
      """)

      output =
        capture_io(fn ->
          assert :ok = Mix.Tasks.TinyCi.Run.run(["--file", path, "--events", "-"])
        end)

      ndjson_lines =
        output
        |> String.split("\n", trim: true)
        |> Enum.filter(&match?({:ok, %{"type" => _}}, Jason.decode(&1)))
        |> Enum.map(&Jason.decode!/1)

      types = Enum.map(ndjson_lines, & &1["type"])
      assert "run_started" in types
      assert "run_finished" in types
    end
  end

  describe "--break" do
    # The test suite runs without a TTY, so no interactive driver is attached and
    # `--break-timeout` is mandatory. That is the guard, exercised for real.
    defp pipeline(root, body) do
      path = Path.join(root, "tiny_ci.exs")
      File.write!(path, body)
      path
    end

    defp two_stage_pipeline(root) do
      pipeline(root, """
      stage :test, mode: :serial do
        step :unit, cmd: "true"
      end

      stage :deploy, mode: :serial do
        step :push, cmd: "true"
      end
      """)
    end

    test "refuses to arm with nothing able to answer the prompt", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :no_pipeline} =
                     Mix.Tasks.TinyCi.Run.run(["--file", path, "--break", "before:deploy"])
          end)
        end)

      assert stderr =~ "Refusing to arm --break with nothing to release it"
      assert stderr =~ "--break-timeout MS"
    end

    test "rejects an unparsable spec before running anything", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :no_pipeline} =
                     Mix.Tasks.TinyCi.Run.run(["--file", path, "--break", "during:deploy"])
          end)
        end)

      assert stderr =~ "Invalid --break"
      assert stderr =~ ~s(unknown breakpoint phase "during")
    end

    test "rejects an unknown stage and lists the real ones", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :no_pipeline} =
                     Mix.Tasks.TinyCi.Run.run(["--file", path, "--break", "before:nope"])
          end)
        end)

      assert stderr =~ "unknown stage :nope"
      assert stderr =~ "Available stages: :test, :deploy"
    end

    test "rejects an unknown step and lists that stage's steps", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :no_pipeline} =
                     Mix.Tasks.TinyCi.Run.run(["--file", path, "--break", "after:test.nope"])
          end)
        end)

      assert stderr =~ "unknown step :nope in stage :test"
      assert stderr =~ "Available steps: :unit"
    end

    test "reports every bad spec at once", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            Mix.Tasks.TinyCi.Run.run([
              "--file",
              path,
              "--break",
              "during:deploy",
              "--break",
              "sideways:test"
            ])
          end)
        end)

      assert stderr =~ ~s("during")
      assert stderr =~ ~s("sideways")
    end

    test "rejects an unknown --break-timeout-action", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :no_pipeline} =
                     Mix.Tasks.TinyCi.Run.run([
                       "--file",
                       path,
                       "--break",
                       "before:deploy",
                       "--break-timeout-action",
                       "sideways"
                     ])
          end)
        end)

      assert stderr =~ "Unknown --break-timeout-action"
      assert stderr =~ "abort, continue"
    end

    test "rejects a non-positive --break-timeout", %{project_root: root} do
      path = two_stage_pipeline(root)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :no_pipeline} =
                     Mix.Tasks.TinyCi.Run.run([
                       "--file",
                       path,
                       "--break",
                       "before:deploy",
                       "--break-timeout",
                       "0"
                     ])
          end)
        end)

      assert stderr =~ "Invalid --break-timeout"
    end

    test "a headless breakpoint times out and aborts the run", %{project_root: root} do
      path = two_stage_pipeline(root)
      events_path = Path.join(root, "run.ndjson")

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :pipeline_failed} =
                     Mix.Tasks.TinyCi.Run.run([
                       "--file",
                       path,
                       "--break",
                       "before:deploy",
                       "--break-timeout",
                       "50",
                       "--events",
                       events_path
                     ])
          end)
        end)

      assert stderr =~ "Pipeline aborted by execution control at stage :deploy"

      events =
        events_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!/1)

      hit = Enum.find(events, &(&1["type"] == "breakpoint_hit"))
      assert hit["breakpoint"] == "before:deploy"
      assert hit["phase"] == "before"
      assert hit["scope"] == "stage"
      assert hit["stage"] == "deploy"

      resumed = Enum.find(events, &(&1["type"] == "breakpoint_resumed"))
      assert resumed["command"] == "abort"
      assert resumed["timed_out"] == true

      # The abort surfaces as its own status, not as a test failure.
      assert Enum.find(events, &(&1["type"] == "run_finished"))["status"] == "aborted"
    end

    test "--break-timeout-action continue lets the run finish", %{project_root: root} do
      path = two_stage_pipeline(root)

      output =
        capture_io(fn ->
          assert :ok =
                   Mix.Tasks.TinyCi.Run.run([
                     "--file",
                     path,
                     "--break",
                     "before:deploy",
                     "--break-timeout",
                     "50",
                     "--break-timeout-action",
                     "continue"
                   ])
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "--debug-serial is accepted alongside --break", %{project_root: root} do
      path = two_stage_pipeline(root)

      output =
        capture_io(fn ->
          assert :ok =
                   Mix.Tasks.TinyCi.Run.run([
                     "--file",
                     path,
                     "--break",
                     "after:test.unit",
                     "--break-timeout",
                     "50",
                     "--break-timeout-action",
                     "continue",
                     "--debug-serial"
                   ])
        end)

      assert output =~ "Pipeline completed successfully"
    end

    test "a run without --break arms nothing and emits no control events",
         %{project_root: root} do
      path = two_stage_pipeline(root)
      events_path = Path.join(root, "run.ndjson")

      capture_io(fn ->
        assert :ok = Mix.Tasks.TinyCi.Run.run(["--file", path, "--events", events_path])
      end)

      types =
        events_path
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!(&1)["type"])

      refute "breakpoint_hit" in types
      refute "breakpoint_resumed" in types
      refute "run_diverged" in types
    end
  end
end
