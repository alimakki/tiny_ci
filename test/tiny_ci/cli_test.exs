defmodule TinyCI.CLITest.FakeSub do
  @moduledoc false
  @behaviour TinyCI.CLI.Subcommand

  @impl true
  def run(args) do
    IO.puts("fake ran #{inspect(args)}")
    :ok
  end

  @impl true
  def help, do: "A fake subcommand registered for tests.\n\nUsage: tiny_ci fake"
end

defmodule TinyCI.CLITest.UsageSub do
  @moduledoc false
  @behaviour TinyCI.CLI.Subcommand

  @impl true
  def run(_args), do: {:error, {:usage, "bad flag --zzz"}}

  @impl true
  def help, do: "Always a usage error."
end

defmodule TinyCI.CLITest.FailedSub do
  @moduledoc false
  @behaviour TinyCI.CLI.Subcommand

  @impl true
  def run(["opaque"]), do: {:error, :printed_already}
  def run(_args), do: {:error, {:failed, "it went wrong"}}

  @impl true
  def help, do: "Always fails."
end

defmodule TinyCI.CLITest.RaisingHelpSub do
  @moduledoc false
  def run(_args), do: :ok
  def help, do: raise("help exploded")
end

defmodule TinyCI.CLITest.NonBinaryHelpSub do
  @moduledoc false
  def run(_args), do: :ok
  def help, do: :not_a_string
end

defmodule TinyCI.CLITest.NilRunSub do
  @moduledoc false
  def run(_args), do: nil
  def help, do: "Returns nil from run/1."
end

defmodule TinyCI.CLITest.BadMessageSub do
  @moduledoc false
  @behaviour TinyCI.CLI.Subcommand

  # The first argument picks what to return, so one registered extra can cover every shape.
  @impl true
  def run(["failed_atom"]), do: {:error, {:failed, :oops}}
  def run(["usage_charlist"]), do: {:error, {:usage, ~c"charlist message"}}
  def run(["failed_iodata"]), do: {:error, {:failed, ["io", ?d, ["ata" | "!"]]}}
  def run(["failed_bad_iodata"]), do: {:error, {:failed, ["ok", <<255>>, 1_114_112]}}
  def run(["failed_tuple"]), do: {:error, {:failed, {:a, 1}}}
  def run(["usage_nil"]), do: {:error, {:usage, nil}}
  def run(["failed_multiline"]), do: {:error, {:failed, "first line\nsecond line"}}
  def run(["failed_invalid_utf8"]), do: {:error, {:failed, <<255>>}}
  def run(["failed_invalid_multiline"]), do: {:error, {:failed, "ok\n" <> <<255>>}}

  @impl true
  def help, do: "Returns odd messages."
end

defmodule TinyCI.CLITest do
  # async: false because these tests change global state: the `:cli_subcommands`
  # application env and `:elixir, :ansi_enabled` (what `IO.ANSI.enabled?/0` reads).
  # Both are restored in `on_exit`.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias TinyCI.CLI

  alias TinyCI.CLITest.{
    BadMessageSub,
    FailedSub,
    FakeSub,
    NilRunSub,
    NonBinaryHelpSub,
    RaisingHelpSub,
    UsageSub
  }

  doctest TinyCI.CLI

  setup do
    ansi = Application.fetch_env(:elixir, :ansi_enabled)
    Application.put_env(:elixir, :ansi_enabled, false)
    subcommands = Application.fetch_env(:tiny_ci, :cli_subcommands)

    on_exit(fn ->
      restore(:elixir, :ansi_enabled, ansi)
      restore(:tiny_ci, :cli_subcommands, subcommands)
    end)
  end

  defp restore(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore(app, key, :error), do: Application.delete_env(app, key)

  # Runs `argv`, returning `{exit_code, stdout, stderr}`.
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

  describe "run/1 dispatch" do
    test "no arguments prints usage to stderr and exits 2" do
      assert {2, "", stderr} = invoke([])
      assert stderr =~ "Usage: tiny_ci <command>"
      assert stderr =~ "run"
    end

    test "an unknown subcommand is named, and exits 2" do
      assert {2, "", stderr} = invoke(["nope"])
      assert stderr =~ "Unknown command: nope"
      assert stderr =~ "Usage: tiny_ci <command>"
    end

    test "version and --version print the application version and exit 0" do
      expected = "tiny_ci #{Application.spec(:tiny_ci, :vsn)}\n"

      assert {0, ^expected, ""} = invoke(["version"])
      assert {0, ^expected, ""} = invoke(["--version"])
    end

    test "help, --help and -h list the built-in commands on stdout and exit 0" do
      for argv <- [["help"], ["--help"], ["-h"]] do
        assert {0, stdout, ""} = invoke(argv)
        assert stdout =~ "Usage: tiny_ci <command>"

        for command <- ~w(run runs cache attest actions version help) do
          assert stdout =~ ~r/^  #{command}\s/m
        end
      end
    end

    test "help SUBCOMMAND prints that subcommand's help, in the tiny_ci form" do
      assert {0, stdout, ""} = invoke(["help", "run"])
      assert stdout =~ "tiny_ci run [NAME] [options]"
      refute stdout =~ "mix tiny_ci.run [NAME]"
    end

    test "help --help and help -h print the top-level help and exit 0" do
      for flag <- ["--help", "-h"] do
        assert {0, stdout, ""} = invoke(["help", flag])
        assert stdout =~ "Usage: tiny_ci <command>"
      end
    end

    test "the --no-color help says what the flag does, not that it disables colours" do
      assert {0, stdout, ""} = invoke(["help"])
      [_before, rest] = String.split(stdout, "--no-color", parts: 2)
      [entry, _after] = String.split(rest, "--version", parts: 2)

      assert entry =~ "non-interactive"
      assert entry =~ "not yet removed"
      refute stdout =~ ~r/disable\s+(ANSI|colou?rs)/i
    end

    test "the moduledoc does not claim --no-color disables colours either" do
      {:docs_v1, _, _, _, %{"en" => moduledoc}, _, _} = Code.fetch_docs(CLI)
      moduledoc = String.replace(moduledoc, ~r/\s+/, " ")

      assert moduledoc =~ "non-interactive"
      assert moduledoc =~ "not yet removed"
      refute moduledoc =~ ~r/disable\s+(ANSI|colou?rs)/i
    end

    test "help version and help help describe the meta commands and exit 0" do
      assert {0, stdout, ""} = invoke(["help", "version"])
      assert stdout =~ "Usage: tiny_ci version"

      assert {0, stdout, ""} = invoke(["help", "help"])
      assert stdout =~ "Usage: tiny_ci help [command]"
    end

    test "--help and -h are not flags after a `--`" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"fake", FakeSub}])

      for flag <- ["--help", "-h"] do
        assert {0, stdout, ""} = invoke(["fake", "--", flag])
        assert stdout =~ ~s(fake ran ["--", "#{flag}"])
      end

      assert {0, stdout, ""} = invoke(["fake", "a", "--", "--help"])
      assert stdout =~ "fake ran"

      # ...but still are before it.
      assert {0, stdout, ""} = invoke(["fake", "--help", "--"])
      assert stdout =~ "Usage: tiny_ci fake"
    end

    @tag :tmp_dir
    test "run -- --help treats --help as an argument, not a request for help", %{tmp_dir: tmp} do
      assert {1, stdout, _stderr} = invoke(["run", "--root", tmp, "--", "--help"])
      refute stdout =~ "[NAME] [options]"
    end

    test "help for an unknown subcommand exits 2" do
      assert {2, "", stderr} = invoke(["help", "nope"])
      assert stderr =~ "Unknown command: nope"
    end

    test "--help after a subcommand prints that subcommand's help and exits 0" do
      for flag <- ["--help", "-h"] do
        assert {0, stdout, ""} = invoke(["run", flag])
        assert stdout =~ "tiny_ci run [NAME] [options]"
      end
    end

    test "--no-color turns IO.ANSI.enabled?/0 off, wherever it appears" do
      for argv <- [["--no-color", "version"], ["version", "--no-color"]] do
        Application.put_env(:elixir, :ansi_enabled, true)
        assert IO.ANSI.enabled?()

        assert {0, _stdout, ""} = invoke(argv)
        refute IO.ANSI.enabled?()
      end
    end

    test "--no-color is not passed on to the subcommand" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"fake", FakeSub}])

      assert {0, stdout, ""} = invoke(["fake", "--no-color", "x"])
      assert stdout =~ ~s(fake ran ["x"])
    end
  end

  describe "exit_code/1" do
    test ":ok is 0" do
      assert CLI.exit_code(:ok) == 0
    end

    test "a usage error is 2" do
      assert CLI.exit_code({:error, {:usage, "nope"}}) == 2
    end

    test "any other error is 1" do
      assert CLI.exit_code({:error, {:failed, "nope"}}) == 1
      assert CLI.exit_code({:error, :pipeline_failed}) == 1
    end
  end

  describe "subcommand registry (:cli_subcommands)" do
    setup do
      Application.put_env(:tiny_ci, :cli_subcommands, [
        {"fake", FakeSub},
        {"usage", UsageSub},
        {"failing", FailedSub}
      ])
    end

    test "a registered subcommand is dispatched with the remaining arguments" do
      assert {0, stdout, ""} = invoke(["fake", "a", "--b"])
      assert stdout =~ ~s(fake ran ["a", "--b"])
    end

    test "registered subcommands are listed in help after the built-ins" do
      assert {0, stdout, ""} = invoke(["help"])
      assert stdout =~ ~r/^  fake\s+A fake subcommand registered for tests\./m
      assert stdout =~ ~r/^  usage\s+Always a usage error\./m

      {run_at, _} = :binary.match(stdout, "  run ")
      {fake_at, _} = :binary.match(stdout, "  fake ")
      assert run_at < fake_at
    end

    test "an extra shadowed by a built-in is listed once, as the built-in" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"run", FakeSub}, {"fake", FakeSub}])

      assert {0, stdout, ""} = invoke(["help"])
      assert length(Regex.scan(~r/^  run\s/m, stdout)) == 1
      assert stdout =~ ~r/^  run\s+Discovers/m
      assert stdout =~ ~r/^  fake\s/m
    end

    test "help SUBCOMMAND reaches a registered subcommand" do
      assert {0, stdout, ""} = invoke(["help", "fake"])
      assert stdout =~ "Usage: tiny_ci fake"
    end

    test "a built-in wins over an extra of the same name" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"run", FakeSub}])

      assert {0, stdout, ""} = invoke(["run", "--help"])
      refute stdout =~ "fake ran"
      assert stdout =~ "tiny_ci run [NAME] [options]"
    end

    test "{:error, {:usage, msg}} prints msg and a help hint to stderr, and exits 2" do
      assert {2, "", stderr} = invoke(["usage"])
      assert stderr =~ "bad flag --zzz"
      assert stderr =~ "tiny_ci help usage"
    end

    test "{:error, {:failed, msg}} prints msg to stderr and exits 1" do
      assert {1, "", stderr} = invoke(["failing"])
      assert stderr =~ "it went wrong"
    end

    test "any other error exits 1 and prints nothing (the subcommand already did)" do
      assert {1, "", ""} = invoke(["failing", "opaque"])
    end
  end

  describe "global flags stop at --" do
    @describetag :tmp_dir

    test "--no-color after a -- is an argument, not a flag", %{tmp_dir: tmp} do
      Application.put_env(:elixir, :ansi_enabled, true)

      assert {1, "", stderr} = invoke(["run", "--root", tmp, "--", "--no-color"])
      assert String.replace(stderr, ~r/\e\[[0-9;]*m/, "") =~ "Pipeline not found: --no-color"
      assert IO.ANSI.enabled?()
    end

    test "--no-color before a -- still works", %{tmp_dir: tmp} do
      Application.put_env(:elixir, :ansi_enabled, true)

      assert {1, "", _stderr} = invoke(["run", "--no-color", "--root", tmp, "--", "x"])
      refute IO.ANSI.enabled?()
    end

    test "a subcommand receives everything after -- untouched" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"fake", FakeSub}])

      assert {0, stdout, ""} = invoke(["fake", "--", "--no-color"])
      assert stdout =~ ~s(fake ran ["--", "--no-color"])

      assert {0, stdout, ""} = invoke(["fake", "--no-color", "a", "--", "--no-color", "b"])
      assert stdout =~ ~s(fake ran ["a", "--", "--no-color", "b"])
    end
  end

  describe "help alignment" do
    # {name_start, summary_column} for each line of the Commands section.
    defp command_columns(stdout) do
      stdout
      |> String.split("\n")
      |> Enum.drop_while(&(&1 != "Commands:"))
      |> Enum.drop(1)
      |> Enum.take_while(&(&1 != ""))
      |> Enum.map(fn line ->
        [_, name, gap] = Regex.run(~r/^  (\S+)( +)/, line)
        {name, 2 + String.length(name) + String.length(gap), String.length(gap)}
      end)
    end

    test "with only the built-ins, summaries start in one column, two spaces after the longest" do
      assert {0, stdout, ""} = invoke(["help"])
      columns = command_columns(stdout)

      assert Enum.uniq(for {_name, column, _gap} <- columns, do: column) == [11]
      assert length(columns) == 7
    end

    test "a long extra name widens the column for every command" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"abcdefghijkl", FakeSub}])

      assert {0, stdout, ""} = invoke(["help"])
      columns = command_columns(stdout)

      assert Enum.uniq(for {_name, column, _gap} <- columns, do: column) == [16]
      assert Enum.all?(columns, fn {_name, _column, gap} -> gap >= 2 end)
      assert stdout =~ "  abcdefghijkl  A fake subcommand registered for tests."
    end
  end

  describe "the registry is read once per invocation" do
    # A process cannot receive its own trace messages, so a helper process is the tracer.
    # It answers `{:count, from, module}` only after every earlier trace message, which
    # `:erlang.trace_delivered/1` guarantees have reached it.
    defp tracer(counts \\ []) do
      receive do
        {:trace, _pid, :call, {Code, :ensure_loaded?, [module]}} ->
          tracer([module | counts])

        {:trace, _pid, _kind, _info} ->
          tracer(counts)

        {:count, from, module} ->
          send(from, {:count, Enum.count(counts, &(&1 == module))})
      end
    end

    defp count_loads(argv, module) do
      tracer = spawn_link(fn -> tracer() end)
      :erlang.trace(self(), true, [:call, {:tracer, tracer}])
      :erlang.trace_pattern({Code, :ensure_loaded?, 1}, true, [:local])

      try do
        invoke(argv)
      after
        :erlang.trace_pattern({Code, :ensure_loaded?, 1}, false, [:local])
        :erlang.trace(self(), false, [:call])
      end

      ref = :erlang.trace_delivered(self())

      receive do
        {:trace_delivered, _, ^ref} -> :ok
      end

      send(tracer, {:count, self(), module})

      receive do
        {:count, count} -> count
      end
    end

    test "version, help, a failing run, an unknown command and an extra each validate it once" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"fake", FakeSub}])

      for argv <- [["version"], ["help"], ["run", "--bogus"], ["nope"], ["fake", "x"]] do
        loads = count_loads(argv, FakeSub)
        assert loads == 1, "#{inspect(argv)} validated the registry #{loads} times, not once"
      end
    end
  end

  describe "extra results of any shape never crash the dispatcher" do
    setup do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"odd", BadMessageSub}])
    end

    test "an atom, a tuple, nil, a charlist and iodata all render as a readable line" do
      assert {1, "", stderr} = invoke(["odd", "failed_atom"])
      assert stderr =~ ":oops"

      assert {1, "", stderr} = invoke(["odd", "failed_tuple"])
      assert stderr =~ "{:a, 1}"

      assert {2, "", stderr} = invoke(["odd", "usage_nil"])
      assert stderr =~ "nil"
      assert stderr =~ "tiny_ci help odd"

      assert {2, "", stderr} = invoke(["odd", "usage_charlist"])
      assert stderr =~ "charlist message"

      assert {1, "", stderr} = invoke(["odd", "failed_iodata"])
      assert stderr =~ "iodata!"
    end

    test "invalid chardata falls back to inspect" do
      assert {1, "", stderr} = invoke(["odd", "failed_bad_iodata"])
      assert stderr =~ "ok"
    end

    test "a binary that is not valid UTF-8 is inspected rather than crashing" do
      assert {1, "", stderr} = invoke(["odd", "failed_invalid_utf8"])
      assert stderr =~ "<<255>>"

      assert {1, "", stderr} = invoke(["odd", "failed_invalid_multiline"])
      assert stderr =~ "<<111, 107, 10, 255>>"
    end

    test "a multi-line binary is still printed as is" do
      assert {1, "", stderr} = invoke(["odd", "failed_multiline"])
      assert stderr =~ "first line\nsecond line"
    end
  end

  describe "registry warning size" do
    test "a config of huge bad entries produces a small warning" do
      huge = String.duplicate("x", 50_000)
      map = Map.new(1..1000, &{&1, huge})
      Application.put_env(:tiny_ci, :cli_subcommands, [huge, map, {huge, huge}, {1, map}, [map]])

      assert {0, _stdout, stderr} = invoke(["version"])
      assert warnings(stderr) == 1
      assert byte_size(stderr) < 2048
    end

    test "a huge value that is not even a list is bounded too" do
      Application.put_env(
        :tiny_ci,
        :cli_subcommands,
        Map.new(1..1000, &{&1, String.duplicate("y", 5000)})
      )

      assert {0, _stdout, stderr} = invoke(["version"])
      assert byte_size(stderr) < 2048
    end
  end

  describe "registry rules" do
    test "an extra named like a built-in is dropped silently, whatever its module" do
      Application.put_env(:tiny_ci, :cli_subcommands, [
        {"run", TinyCI.CLITest.NoSuchModule},
        {"help", FakeSub},
        {"version", TinyCI.CLITest.NoSuchModule}
      ])

      assert {0, _stdout, ""} = invoke(["help"])
      assert {0, "tiny_ci " <> _, ""} = invoke(["version"])
      assert {2, "", stderr} = invoke(["run", "--bogus"])
      assert stderr =~ "Invalid option(s): --bogus"
      refute stderr =~ "malformed"
    end

    test "an improper list is malformed: one warning, no extras" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"fake", FakeSub} | :tail])

      assert {0, stdout, stderr} = invoke(["help"])
      refute stdout =~ "fake"
      assert warnings(stderr) == 1
      assert stderr =~ "(not a proper list)"
    end

    test "a value that is not a list says so" do
      Application.put_env(:tiny_ci, :cli_subcommands, :notalist)

      assert {0, "tiny_ci " <> _, stderr} = invoke(["version"])
      assert stderr =~ ":notalist (not a list)"
    end

    test "three small bad entries are printed whole, each with its reason" do
      Application.put_env(:tiny_ci, :cli_subcommands, [:a, "b", {:c, FakeSub}])

      assert {0, _stdout, stderr} = invoke(["version"])
      assert stderr =~ ":a (not a {name, module} tuple); "
      assert stderr =~ ~s|"b" (not a {name, module} tuple); |
      assert stderr =~ "{:c, TinyCI.CLITest.FakeSub} (not a {name, module} tuple)"
      refute stderr =~ "more)"
    end

    test "many bad entries are summarised" do
      Application.put_env(:tiny_ci, :cli_subcommands, Enum.to_list(1..20))

      assert {0, _stdout, stderr} = invoke(["version"])
      assert stderr =~ "(and 12 more)"
      assert warnings(stderr) == 1
    end

    test "duplicate names: the first wins, and the duplicate is reported in the one warning" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"fake", FakeSub}, {"fake", UsageSub}])

      assert {0, stdout, stderr} = invoke(["fake", "x"])
      assert stdout =~ ~s(fake ran ["x"])
      assert warnings(stderr) == 1
      assert stderr =~ "UsageSub"

      assert {0, stdout, stderr} = invoke(["help"])
      assert length(Regex.scan(~r/^  fake\s/m, stdout)) == 1
      assert stderr =~ "UsageSub} (duplicate name)"
    end

    test "names starting with - can never be dispatched, so they are dropped with a warning" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"--help", FakeSub}, {"-x", FakeSub}])

      assert {0, stdout, stderr} = invoke(["help"])
      refute stdout =~ "-x"
      assert warnings(stderr) == 1
      assert stderr =~ ~s|{"--help", TinyCI.CLITest.FakeSub} (invalid name)|
      assert stderr =~ ~s|{"-x", TinyCI.CLITest.FakeSub} (invalid name)|
    end

    test "a module that cannot be loaded is dropped with a warning, not listed" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"ghost", TinyCI.CLITest.NoSuchModule}])

      assert {0, stdout, stderr} = invoke(["help"])
      refute stdout =~ "ghost"
      assert warnings(stderr) == 1
      assert stderr =~ "NoSuchModule} (unloadable module)"

      assert {2, "", stderr} = invoke(["ghost"])
      assert stderr =~ "Unknown command: ghost"
    end

    test "an extra shadowed by a built-in is dropped silently" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"run", FakeSub}])

      assert {0, _stdout, ""} = invoke(["help"])
    end
  end

  describe "a malformed :cli_subcommands never affects the built-ins" do
    defp warnings(stderr), do: length(Regex.scan(~r/ignoring malformed :cli_subcommands/, stderr))

    test "a value that is not a list is ignored, with one warning" do
      Application.put_env(:tiny_ci, :cli_subcommands, :notalist)

      assert {2, "", stderr} = invoke(["run", "--bogus"])
      assert stderr =~ "Invalid option(s): --bogus"
      assert warnings(stderr) == 1
    end

    test "bad entries are dropped with one warning, and good entries still work" do
      Application.put_env(:tiny_ci, :cli_subcommands, [:atom_entry, "str", {"fake", FakeSub}])

      assert {0, stdout, stderr} = invoke(["fake", "x"])
      assert stdout =~ ~s(fake ran ["x"])
      assert warnings(stderr) == 1
      assert stderr =~ ":atom_entry (not a {name, module} tuple)"
      assert stderr =~ ~s|"str" (not a {name, module} tuple)|
    end

    test "an entry whose name is not a string is dropped, and help still works" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{:fake, FakeSub}, {"", FakeSub}])

      assert {0, stdout, stderr} = invoke(["help"])
      assert stdout =~ ~r/^  run\s/m
      refute stdout =~ "fake"
      assert warnings(stderr) == 1
    end

    test "an extra whose help/0 raises or is not a string is listed without a description" do
      Application.put_env(:tiny_ci, :cli_subcommands, [
        {"boom", RaisingHelpSub},
        {"odd", NonBinaryHelpSub}
      ])

      assert {0, stdout, ""} = invoke(["help"])
      assert stdout =~ ~r/^  run\s/m
      assert stdout =~ ~r/^  boom\s+\(no description\)/m
      assert stdout =~ ~r/^  odd\s+\(no description\)/m
    end

    test "the unknown-command path does not raise because of an extra" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"boom", RaisingHelpSub}])

      assert {2, "", stderr} = invoke(["nope"])
      assert stderr =~ "Unknown command: nope"
    end

    test "help for an extra whose help/0 raises does not raise" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"boom", RaisingHelpSub}])

      assert {0, stdout, ""} = invoke(["help", "boom"])
      assert stdout =~ "No help available"
    end

    test "an extra whose run/1 returns neither :ok nor {:error, _} exits 1 with a message" do
      Application.put_env(:tiny_ci, :cli_subcommands, [{"nilly", NilRunSub}])

      assert {1, "", stderr} = invoke(["nilly"])
      assert stderr =~ "tiny_ci: subcommand nilly returned an unexpected result: nil"
    end
  end

  test "lib/tiny_ci/cli has no Mix references" do
    files = ["lib/tiny_ci/cli.ex" | Path.wildcard("lib/tiny_ci/cli/**/*.ex")]

    for file <- files do
      refute File.read!(file) =~ ~r/\bMix\./, "#{file} references Mix"
    end
  end
end
