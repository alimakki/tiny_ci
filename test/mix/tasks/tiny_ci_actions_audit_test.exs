defmodule AuditTaskAction do
  @moduledoc false
  def execute(_config, _ctx), do: :ok
end

defmodule Mix.Tasks.TinyCi.Actions.AuditTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @tmp_dir "test/tmp/audit_task"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)
    :ok
  end

  test "prints the resolved action tree for a pipeline" do
    path = Path.join(@tmp_dir, "tiny_ci.exs")

    File.write!(path, """
    stage :build, mode: :serial do
      step :run, module: AuditTaskAction
    end
    """)

    output =
      capture_io(fn ->
        assert Mix.Tasks.TinyCi.Actions.Audit.run(["--file", path]) == :ok
      end)

    assert output =~ "Resolved actions (1)"
    assert output =~ "AuditTaskAction"
    assert output =~ "local"
  end

  test "reports when a pipeline has no module actions" do
    path = Path.join(@tmp_dir, "tiny_ci.exs")

    File.write!(path, """
    stage :build, mode: :serial do
      step :run, cmd: "echo hi"
    end
    """)

    output =
      capture_io(fn ->
        assert Mix.Tasks.TinyCi.Actions.Audit.run(["--file", path]) == :ok
      end)

    assert output =~ "No module actions"
  end

  test "errors when no pipeline file is found" do
    stderr =
      capture_io(:stderr, fn ->
        result = Mix.Tasks.TinyCi.Actions.Audit.run(["--file", "/nonexistent/tiny_ci.exs"])
        assert result == {:error, :audit_failed}
      end)

    assert stderr =~ "not found" or stderr =~ "Error"
  end
end
