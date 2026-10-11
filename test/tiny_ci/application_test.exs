defmodule TinyCI.ApplicationTest do
  # async: false — puts/removes shared application env and `System` env, and
  # stops/starts the application itself.
  use ExUnit.Case, async: false

  # Stopping the application (the `start/2` test) logs a notice; capture it so a
  # passing suite stays quiet.
  @moduletag :capture_log

  alias TinyCI.AnsiFixtures
  alias TinyCI.Application, as: App

  @standalone_keys [
    :standalone_cli,
    :standalone_argv,
    :standalone_cli_module,
    :standalone_cli_test_pid
  ]

  # Stands in for `TinyCI.CLI`: records the argv it was called with instead of
  # halting the VM (which is what the real `main/1` does).
  defmodule StubCLI do
    @moduledoc false

    def main(argv) do
      Application.get_env(:tiny_ci, :standalone_cli_test_pid)
      |> send({:cli, argv})
    end
  end

  # Everything `scrub_wrapper_env/0` reads or rewrites. Under Mix, `PATH`,
  # `ROOTDIR`, and `BINDIR` are the host's (the `erl` script exports them), so they
  # must come back intact for the tests that spawn `erl` or `mix` later.
  @os_env_vars ~w(__BURRITO __BURRITO_BIN_PATH _IS_TTY RELEASE_ROOT RELEASE_SYS_CONFIG
                  ROOTDIR BINDIR PATH LD_LIBRARY_PATH)

  @burrito_lib_paths "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib"

  setup do
    saved = Map.new(@os_env_vars, &{&1, System.get_env(&1)})
    # The restart path in the `start/2` test must not accidentally run the real
    # CLI because the suite was launched from inside a Burrito binary.
    System.delete_env("__BURRITO")

    on_exit(fn ->
      Enum.each(saved, fn {name, value} -> restore_env(name, value) end)

      for key <- @standalone_keys, do: Application.delete_env(:tiny_ci, key)
    end)

    :ok
  end

  describe "maybe_run_cli/0" do
    test "runs the configured CLI with the standalone argv when standalone" do
      Application.put_env(:tiny_ci, :standalone_cli, true)
      Application.put_env(:tiny_ci, :standalone_argv, ["version"])
      Application.put_env(:tiny_ci, :standalone_cli_module, StubCLI)
      Application.put_env(:tiny_ci, :standalone_cli_test_pid, self())

      assert :ok = App.maybe_run_cli()
      assert_receive {:cli, ["version"]}
    end

    test "treats the __BURRITO env var as standalone" do
      Application.put_env(:tiny_ci, :standalone_cli_module, StubCLI)
      Application.put_env(:tiny_ci, :standalone_cli_test_pid, self())
      System.put_env("__BURRITO", "1")

      assert :ok = App.maybe_run_cli()
      assert_receive {:cli, argv}
      assert is_list(argv)
    end

    test "does nothing when not standalone" do
      Application.put_env(:tiny_ci, :standalone_cli_module, StubCLI)
      Application.put_env(:tiny_ci, :standalone_cli_test_pid, self())
      System.delete_env("__BURRITO")

      assert :ok = App.maybe_run_cli()
      refute_receive {:cli, _argv}, 50
    end
  end

  describe "start/2" do
    test "runs the CLI when standalone" do
      Application.put_env(:tiny_ci, :standalone_cli, true)
      Application.put_env(:tiny_ci, :standalone_argv, ["version"])
      Application.put_env(:tiny_ci, :standalone_cli_module, StubCLI)
      Application.put_env(:tiny_ci, :standalone_cli_test_pid, self())

      # The suite runs with the application already started, so stop it to free
      # the supervisor names, then let the application controller start it again
      # through `TinyCI.Application.start/2` — the path a release takes.
      :ok = Application.stop(:tiny_ci)

      on_exit(fn ->
        for key <- @standalone_keys, do: Application.delete_env(:tiny_ci, key)
        {:ok, _} = Application.ensure_all_started(:tiny_ci)
      end)

      assert {:ok, _started} = Application.ensure_all_started(:tiny_ci)
      assert_receive {:cli, ["version"]}
    end
  end

  describe "scrub_wrapper_env/0" do
    setup do
      System.put_env(%{
        "__BURRITO" => "1",
        "__BURRITO_BIN_PATH" => "/home/u/bin/tiny_ci",
        "_IS_TTY" => "1",
        "RELEASE_ROOT" => "/data/.burrito/tiny_ci",
        "RELEASE_SYS_CONFIG" => "/data/.burrito/tiny_ci/releases/0.1.0/sys",
        "ROOTDIR" => "/data/.burrito/tiny_ci",
        "BINDIR" => "/data/.burrito/tiny_ci/erts-17.0.5/bin",
        "PATH" =>
          "/data/.burrito/tiny_ci/erts-17.0.5/bin:/data/.burrito/tiny_ci/bin:" <>
            "/usr/bin:/data/.burrito/tiny_ci_other/bin"
      })

      :ok
    end

    test "removes the wrapper's variables and its PATH entries" do
      assert :ok = App.scrub_wrapper_env()

      for name <- ~w(__BURRITO __BURRITO_BIN_PATH _IS_TTY RELEASE_ROOT RELEASE_SYS_CONFIG
                     ROOTDIR BINDIR) do
        assert System.get_env(name) == nil, "#{name} was not removed"
      end

      # Only entries under ROOTDIR go, not ones that merely share its prefix.
      assert System.get_env("PATH") == "/usr/bin:/data/.burrito/tiny_ci_other/bin"
    end

    test "restores the user's LD_LIBRARY_PATH" do
      System.put_env("LD_LIBRARY_PATH", "/opt/lib:" <> @burrito_lib_paths)
      App.scrub_wrapper_env()
      assert System.get_env("LD_LIBRARY_PATH") == "/opt/lib"
    end

    test "drops LD_LIBRARY_PATH when the launcher created it" do
      System.put_env("LD_LIBRARY_PATH", @burrito_lib_paths)
      App.scrub_wrapper_env()
      assert System.get_env("LD_LIBRARY_PATH") == nil
    end

    test "does nothing outside a Burrito binary" do
      System.delete_env("__BURRITO")
      path = System.get_env("PATH")

      assert :ok = App.scrub_wrapper_env()
      assert System.get_env("ROOTDIR") == "/data/.burrito/tiny_ci"
      assert System.get_env("PATH") == path
    end

    test "processes spawned by the standalone CLI do not see __BURRITO" do
      Application.put_env(:tiny_ci, :standalone_argv, ["version"])
      Application.put_env(:tiny_ci, :standalone_cli_module, StubCLI)
      Application.put_env(:tiny_ci, :standalone_cli_test_pid, self())
      # Keep a working shell reachable after the fake ROOTDIR entries are dropped.
      System.put_env("PATH", System.get_env("PATH") <> ":/bin")

      App.maybe_run_cli()
      assert_receive {:cli, ["version"]}

      assert {"unset", 0} = System.cmd("sh", ["-c", ~s(printf %s "${__BURRITO-unset}")])
    end
  end

  describe "configure_ansi/0" do
    test "disables ANSI when the Burrito wrapper reports stdout is not a terminal" do
      AnsiFixtures.set_ansi(true)
      System.put_env("_IS_TTY", "0")

      assert :ok = App.configure_ansi()
      refute IO.ANSI.enabled?()
    end

    test "leaves ANSI alone for a terminal or when unset" do
      AnsiFixtures.set_ansi(true)
      System.delete_env("_IS_TTY")

      assert :ok = App.configure_ansi()
      assert IO.ANSI.enabled?()
    end
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
