defmodule TinyCI.CLI.RunTest do
  # async: false because the tests capture stderr (one global device) and one of them
  # passes --no-color, which changes the global `:elixir, :ansi_enabled` env; both
  # the env and the capture are restored/scoped per test.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.TinyCi.Run, as: MixRun
  alias TinyCI.CLI
  alias TinyCI.CLI.Run

  @moduletag :tmp_dir

  @ansi ~r/\e\[[0-9;]*m/

  setup %{tmp_dir: tmp_dir} do
    ansi = Application.fetch_env(:elixir, :ansi_enabled)
    Application.put_env(:elixir, :ansi_enabled, false)

    on_exit(fn ->
      case ansi do
        {:ok, value} -> Application.put_env(:elixir, :ansi_enabled, value)
        :error -> Application.delete_env(:elixir, :ansi_enabled)
      end
    end)

    path = Path.join(tmp_dir, "tiny_ci.exs")

    File.write!(path, """
    stage :build, mode: :serial do
      step :compile, cmd: "echo compiling"
    end

    stage :test, needs: [:build], mode: :serial do
      step :unit, cmd: "echo testing"
    end
    """)

    {:ok, pipeline: path, root: tmp_dir}
  end

  defp strip_ansi(text), do: String.replace(text, @ansi, "")

  # Runs `argv` through the CLI, returning `{exit_code, stdout, stderr}`.
  defp invoke(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:code, CLI.run(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:code, code}
    assert_received {:stdout, stdout}
    {code, stdout, stderr}
  end

  describe "tiny_ci run, through TinyCI.CLI.run/1" do
    # Both sides run `TinyCI.CLI.Run`, so this can only catch wiring mistakes in the
    # dispatcher or the Mix delegate. The untouched `test/mix/tasks/*.exs` suite is the
    # real regression net for the moved bodies.
    test "a dry run prints the same plan as `mix tiny_ci.run --dry-run`", ctx do
      args = ["--file", ctx.pipeline, "--root", ctx.root, "--dry-run"]

      assert {0, cli_out, ""} = invoke(["run" | args])
      mix_out = capture_io(fn -> assert :ok = MixRun.run(args) end)

      assert strip_ansi(cli_out) == strip_ansi(mix_out)
      assert cli_out =~ "compiling"
    end

    test "a passing pipeline exits 0", ctx do
      assert {0, stdout, ""} =
               invoke(["run", "--file", ctx.pipeline, "--root", ctx.root, "--no-record"])

      assert stdout =~ "Pipeline completed successfully"
    end

    test "a failing pipeline exits 1", ctx do
      File.write!(ctx.pipeline, """
      stage :fail, mode: :serial do
        step :boom, cmd: "exit 1"
      end
      """)

      assert {1, _stdout, stderr} =
               invoke(["run", "--file", ctx.pipeline, "--root", ctx.root, "--no-record"])

      assert stderr =~ "Pipeline failed"
    end

    test "a missing pipeline file exits 1", ctx do
      assert {1, "", stderr} = invoke(["run", "--file", Path.join(ctx.root, "nope.exs")])
      assert stderr =~ "not found"
    end

    test "an unknown flag is a usage error naming the flag, and exits 2", ctx do
      assert {2, "", stderr} = invoke(["run", "--file", ctx.pipeline, "--bogus"])
      assert stderr =~ "--bogus"
      assert stderr =~ "tiny_ci help run"
    end

    test "--events - together with --output json is a usage error", ctx do
      assert {2, "", stderr} =
               invoke(["run", "--root", ctx.root, "--events", "-", "--output", "json"])

      assert stderr =~ "cannot share stdout"
    end

    # What the `run` help says about exit code 2: an unknown flag, a wrong-typed value,
    # or --events - with --output json. Any other invalid value is a failed run (1).
    test "exit code 2 is for unknown flags and wrong types; other invalid values exit 1", ctx do
      base = ["run", "--file", ctx.pipeline, "--root", ctx.root, "--no-record"]

      for extra <- [["--bogus"], ["--break-timeout", "abc"]] do
        assert {2, "", _stderr} = invoke(base ++ extra)
      end

      for extra <- [
            ["--output", "xml"],
            ["--break", "nonsense"],
            ["--break", "before:build", "--break-timeout-action", "foo"],
            ["--filter", ":nosuch"]
          ] do
        assert {1, _stdout, stderr} = invoke(base ++ extra)
        assert stderr != "", "no message for #{inspect(extra)}"
      end
    end

    test "an unknown --output format exits 1", ctx do
      assert {1, "", stderr} = invoke(["run", "--file", ctx.pipeline, "--output", "xml"])
      assert stderr =~ "Unknown --output format"
    end

    test "--no-color is accepted after the subcommand", ctx do
      args = ["run", "--file", ctx.pipeline, "--root", ctx.root, "--dry-run", "--no-color"]

      assert {0, _stdout, ""} = invoke(args)
    end
  end

  describe "--no-color" do
    test "mix tiny_ci.run accepts it and turns ANSI off", ctx do
      Application.put_env(:elixir, :ansi_enabled, true)

      capture_io(fn ->
        assert :ok =
                 MixRun.run([
                   "--no-color",
                   "--dry-run",
                   "--file",
                   ctx.pipeline,
                   "--root",
                   ctx.root
                 ])
      end)

      refute IO.ANSI.enabled?()
    end

    test "Run.run/1 accepts it directly and turns ANSI off", ctx do
      Application.put_env(:elixir, :ansi_enabled, true)

      capture_io(fn ->
        assert :ok =
                 Run.run(["--no-color", "--dry-run", "--file", ctx.pipeline, "--root", ctx.root])
      end)

      refute IO.ANSI.enabled?()
    end

    test "tiny_ci run accepts it and turns ANSI off", ctx do
      Application.put_env(:elixir, :ansi_enabled, true)

      args = ["run", "--no-color", "--dry-run", "--file", ctx.pipeline, "--root", ctx.root]
      assert {0, _stdout, ""} = invoke(args)
      refute IO.ANSI.enabled?()
    end
  end

  describe "run/1" do
    test "returns :ok for a dry run", ctx do
      capture_io(fn ->
        assert :ok = Run.run(["--file", ctx.pipeline, "--root", ctx.root, "--dry-run"])
      end)
    end

    test "returns {:error, :pipeline_failed} instead of raising when a step fails", ctx do
      File.write!(ctx.pipeline, "stage :fail do\n  step :boom, cmd: \"exit 1\"\nend\n")

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert {:error, :pipeline_failed} =
                   Run.run(["--file", ctx.pipeline, "--root", ctx.root, "--no-record"])
        end)
      end)
    end

    test "rejects an unknown flag as a usage error" do
      assert {:error, {:usage, "Invalid option(s): --bogus"}} = Run.run(["--bogus"])
    end

    test "a non-integer --break-timeout is a usage error naming the value" do
      assert {:error, {:usage, "Invalid option(s): --break-timeout abc"}} =
               Run.run(["--break-timeout", "abc"])
    end

    test "names every invalid flag" do
      assert {:error, {:usage, message}} = Run.run(["--bogus", "--worse", "x"])
      assert message =~ "--bogus"
      assert message =~ "--worse"
    end

    test "a run with the control and cache switches armed is accepted under strict parsing",
         ctx do
      # --output json keeps the (non-interactive) control driver out of the way.
      argv = [
        "--file",
        ctx.pipeline,
        "--root",
        ctx.root,
        "--base",
        "HEAD",
        "--dry-run",
        "--output",
        "json",
        "--filter",
        ":build",
        "--no-cache",
        "--no-record",
        "--artifacts-dir",
        Path.join(ctx.root, "artifacts"),
        "--signing-key",
        Path.join(ctx.root, "unused.key"),
        "--break",
        "before:build",
        "--break",
        "after:test.unit",
        "--break-timeout",
        "100",
        "--break-timeout-action",
        "continue",
        "--debug-serial"
      ]

      capture_io(:stderr, fn ->
        capture_io(fn -> assert :ok = Run.run(argv) end)
      end)
    end

    test "accepts the -f and -r aliases", ctx do
      capture_io(fn ->
        assert :ok = Run.run(["-f", ctx.pipeline, "-r", ctx.root, "--dry-run"])
      end)
    end

    test "--list and --list-artifacts are accepted", ctx do
      capture_io(fn ->
        assert :ok = Run.run(["--root", ctx.root, "--list"])
        assert :ok = Run.run(["--root", ctx.root, "--list-artifacts"])
      end)
    end
  end

  describe "parse/1" do
    test "carries every switch the Mix task accepted, with its type" do
      argv = [
        "--file",
        "p.exs",
        "--root",
        "/r",
        "--base",
        "main",
        "--dry-run",
        "--list",
        "--filter",
        ":a,:b",
        "--output",
        "json",
        "--no-cache",
        "--artifacts-dir",
        "/art",
        "--list-artifacts",
        "--events",
        "-",
        "--no-record",
        "--attest",
        "a.json",
        "--signing-key",
        "k",
        "--break",
        "before:a",
        "--break",
        "after:b",
        "--break-timeout",
        "250",
        "--break-timeout-action",
        "continue",
        "--debug-serial",
        "NAME"
      ]

      assert {:ok, opts, ["NAME"]} = Run.parse(argv)

      assert opts[:file] == "p.exs"
      assert opts[:root] == "/r"
      assert opts[:base] == "main"
      assert opts[:dry_run] === true
      assert opts[:list] === true
      assert opts[:filter] == ":a,:b"
      assert opts[:output] == "json"
      assert opts[:no_cache] === true
      assert opts[:artifacts_dir] == "/art"
      assert opts[:list_artifacts] === true
      assert opts[:events] == "-"
      assert opts[:record] === false
      assert opts[:attest] == "a.json"
      assert opts[:signing_key] == "k"
      assert Keyword.get_values(opts, :break) == ["before:a", "after:b"]
      assert opts[:break_timeout] === 250
      assert opts[:break_timeout_action] == "continue"
      assert opts[:debug_serial] === true
    end

    test "--no-color is a boolean switch" do
      assert {:ok, opts, []} = Run.parse(["--no-color"])
      assert opts[:no_color] === true
    end

    test "-f and -r are aliases" do
      assert {:ok, opts, []} = Run.parse(["-f", "p.exs", "-r", "/r"])
      assert opts[:file] == "p.exs"
      assert opts[:root] == "/r"
    end

    test "an unknown flag and a mistyped value are both reported" do
      assert {:error, {:usage, "Invalid option(s): --bogus, --break-timeout abc"}} =
               Run.parse(["--bogus", "--break-timeout", "abc"])
    end
  end

  describe "help/1" do
    test "documents the command under the name it is given" do
      assert Run.help("tiny_ci run") =~ "tiny_ci run [NAME] [options]"
      assert Run.help("mix tiny_ci.run") =~ "mix tiny_ci.run [NAME] [options]"
    end

    test "help/0 is the standalone form" do
      assert Run.help() == Run.help("tiny_ci run")
      refute Run.help() =~ "mix tiny_ci"
    end

    test "the first line is a one-sentence summary" do
      assert [summary | _] = String.split(Run.help(), "\n")
      assert summary =~ "pipeline"
    end

    test "documents every flag" do
      help = Run.help()

      for flag <- ~w(--file --root --base --dry-run --list --filter --output --events
                     --no-record --break --break-timeout --break-timeout-action
                     --debug-serial --no-cache --no-color --attest --signing-key --artifacts-dir
                     --list-artifacts) do
        assert help =~ flag, "#{flag} is missing from the run help"
      end
    end
  end
end
