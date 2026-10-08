defmodule Mix.Tasks.TinyCi.DelegateContractsTest do
  # async: false because the tests capture stderr, which is one global device.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  # M1-01 moved the task bodies into TinyCI.CLI.*. These pin the Mix-visible
  # contracts that changed in the move; the rest are pinned by the older task tests.

  test "mix tiny_ci.run rejects an unknown flag with a Mix.Error naming it" do
    assert_raise Mix.Error, "Invalid option(s): --bogus", fn ->
      Mix.Tasks.TinyCi.Run.run(["--bogus"])
    end
  end

  test "mix tiny_ci.cache with an unknown command returns {:error, :cache_failed}" do
    stderr =
      capture_io(:stderr, fn ->
        assert Mix.Tasks.TinyCi.Cache.run(["bogus"]) == {:error, :cache_failed}
      end)

    assert stderr =~ "Unknown or missing command."
    assert stderr =~ "Usage: cache clean"
  end

  test "mix tiny_ci.attest.verify without arguments returns {:error, :verify_failed}" do
    stderr =
      capture_io(:stderr, fn ->
        assert Mix.Tasks.TinyCi.Attest.Verify.run([]) == {:error, :verify_failed}
      end)

    assert stderr =~ "Usage: attest verify FILE --key PATH.pub"
  end
end
