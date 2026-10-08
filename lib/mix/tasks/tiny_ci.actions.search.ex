defmodule Mix.Tasks.TinyCi.Actions.Search do
  @shortdoc "Searches the curated tiny_ci action registry"

  @moduledoc """
  Searches the tiny_ci action registry for actions matching a term.

  By default this scans the locally-installed packages that self-identify as
  action providers (via their `:tiny_ci_actions` application env). Pass
  `--index` to search a generated static index instead.

  Each result shows the action's package, version, declared capabilities (its
  blast radius), and review tier.

  ## Usage

      mix tiny_ci.actions.search [TERM] [options]

    * `--index PATH`      — search a JSON index (from `mix tiny_ci.actions.index`)
    * `--capability CAP`  — only actions declaring this capability (e.g. `network`)
    * `--tier TIER`       — only actions at this review tier (`verified`,
      `community`, `unreviewed`)

  ## Exit codes

    * `0` — the search ran (even if nothing matched)
    * `1` — bad input (e.g. an unreadable `--index` file)

  ## Standalone

  The same command is available without Mix as `tiny_ci actions search`
  (see `TinyCI.CLI`).
  """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    ["search" | args]
    |> TinyCI.CLI.Actions.run()
    |> MixDelegate.halt_unless_test(:search_failed)
  end
end
