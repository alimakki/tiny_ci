defmodule TinyCI.CLI.Subcommand do
  @moduledoc """
  The contract between the `tiny_ci` dispatcher and one subcommand.

  The dispatcher (`TinyCI.CLI`) owns argument routing, exit codes, and the
  top-level help. A subcommand owns everything after its own name. Sibling
  applications (a server, a runner) register extra subcommands under the
  `:cli_subcommands` key of the `:tiny_ci` application environment, so the core
  never has to depend on them:

      config :tiny_ci, :cli_subcommands, [{"serve", MyApp.CLI.Serve}]

  ## Registration rules

    * A name is a non-empty binary that does not start with `-` (`--help` and friends
      are handled before any lookup, so such a name could never be dispatched).
      Names with whitespace are allowed but cannot be typed as one word.
    * The module must be loadable (`Code.ensure_loaded?/1`). It is not otherwise
      checked: a module without `help/0` is listed as "(no description)".
    * A built-in command (`run`, `runs`, `cache`, `attest`, `actions`), `version` and
      `help` always win. An extra registered under one of those names is silently
      dropped.
    * If a name is registered twice, the first entry wins.
    * The value must be a proper list of `{name, module}` tuples. Anything else, a bad
      entry, or a duplicate is ignored, and **one** warning per `tiny_ci` invocation
      goes to stderr listing everything ignored. Malformed configuration never affects
      the built-in commands.

  ## Results

  `c:run/1` returns `:ok` or `{:error, reason}`, and never halts the VM. The
  shape of `reason` decides what the dispatcher prints and which exit code it
  returns:

    * `{:usage, message}` — the arguments were wrong. The dispatcher prints
      `message` and a pointer to `tiny_ci help <command>` on stderr, exit code `2`.
    * `{:failed, message}` — the command ran and failed. The dispatcher prints
      `message` on stderr, exit code `1`.
    * any other `{:error, reason}` — the command failed and has already printed its
      own diagnostics. Exit code `1`, nothing more is printed.
    * any other return value breaks this contract. The dispatcher prints
      "subcommand NAME returned an unexpected result" on stderr and exits `1`.

  `message` should be a binary. Other chardata is flattened and anything else is
  `inspect`ed, so a careless message is still printed rather than crashing the CLI.

  A `run/1` that raises is not caught: the subcommand crashes itself.
  """

  @doc "Runs the subcommand with the arguments that followed its name."
  @callback run(args :: [String.t()]) :: :ok | {:error, term()}

  @doc """
  The subcommand's help text. The first line is a one-sentence summary; it is what
  `tiny_ci help` lists next to the command name.
  """
  @callback help() :: String.t()
end
