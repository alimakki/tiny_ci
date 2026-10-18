defmodule TinyCI.Execution.Backend.ContainerPodmanTest do
  @moduledoc """
  A minimal rootless-Podman smoke test for the container backend.

  Tagged `:podman` and excluded when Podman is unavailable. `async: false` because
  it switches the application's `:container_runtime` while it runs.
  """

  use ExUnit.Case, async: false

  alias TinyCI.Execution.{Command, SessionSpec}
  alias TinyCI.Execution.Backend.Container

  @moduletag :podman
  @moduletag :tmp_dir

  @image "alpine:3.22"

  setup do
    previous = Application.get_env(:tiny_ci, :container_runtime)
    Application.put_env(:tiny_ci, :container_runtime, :podman)
    on_exit(fn -> restore_env(previous) end)
    :ok
  end

  test "rootless Podman keeps the host uid and can write the workspace", %{tmp_dir: tmp_dir} do
    case Container.runtime() do
      {:ok, %{kind: :podman, rootless: true}} ->
        assert_rootless_podman(tmp_dir)

      other ->
        IO.puts(
          :stderr,
          "skipping rootless Podman assertion: #{inspect(other)} " <>
            "(the runtime is rootful or unavailable)"
        )
    end
  end

  defp assert_rootless_podman(tmp_dir) do
    ensure_image()

    {:ok, session} =
      Container.open(%SessionSpec{workspace: tmp_dir, run_id: "podman_smoke", image: @image})

    try do
      command = %Command{run: {:shell, "id -u; echo podman > /workspace/from_podman"}}
      assert {:passed, output} = Container.exec(session, command, fn _ -> :ok end)
      assert String.starts_with?(output, host_uid() <> "\n")
      assert File.read!(Path.join(tmp_dir, "from_podman")) == "podman\n"
      assert File.stat!(Path.join(tmp_dir, "from_podman")).uid == String.to_integer(host_uid())
    after
      Container.close(session)
    end
  end

  defp ensure_image do
    case System.cmd("podman", ["image", "inspect", @image], stderr_to_stdout: true) do
      {_output, 0} ->
        :ok

      {_output, _} ->
        case System.cmd("podman", ["pull", @image], stderr_to_stdout: true) do
          {_output, 0} -> :ok
          {output, status} -> flunk("could not pull #{@image}: #{status} #{output}")
        end
    end
  end

  defp host_uid do
    {output, 0} = System.cmd("id", ["-u"])
    String.trim(output)
  end

  defp restore_env(nil), do: Application.delete_env(:tiny_ci, :container_runtime)
  defp restore_env(value), do: Application.put_env(:tiny_ci, :container_runtime, value)
end
