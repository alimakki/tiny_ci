defmodule TinyCI.UntrustedLoadingTest do
  # async: false because it loads/unloads a fixture module in the shared code
  # server and sets the environment variable its @on_load callback observes.
  use ExUnit.Case, async: false

  alias TinyCI.Discovery

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    path = Path.join(tmp_dir, "tiny_ci.exs")

    File.write!(path, """
    stage :build, mode: :serial do
      step :deploy, module: TinyCI.UnloadedActionFixture
    end
    """)

    marker = Path.join(tmp_dir, "on_load_marker")
    previous = System.get_env("TINY_CI_ON_LOAD_MARKER")
    System.put_env("TINY_CI_ON_LOAD_MARKER", marker)
    purge_fixture()

    on_exit(fn ->
      restore_env("TINY_CI_ON_LOAD_MARKER", previous)
      purge_fixture()
    end)

    {:ok, path: path, marker: marker}
  end

  test "untrusted loading never loads or executes a repository module",
       %{path: path, marker: marker} do
    assert {:ok, %{stages: [%{steps: [%{module: TinyCI.UnloadedActionFixture}]}]}} =
             Discovery.load_pipeline(path, load_actions: false)

    refute :code.is_loaded(TinyCI.UnloadedActionFixture)
    refute File.exists?(marker)
  end

  test "trusted loading still validates and loads the module",
       %{path: path, marker: marker} do
    assert {:ok, _spec} = Discovery.load_pipeline(path)

    assert :code.is_loaded(TinyCI.UnloadedActionFixture)
    assert File.read!(marker) == "loaded"
  end

  defp purge_fixture do
    :code.purge(TinyCI.UnloadedActionFixture)
    :code.delete(TinyCI.UnloadedActionFixture)
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
