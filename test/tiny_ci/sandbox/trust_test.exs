defmodule TinyCI.Sandbox.TrustTest do
  use ExUnit.Case, async: true

  alias TinyCI.Sandbox.Trust
  alias TinyCI.SandboxFixtures.Echo

  defmodule ScriptLocal do
    @moduledoc false
    def execute(_c, _ctx), do: :ok
  end

  describe "classify/2" do
    test "a module owned by the root app is first-party" do
      assert Trust.classify(Echo, root_app: :tiny_ci) == :first_party
    end

    test "a module owned by another app is third-party" do
      assert Trust.classify(Echo, root_app: :some_other_app) == :third_party
    end

    test "an OTP/Elixir module is builtin" do
      assert Trust.classify(Enum, root_app: :tiny_ci) == :builtin
    end

    test "a module with no owning application is local" do
      assert Trust.classify(ScriptLocal, root_app: :tiny_ci) == :local
    end
  end

  describe "trusted?/2" do
    test "first-party, builtin, and local are trusted; third-party is not" do
      assert Trust.trusted?(Echo, root_app: :tiny_ci)
      assert Trust.trusted?(Enum, root_app: :tiny_ci)
      assert Trust.trusted?(ScriptLocal, root_app: :tiny_ci)
      refute Trust.trusted?(Echo, root_app: :some_other_app)
    end
  end

  describe "classify/1 with Mix loadable but not running" do
    # `TinyCI.Project.root_app/0` loads `Mix.Project` on first call; if `classify/2`
    # then asked `Mix.Project` directly, `Mix.Project.config/0` would exit with
    # `{:noproc, …}` because no project stack is alive (as in the escript). A bare
    # `erl` is the only way to get a VM in that state, hence the subprocess.
    @erl System.find_executable("erl")

    @tag skip: if(@erl, do: false, else: "the `erl` executable is not on the PATH")
    test "does not crash when Mix is loadable but no project is running" do
      ebin = Path.join(Mix.Project.app_path(), "ebin")
      elixir_libs = :elixir |> :code.lib_dir() |> Path.dirname()

      code =
        "R = 'Elixir.TinyCI.Project':root_app(), " <>
          "C = 'Elixir.TinyCI.Sandbox.Trust':classify('Elixir.Kernel'), " <>
          "io:format(\"~p ~p~n\", [R, C]), halt(0)."

      {output, status} =
        System.cmd(@erl, ["-noshell", "-pa", ebin, "-eval", code],
          env: [{"ERL_LIBS", elixir_libs}, {"ERL_CRASH_DUMP", "/dev/null"}],
          stderr_to_stdout: true
        )

      assert status == 0
      # `root_app` is nil (no Mix project); the class is a valid atom, not a crash.
      assert String.starts_with?(String.trim(output), "nil ")
    end
  end
end
