defmodule TinyCI.ProjectTest do
  use ExUnit.Case, async: true

  doctest TinyCI.Project

  describe "version/0" do
    test "is the version of the :tiny_ci application" do
      assert TinyCI.Project.version() == to_string(Application.spec(:tiny_ci, :vsn))
    end
  end

  describe "root_app/0" do
    test "is the app of the Mix project when running under Mix" do
      assert TinyCI.Project.root_app() == :tiny_ci
    end
  end

  describe "root_app/0 with Mix loadable but not running" do
    # Elixir's libraries are on the code path (as with ERL_LIBS) so `Mix.Project` loads,
    # but Mix itself never starts, so there is no project stack to ask. Without the
    # `Mix.ProjectStack` guard, `Mix.Project.config/0` exits with `{:noproc, ...}`.
    # A bare `erl` is the only way to get a VM in that state, hence the subprocess.
    @erl System.find_executable("erl")

    @tag skip: if(@erl, do: false, else: "the `erl` executable is not on the PATH")
    test "returns nil instead of crashing" do
      ebin = Path.join(Mix.Project.app_path(), "ebin")
      elixir_libs = :elixir |> :code.lib_dir() |> Path.dirname()

      code = "io:format(\"~p~n\", ['Elixir.TinyCI.Project':root_app()]), halt(0)."

      {output, status} =
        System.cmd(@erl, ["-noshell", "-pa", ebin, "-eval", code],
          # A broken guard crashes the VM; do not let it write erl_crash.dump into the cwd.
          env: [{"ERL_LIBS", elixir_libs}, {"ERL_CRASH_DUMP", "/dev/null"}],
          stderr_to_stdout: true
        )

      assert String.trim(output) == "nil", output
      assert status == 0
    end
  end
end
