defmodule TinyCI.Application do
  @moduledoc false
  use Application

  def start(_type, _args) do
    children = [
      {Task.Supervisor, name: TinyCI.TaskSupervisor},
      {Registry, keys: :unique, name: TinyCI.Control.Registry}
    ]

    opts = [strategy: :one_for_one, name: TinyCI.Supervisor]
    {:ok, sup} = Supervisor.start_link(children, opts)

    maybe_run_cli()
    {:ok, sup}
  end

  @doc """
  Runs the command line when tiny_ci is launched as a standalone binary.

  Under `mix` and in the escript this is a no-op. The Burrito wrapper of a release
  binary sets `__BURRITO` and passes the CLI arguments through `-extra`, so they
  arrive at `:init.get_plain_arguments/0`; the wrapper also reports whether stdout
  is a terminal via `_IS_TTY`. Once read, the wrapper's environment is removed
  (`scrub_wrapper_env/0`) so it does not leak into spawned processes.

  Burrito is a build-time-only dependency and is not part of the release, so the
  branch is detected from the environment the wrapper sets rather than by calling
  Burrito. `:standalone_cli` forces the branch and `:standalone_argv` /
  `:standalone_cli_module` inject the arguments and the entrypoint, which is how a
  test exercises it without a real wrapper and without halting the VM.

  The CLI runs synchronously so its `System.halt/1` happens before the boot
  process reaches Burrito's `-s elixir start_cli`, which would otherwise consume
  the same `-extra` arguments as a script name and fail. `TinyCI.CLI.main/1` always
  halts, so `Application.start/2` does not return in a release.
  """
  @spec maybe_run_cli() :: :ok
  def maybe_run_cli do
    if standalone?() do
      configure_ansi()
      scrub_wrapper_env()
      run_cli(standalone_argv())
    end

    :ok
  end

  # Set by Burrito's launcher (`erlang_launcher.zig`, `wrapper.zig`) for the VM it
  # starts; none of them describe the user's environment.
  @wrapper_vars ~w(__BURRITO __BURRITO_BIN_PATH _IS_TTY RELEASE_ROOT RELEASE_SYS_CONFIG ROOTDIR BINDIR)

  # Appended to `LD_LIBRARY_PATH` by the launcher so bundled NIFs find system libraries.
  @burrito_lib_paths "/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu:/lib:/usr/lib"

  @doc """
  Removes what the Burrito wrapper added to the OS environment, so the processes
  tiny_ci spawns (pipeline steps, `git`, sandboxes) see the user's environment.

  Without this, every step inherits `__BURRITO` — so a step that starts the
  `:tiny_ci` application (`mix test` in a project depending on tiny_ci, the
  escript) would take the standalone branch and run the CLI with its own
  arguments — and a `PATH` that puts the bundled ERTS first, so a step's `erl`,
  `elixir`, and `mix` would run on tiny_ci's runtime instead of the project's.

  Drops the wrapper's variables, the `PATH` entries under the payload's `ROOTDIR`,
  and the launcher's `LD_LIBRARY_PATH` suffix. A no-op unless `__BURRITO` is set.
  The running VM is unaffected: it locates its own executables through the
  `-bindir` boot argument, and the dynamic loader reads `LD_LIBRARY_PATH` only at
  process start.
  """
  @spec scrub_wrapper_env() :: :ok
  def scrub_wrapper_env do
    if System.get_env("__BURRITO") do
      drop_path_entries_under(System.get_env("ROOTDIR"))
      strip_ld_library_path()
      Enum.each(@wrapper_vars, &System.delete_env/1)
    end

    :ok
  end

  defp drop_path_entries_under(nil), do: :ok

  defp drop_path_entries_under(root) do
    path =
      (System.get_env("PATH") || "")
      |> String.split(":")
      |> Enum.reject(&(&1 == root or String.starts_with?(&1, root <> "/")))
      |> Enum.join(":")

    System.put_env("PATH", path)
  end

  defp strip_ld_library_path do
    case System.get_env("LD_LIBRARY_PATH") do
      nil ->
        :ok

      @burrito_lib_paths ->
        System.delete_env("LD_LIBRARY_PATH")

      value ->
        System.put_env(
          "LD_LIBRARY_PATH",
          String.replace_suffix(value, ":" <> @burrito_lib_paths, "")
        )
    end
  end

  @doc """
  Disables colour when the Burrito wrapper reports stdout is not a terminal.

  A Burrito release is started with `ansi_enabled` forced on, so `IO.ANSI.enabled?/0`
  would report a terminal even when piped (and a piped run could try to start the
  interactive control console). The wrapper sets `_IS_TTY` to `0` in that case.

  This does not strip escape codes from the console reporter — those are emitted
  regardless of `ansi_enabled` for now; `--no-color` remains the explicit switch
  for the escript and the Mix front end.
  """
  @spec configure_ansi() :: :ok
  def configure_ansi do
    if System.get_env("_IS_TTY") == "0" do
      Application.put_env(:elixir, :ansi_enabled, false)
    end

    :ok
  end

  defp standalone? do
    Application.get_env(:tiny_ci, :standalone_cli, false) or
      System.get_env("__BURRITO") != nil
  end

  defp standalone_argv do
    Application.get_env(:tiny_ci, :standalone_argv) || plain_arguments()
  end

  defp plain_arguments do
    :init.get_plain_arguments() |> Enum.map(&to_string/1)
  end

  defp run_cli(argv) do
    module = Application.get_env(:tiny_ci, :standalone_cli_module, TinyCI.CLI)
    module.main(argv)
  catch
    # `main/1` halts with the command's exit code; anything that leaves it early
    # (raise, throw, or exit) would leave the release running with the supervisor
    # still up. Fail loudly and exit 1. `System.halt/1` itself is not catchable.
    kind, reason ->
      IO.puts(:stderr, Exception.format(kind, reason, __STACKTRACE__))
      System.halt(1)
  end
end
