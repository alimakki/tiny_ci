defmodule TinyCI.Executor.CrashTest do
  use ExUnit.Case, async: true

  alias TinyCI.Executor.Crash

  doctest Crash

  describe "format/3" do
    test "formats a raised exception with its class and message" do
      text = Crash.format(:error, %RuntimeError{message: "kaboom"}, [])
      assert String.starts_with?(text, "Step crashed: ** (RuntimeError) kaboom")
    end

    test "normalizes erlang error terms into exceptions" do
      text = Crash.format(:error, :badarg, [])
      assert text =~ "(ArgumentError)"
    end

    test "formats an exit" do
      assert Crash.format(:exit, :shutdown, []) =~ "(exit) shutdown"
    end

    test "formats a throw" do
      assert Crash.format(:throw, :ball, []) =~ "(throw) :ball"
    end

    test "keeps the stack trace" do
      stacktrace = [{TinyCI.SandboxFixtures.Boom, :execute, 2, [file: ~c"boom.ex", line: 7]}]
      text = Crash.format(:error, %RuntimeError{message: "kaboom"}, stacktrace)
      assert text =~ "Boom.execute/2"
      assert text =~ "boom.ex:7"
    end
  end
end
