defmodule TinyCI.CLI.RunContainerTest do
  @moduledoc """
  End-to-end `tiny_ci run --isolate` through the CLI and the container backend.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TinyCI.CLI
  alias TinyCI.Execution.Backend.Container

  @moduletag :container
  @moduletag :tmp_dir

  defp image, do: "alpine:3.22"

  setup_all do
    {:ok, runtime} = Container.runtime()
    ensure_image(runtime, image())
    :ok
  end

  setup do
    previous = Application.get_env(:tiny_ci, :default_image)
    Application.put_env(:tiny_ci, :default_image, image())

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:tiny_ci, :default_image)
        value -> Application.put_env(:tiny_ci, :default_image, value)
      end
    end)

    :ok
  end

  test "--isolate runs a shell-only pipeline in the container", %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "tiny_ci.exs")

    File.write!(path, """
    stage :build, mode: :serial do
      step :image, cmd: "cat /etc/alpine-release"
      step :workspace, cmd: "echo made > /workspace/from_cli"
    end
    """)

    argv = ["run", "--file", path, "--root", tmp_dir, "--no-record", "--isolate"]

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(self(), {:code, CLI.run(argv)}) end)
        send(self(), {:stdout, stdout})
      end)

    assert_received {:code, 0}
    assert_received {:stdout, stdout}

    assert stdout =~ ~r/\d+\.\d+/
    assert stdout =~ "Pipeline completed successfully"
    assert stderr == ""
    assert File.read!(Path.join(tmp_dir, "from_cli")) == "made\n"
  end

  defp ensure_image(runtime, image) do
    case System.cmd(runtime.command, ["image", "inspect", image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _} ->
        case System.cmd(runtime.command, ["pull", image], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("could not pull #{image} (#{status}): #{output}")
        end
    end
  end
end
