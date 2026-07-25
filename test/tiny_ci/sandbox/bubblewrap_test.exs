defmodule TinyCI.Sandbox.BubblewrapTest do
  @moduledoc """
  Integration tests that exercise the real Linux Bubblewrap backend: a confined
  child BEAM actually runs each action, and the kernel enforces the namespaces.

  Tagged `:bubblewrap` and excluded automatically where `bwrap` is not available
  (see `test/test_helper.exs`).
  """
  use ExUnit.Case, async: false

  alias TinyCI.Context
  alias TinyCI.Executor.Driver.Sandbox
  alias TinyCI.Sandbox.Backend.Bubblewrap

  alias TinyCI.SandboxFixtures.{
    Echo,
    EnvProbe,
    NativeEscape,
    TcpProbe,
    TcpProbeAllowed,
    WriteProbe,
    WriteProbeAllowed
  }

  @moduletag :bubblewrap

  defp run(module, config, opts \\ []) do
    context = Context.build(branch: "main", store: %{seed: 1})
    Sandbox.run(module, config, context, Keyword.put(opts, :backend, Bubblewrap))
  end

  defp listener do
    {:ok, socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
    {:ok, port} = :inet.port(socket)
    on_exit(fn -> :gen_tcp.close(socket) end)
    port
  end

  test "round-trips a benign action through a real confined BEAM" do
    assert {:ok, %{echoed: "hi", branch: "main", seed: 1}} = run(Echo, %{msg: "hi"})
  end

  describe "network capability" do
    test "an action without :network cannot open a socket" do
      port = listener()
      assert {:ok, %{connect: result}} = run(TcpProbe, %{host: "127.0.0.1", port: port})
      assert result =~ "error"
    end

    test "an action with :network can open a socket" do
      port = listener()
      assert {:ok, %{connect: "ok"}} = run(TcpProbeAllowed, %{host: "127.0.0.1", port: port})
    end
  end

  describe "filesystem capability" do
    test "an action without :filesystem_write cannot write outside granted paths" do
      path = Path.join(File.cwd!(), "probe_#{System.unique_integer([:positive])}.tmp")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{write: result}} = run(WriteProbe, %{path: path})
      assert result =~ "error"
      refute File.exists?(path)
    end

    test "an action may write to an explicitly granted path" do
      dir = Path.join(File.cwd!(), "grant_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      path = Path.join(dir, "out.tmp")

      assert {:ok, %{write: "ok"}} =
               run(WriteProbeAllowed, %{path: path}, grants: [write_paths: [dir]])

      assert File.exists?(path)
    end
  end

  describe "environment isolation" do
    test "only granted env vars are visible; ungranted ones are absent" do
      System.put_env("TINY_CI_GRANTED", "yes")
      System.put_env("TINY_CI_SECRET", "leak")
      on_exit(fn -> System.delete_env("TINY_CI_GRANTED") end)
      on_exit(fn -> System.delete_env("TINY_CI_SECRET") end)

      config = %{vars: ["TINY_CI_GRANTED", "TINY_CI_SECRET"]}
      assert {:ok, %{seen: seen}} = run(EnvProbe, config, grants: [env: ["TINY_CI_GRANTED"]])

      assert seen["TINY_CI_GRANTED"] == "yes"
      assert seen["TINY_CI_SECRET"] == nil
    end
  end

  describe "native escape attempt" do
    test "a native subprocess cannot write outside the sandbox" do
      path = Path.join(File.cwd!(), "escape_#{System.unique_integer([:positive])}.tmp")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, %{exit: exit_code}} = run(NativeEscape, %{path: path})
      assert exit_code != 0
      refute File.exists?(path)
    end
  end
end
