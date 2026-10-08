defmodule TinyCI.MixDelegateTest do
  # async: false because halt_unless_test/3 prints to stderr, which is one global device.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  alias TinyCI.MixDelegate

  describe "raise_on_error/2" do
    test ":ok passes through" do
      assert MixDelegate.raise_on_error(:ok) == :ok
    end

    test "a usage or failed error raises with its message" do
      assert_raise Mix.Error, "bad flag", fn ->
        MixDelegate.raise_on_error({:error, {:usage, "bad flag"}}, "ignored label")
      end

      assert_raise Mix.Error, "not found", fn ->
        MixDelegate.raise_on_error({:error, {:failed, "not found"}})
      end
    end

    test "any other error raises with the inspected reason, behind the label when given" do
      assert_raise Mix.Error, "TinyCI run failed: :pipeline_failed", fn ->
        MixDelegate.raise_on_error({:error, :pipeline_failed}, "TinyCI run failed")
      end

      assert_raise Mix.Error, ":boom", fn ->
        MixDelegate.raise_on_error({:error, :boom})
      end
    end
  end

  describe "halt_unless_test/3" do
    test "returns :ok or {:error, tag} without halting under the :test environment" do
      assert MixDelegate.halt_unless_test(:ok, :x_failed) == :ok
      assert MixDelegate.halt_unless_test({:error, :anything}, :x_failed) == {:error, :x_failed}
    end

    test "prints a usage or failed message to stderr first" do
      stderr =
        capture_io(:stderr, fn ->
          assert {:error, :x_failed} =
                   MixDelegate.halt_unless_test({:error, {:usage, "bad flag"}}, :x_failed)
        end)

      assert stderr =~ "bad flag"
    end

    test "prints nothing for an error the subcommand already reported" do
      assert capture_io(:stderr, fn ->
               MixDelegate.halt_unless_test({:error, :reported}, :x_failed)
             end) == ""
    end
  end
end
