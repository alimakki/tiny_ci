defmodule TinyCI.CLI.RunEnvironmentTest do
  # async: false — the CLI captures stdout/stderr (global devices) and these
  # tests switch operator configuration in the application environment.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TinyCI.CLI

  @moduletag :tmp_dir

  @ansi ~r/\e\[[0-9;]*m/

  defp strip_ansi(text), do: String.replace(text, @ansi, "")

  defp write_pipeline(root, contents) do
    path = Path.join(root, "tiny_ci.exs")
    File.write!(path, contents)
    path
  end

  defp invoke(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:code, CLI.run(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:code, code}
    assert_received {:stdout, stdout}
    {code, strip_ansi(stdout), strip_ansi(stderr)}
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:tiny_ci, key)
  defp restore_app_env(key, value), do: Application.put_env(:tiny_ci, key, value)

  describe "--dry-run environments" do
    test "shows a pipeline image on inherited stages and exits 0 without pulling", ctx do
      write_pipeline(ctx.tmp_dir, """
      image "tiny_ci_no_such_image:1"

      stage :build, mode: :serial do
        step :one, cmd: "true"
      end
      """)

      assert {0, stdout, ""} = invoke(["run", "--root", ctx.tmp_dir, "--dry-run"])

      assert stdout =~ "Environment: container image=tiny_ci_no_such_image:1"
      assert stdout =~ "digest=unresolved"
    end

    test "shows a stage override", ctx do
      write_pipeline(ctx.tmp_dir, """
      image "pipeline:1"

      stage :build, mode: :serial, image: "stage:2" do
        step :one, cmd: "true"
      end
      """)

      assert {0, stdout, ""} = invoke(["run", "--root", ctx.tmp_dir, "--dry-run"])

      assert stdout =~ "Environment: container image=stage:2"
      refute stdout =~ "Environment: container image=pipeline:1"
    end

    test "a host pipeline prints exactly what it printed before", ctx do
      write_pipeline(ctx.tmp_dir, """
      stage :build, mode: :serial do
        step :one, cmd: "true"
      end
      """)

      assert {0, stdout, ""} = invoke(["run", "--root", ctx.tmp_dir, "--dry-run"])

      assert stdout =~ "▶ :build"
      refute stdout =~ "Environment:"
    end

    test "an unresolved environment is a warning, and the dry run still exits 0", ctx do
      previous = Application.get_env(:tiny_ci, :container_runtime)

      Application.put_env(:tiny_ci, :container_runtime, :not_a_runtime)

      on_exit(fn -> restore_app_env(:container_runtime, previous) end)

      write_pipeline(ctx.tmp_dir, """
      image "alpine:3.22"

      stage :build, mode: :serial do
        step :one, cmd: "true"
      end
      """)

      assert {0, stdout, ""} = invoke(["run", "--root", ctx.tmp_dir, "--dry-run"])

      assert stdout =~ "Environment: unresolved —"
      assert stdout =~ "container_runtime"
    end

    test "a skipped stage with an image does not print an environment line", ctx do
      write_pipeline(ctx.tmp_dir, """
      image "tiny_ci_no_such_image:1"

      stage :build, mode: :serial, when: branch() == "never" do
        step :one, cmd: "true"
      end
      """)

      assert {0, stdout, ""} = invoke(["run", "--root", ctx.tmp_dir, "--dry-run"])

      assert stdout =~ "will skip"
      refute stdout =~ "Environment:"
    end
  end
end
