defmodule Mix.Tasks.TinyCi.Actions.Audit do
  @shortdoc "Prints the resolved action supply-chain tree for a pipeline"

  @moduledoc """
  Resolves every `module:` action a pipeline uses against the project's
  `mix.lock` and prints the result — each action's owning package, version,
  pinned checksum, and supply-chain status.

  Because TinyCI actions are ordinary Hex dependencies, `mix.lock` *is* the
  action lockfile. This command is the reporting layer over that resolution; the
  same check runs automatically at the start of `mix tiny_ci.run`.

  ## Usage

      mix tiny_ci.actions.audit [NAME] [options]

  Pipeline selection mirrors `mix tiny_ci.run`:

    * `--file PATH` / `-f` — audit a specific pipeline file
    * `--root DIR` / `-r` — project root (defaults to the current directory)
    * a `NAME` positional — `.tiny_ci/<NAME>.exs`

  ## Exit codes

    * `0` — every action is locked, first-party, or otherwise sound
    * `1` — a supply-chain problem (an unpinned third-party action, or a build
      that has drifted from the lockfile), or no pipeline file found

  ## Standalone

  The same command is available without Mix as `tiny_ci actions audit`
  (see `TinyCI.CLI`).
  """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    ["audit" | args]
    |> TinyCI.CLI.Actions.run()
    |> MixDelegate.halt_unless_test(:audit_failed)
  end
end
