defmodule TinyCI.CLI do
  @moduledoc """
  The `tiny_ci` command line: one entrypoint, many subcommands.

  This is the escript's `main_module`, and what a standalone binary wraps. The
  `mix tiny_ci.*` tasks are thin delegates to the same subcommand modules, so the
  two front ends cannot drift apart.

  ## Usage

      tiny_ci <command> [options]
      tiny_ci help [command]
      tiny_ci version

  ## Global options

    * `--no-color` — treat the terminal as non-interactive: no live output streaming
      and no breakpoint prompt. Colour escape codes in console output are not yet
      removed. Accepted anywhere in the arguments before a `--`.
    * `--version` — same as `tiny_ci version`
    * `--help` / `-h` — top-level help; after a command, that command's help

  ## Exit codes

    * `0` — success
    * `1` — a pipeline or command failed
    * `2` — usage error: unknown command, bad flag, missing argument

  ## Extending

  Extra subcommands are registered in the application environment, so the core
  never depends on the apps that provide them. See `TinyCI.CLI.Subcommand`.
  """

  alias TinyCI.CLI.{Actions, Attest, Cache, Run, Runs}

  @builtins [
    {"run", Run},
    {"runs", Runs},
    {"cache", Cache},
    {"attest", Attest},
    {"actions", Actions}
  ]

  # Names an extra can never take: the built-ins, and the two handled by the dispatcher.
  @reserved ["version", "help" | Enum.map(@builtins, &elem(&1, 0))]

  @doc """
  Runs the command line and halts the VM with its exit code. This is the escript
  entrypoint; tests call `run/1`, which does not halt.
  """
  @spec main([String.t()]) :: no_return()
  def main(argv) do
    argv |> run() |> System.halt()
  end

  @doc """
  Runs the command line and returns its exit code (`0`, `1`, or `2`) without
  halting. Output goes to the current group leader and stderr as usual.
  """
  @spec run([String.t()]) :: 0 | 1 | 2
  def run(argv) do
    # Read and validate the registry exactly once per invocation; everything below
    # (dispatch, help, the unknown-command message) is handed the result.
    {extras, bad} = registry()
    warn_malformed(bad)

    argv
    |> apply_global_flags()
    |> dispatch(extras)
    |> finish(extras)
  end

  @doc """
  Maps a subcommand result to a process exit code.

  ## Examples

      iex> TinyCI.CLI.exit_code(:ok)
      0

      iex> TinyCI.CLI.exit_code({:error, {:usage, "unknown flag"}})
      2

      iex> TinyCI.CLI.exit_code({:error, {:failed, "run not found"}})
      1

      iex> TinyCI.CLI.exit_code({:error, :pipeline_failed})
      1
  """
  @spec exit_code(:ok | {:error, term()}) :: 0 | 1 | 2
  def exit_code(:ok), do: 0
  def exit_code({:error, {:usage, _message}}), do: 2
  def exit_code({:error, _reason}), do: 1

  @doc false
  # The one place `--no-color` takes effect, for the dispatcher and for
  # `TinyCI.CLI.Run` (which the Mix task calls without the dispatcher).
  @spec disable_color() :: :ok
  def disable_color, do: Application.put_env(:elixir, :ansi_enabled, false)

  # ---------------------------------------------------------------------------
  # Global flags
  # ---------------------------------------------------------------------------

  # `--no-color` is global: it is removed from the arguments before the first `--` so
  # subcommands (which parse strictly) never see it. Everything after a `--` is an
  # argument and is passed through untouched.
  defp apply_global_flags(argv) do
    {flags, rest} = Enum.split_while(argv, &(&1 != "--"))

    case Enum.reject(flags, &(&1 == "--no-color")) do
      ^flags ->
        argv

      stripped ->
        disable_color()
        stripped ++ rest
    end
  end

  # ---------------------------------------------------------------------------
  # Dispatch
  # ---------------------------------------------------------------------------

  defp dispatch([], _extras), do: {:top_usage, nil}
  defp dispatch(["version" | _], _extras), do: print_version()
  defp dispatch(["--version" | _], _extras), do: print_version()
  defp dispatch([flag | _], extras) when flag in ["--help", "-h"], do: print_top_help(extras)
  defp dispatch(["help"], extras), do: print_top_help(extras)

  defp dispatch(["help", flag | _], extras) when flag in ["--help", "-h"],
    do: print_top_help(extras)

  defp dispatch(["help", "version" | _], _extras),
    do: print_meta_help("version", "Prints the tiny_ci version.")

  defp dispatch(["help", "help" | _], _extras),
    do: print_meta_help("help [command]", "Prints help for tiny_ci, or for one command.")

  defp dispatch(["help", name | _], extras),
    do: with_subcommand(name, extras, &print_help/2)

  defp dispatch([name | args], extras),
    do: with_subcommand(name, extras, &run_subcommand(&1, &2, args))

  defp with_subcommand(name, extras, fun) do
    case lookup(name, extras) do
      {:ok, module} -> {name, fun.(name, module)}
      :error -> {:top_usage, "Unknown command: #{name}"}
    end
  end

  defp run_subcommand(name, module, args) do
    if help_requested?(args) do
      print_help(name, module)
    else
      checked(name, module.run(args))
    end
  end

  # Everything after a `--` is an argument, not a flag. (A `-h` that is the *value* of
  # a string switch cannot be told apart without each subcommand's switch table.)
  defp help_requested?(args) do
    args |> Enum.take_while(&(&1 != "--")) |> Enum.any?(&(&1 in ["--help", "-h"]))
  end

  defp print_meta_help(usage, description) do
    IO.puts("#{description}\n\nUsage: tiny_ci #{usage}")
    {nil, :ok}
  end

  # A registered extra is outside our control: a result that is not part of the
  # `Subcommand` contract is reported and fails the command, never raised.
  defp checked(_name, :ok), do: :ok
  defp checked(_name, {:error, _reason} = error), do: error

  defp checked(name, other) do
    IO.puts(
      :stderr,
      "tiny_ci: subcommand #{name} returned an unexpected result: #{inspect(other)}"
    )

    {:error, :unexpected_result}
  end

  defp print_help(_name, module) do
    IO.puts(help_text(module) || "No help available for this command.")
    :ok
  end

  # `module.help()` as a binary, or nil if the module raises or returns something else.
  defp help_text(module) do
    case module.help() do
      text when is_binary(text) -> text
      _other -> nil
    end
  rescue
    _error -> nil
  catch
    _kind, _reason -> nil
  end

  defp print_version do
    IO.puts("tiny_ci #{TinyCI.Project.version()}")
    {nil, :ok}
  end

  defp print_top_help(extras) do
    IO.puts(top_help(extras))
    {nil, :ok}
  end

  # Built-ins first, so an extra can never shadow one.
  defp lookup(name, extras) do
    case List.keyfind(@builtins ++ extras, name, 0) do
      {^name, module} -> {:ok, module}
      nil -> :error
    end
  end

  # `{usable extras, problems}` for the registered `:cli_subcommands` (see
  # `TinyCI.CLI.Subcommand`). This must never raise: a config mistake in a sibling app
  # cannot be allowed to take the built-ins down. Problems are malformed entries and
  # duplicates, reported once per invocation. An extra shadowed by a built-in is
  # dropped silently, whatever its module.
  defp registry do
    case Application.get_env(:tiny_ci, :cli_subcommands, []) do
      list when is_list(list) -> classify_registry(list)
      other -> {[], [{other, "not a list"}]}
    end
  end

  defp classify_registry(list) do
    if proper_list?(list) do
      {good, bad, _seen} = Enum.reduce(list, {[], [], []}, &classify_entry/2)
      {Enum.reverse(good), Enum.reverse(bad)}
    else
      {[], [{list, "not a proper list"}]}
    end
  end

  defp proper_list?([]), do: true
  defp proper_list?([_head | tail]), do: proper_list?(tail)
  defp proper_list?(_improper), do: false

  defp classify_entry({name, _module}, acc) when name in @reserved, do: acc

  defp classify_entry(entry, {good, bad, seen}) do
    case entry_problem(entry) do
      nil -> add_entry(entry, {good, bad, seen})
      problem -> {good, [{entry, problem} | bad], seen}
    end
  end

  defp add_entry({name, _module} = entry, {good, bad, seen}) do
    if name in seen do
      {good, [{entry, "duplicate name"} | bad], seen}
    else
      {[entry | good], bad, [name | seen]}
    end
  end

  # Why an entry cannot be used, or nil. A name that starts with `-` could never be
  # dispatched (`--help`, `--version` are handled first); a module that cannot be
  # loaded would only crash on dispatch.
  defp entry_problem({name, module}) when is_binary(name) and is_atom(module) do
    cond do
      name == "" or String.starts_with?(name, "-") -> "invalid name"
      not Code.ensure_loaded?(module) -> "unloadable module"
      true -> nil
    end
  end

  defp entry_problem(_entry), do: "not a {name, module} tuple"

  # One warning per invocation, however many entries are bad. The terms are user
  # config of unknown size, so the number of entries shown and the length of each are
  # capped (a few small entries are printed whole).
  @warn_entries 8
  @warn_entry_chars 120

  defp warn_malformed([]), do: :ok

  defp warn_malformed(bad) do
    {shown, rest} = Enum.split(bad, @warn_entries)
    details = Enum.map_join(shown, "; ", &describe_bad/1)
    more = if rest == [], do: "", else: " (and #{length(rest)} more)"
    IO.puts(:stderr, "tiny_ci: ignoring malformed :cli_subcommands entry: #{details}#{more}")
  end

  defp describe_bad({entry, problem}) do
    text = inspect(entry, limit: 20, printable_limit: 80)

    text =
      if String.length(text) > @warn_entry_chars,
        do: String.slice(text, 0, @warn_entry_chars) <> "...",
        else: text

    "#{text} (#{problem})"
  end

  # ---------------------------------------------------------------------------
  # Results and exit codes
  # ---------------------------------------------------------------------------

  defp finish({:top_usage, nil}, extras) do
    IO.puts(:stderr, top_help(extras))
    2
  end

  defp finish({:top_usage, message}, extras) do
    print_error(message)
    IO.puts(:stderr, ["\n", top_help(extras)])
    2
  end

  defp finish({name, {:error, {:usage, message}} = result}, _extras) when is_binary(name) do
    print_error(message)
    IO.puts(:stderr, "Run `tiny_ci help #{name}` for usage.")
    exit_code(result)
  end

  defp finish({_name, {:error, {:failed, message}} = result}, _extras) do
    print_error(message)
    exit_code(result)
  end

  defp finish({_name, result}, _extras), do: exit_code(result)

  @doc false
  # Prints an error message to stderr, coloured red on its first line only (the
  # rest of a multi-line message is usage detail). Shared with the Mix delegate so
  # both front ends print identically.
  @spec print_error(term()) :: :ok
  def print_error(message) do
    case message |> message_to_string() |> String.split("\n", parts: 2) do
      [line] -> IO.puts(:stderr, IO.ANSI.format([:red, line]))
      [line, rest] -> IO.puts(:stderr, [IO.ANSI.format([:red, line]), "\n", rest])
    end
  end

  # A registered extra decides the message, so it may be anything. Binaries print as
  # they are, other chardata is flattened, and whatever remains is inspected.
  defp message_to_string(message) when is_binary(message) do
    if String.valid?(message),
      do: message,
      else: inspect(message, limit: 20, printable_limit: 200)
  end

  defp message_to_string(message) do
    IO.chardata_to_string(message)
  rescue
    _error -> inspect(message, limit: 20, printable_limit: 200)
  end

  # ---------------------------------------------------------------------------
  # Help
  # ---------------------------------------------------------------------------

  defp top_help(extras) do
    """
    tiny_ci #{TinyCI.Project.version()}

    Usage: tiny_ci <command> [options]

    Commands:
    #{command_lines(extras)}

    Global options:
      --no-color     treat the terminal as non-interactive (no live streaming, no
                     breakpoint prompt); colour codes are not yet removed
      --version      print the version
      -h, --help     print help; after a command, that command's help

    Run `tiny_ci help <command>` for a command's options.\
    """
  end

  defp command_lines(extras) do
    builtin = for {name, module} <- @builtins, do: {name, summary(module)}
    own = [{"version", "Prints the tiny_ci version"}, {"help", "Prints help for a command"}]
    extra = for {name, module} <- extras, do: {name, summary(module)}
    listed = builtin ++ own ++ extra

    # Summaries start two spaces after the longest listed name.
    width = listed |> Enum.map(fn {name, _summary} -> String.length(name) end) |> Enum.max()

    Enum.map_join(listed, "\n", fn {name, summary} ->
      "  " <> String.pad_trailing(name, width + 2) <> summary
    end)
  end

  defp first_line(text) do
    case text |> String.split("\n", parts: 2) |> hd() |> String.trim() do
      "" -> "(no description)"
      line -> line
    end
  end

  defp summary(module) do
    case help_text(module) do
      nil -> "(no description)"
      text -> first_line(text)
    end
  end
end
