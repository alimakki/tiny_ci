defmodule TinyCI.CLI.MessagesTest do
  # async: false because the tests capture stderr, which is one global device.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  alias TinyCI.CLI.{Actions, Attest, Cache, Run, Runs}

  # The CLI modules serve two front ends: `tiny_ci <cmd>` and `mix tiny_ci.<cmd>`.
  # Their usage errors and hints are therefore worded relative to the subcommand
  # ("runs show RUN_ID"), never with either executable prefix.

  @moduletag :tmp_dir

  defp neutral!(message) do
    refute message =~ "mix tiny_ci"
    refute message =~ "tiny_ci "
    message
  end

  describe "usage errors are front-end neutral" do
    test "runs show without an id" do
      assert {:error, {:usage, message}} = Runs.run(["show"])
      assert neutral!(message) == "Usage: runs show RUN_ID [--output json] [--events]"
    end

    test "cache with an unknown command" do
      assert {:error, {:usage, message}} = Cache.run(["bogus"])
      neutral!(message)
      assert message =~ "Unknown or missing command."
      assert message =~ "Usage: cache clean [--root DIR] | prune"
    end

    test "attest verify without a file" do
      assert {:error, {:usage, message}} = Attest.run(["verify"])
      assert neutral!(message) == "Usage: attest verify FILE --key PATH.pub"
    end
  end

  describe "hints printed by the commands are front-end neutral" do
    test "actions search with no match points at `actions index`", %{tmp_dir: tmp} do
      index = Path.join(tmp, "index.json")
      File.write!(index, TinyCI.Registry.Index.to_json(TinyCI.Registry.Index.new([])))

      stdout = capture_io(fn -> assert :ok = Actions.run(["search", "zzz", "--index", index]) end)

      assert neutral!(stdout) =~ "generate an index with `actions index`"
    end

    test "run's missing-signing-key message points at `attest gen-key`", %{tmp_dir: tmp} do
      pipeline = Path.join(tmp, "tiny_ci.exs")
      File.write!(pipeline, "stage :a do\n  step :b, cmd: \"true\"\nend\n")
      out = Path.join(tmp, "att.json")
      System.delete_env("TINY_CI_SIGNING_KEY")

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert {:error, :attestation_failed} =
                     Run.run(["--file", pipeline, "--root", tmp, "--no-record", "--attest", out])
          end)
        end)

      assert neutral!(stderr) =~ "Generate one with `attest gen-key`."
    end
  end

  describe "colour of error output" do
    setup do
      previous = Application.fetch_env(:elixir, :ansi_enabled)
      Application.put_env(:elixir, :ansi_enabled, true)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:elixir, :ansi_enabled, value)
          :error -> Application.delete_env(:elixir, :ansi_enabled)
        end
      end)
    end

    test "only the first line of a multi-line usage error is coloured" do
      stderr =
        capture_io(:stderr, fn ->
          TinyCI.CLI.print_error("Unknown or missing command.\n\nUsage: cache stats")
        end)

      assert stderr ==
               IO.ANSI.red() <>
                 "Unknown or missing command." <>
                 IO.ANSI.reset() <> "\n\nUsage: cache stats\n"
    end
  end
end
