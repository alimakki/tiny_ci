defmodule Mix.Tasks.TinyCi.Actions.Index do
  @shortdoc "Generates a static JSON index of installed tiny_ci actions"

  @moduledoc """
  Scans locally-installed packages for self-identified actions (those declaring
  a `:tiny_ci_actions` application env) and writes a static JSON index.

  This is the v1 registry: a generated, checkable artifact rather than a live
  service. Pass `--overlay` to layer a curated index (which assigns review
  tiers) on top of the scan — the scan supplies live version and capability
  data, the overlay supplies the tier.

  ## Usage

      mix tiny_ci.actions.index [options]

    * `--out PATH`     — where to write the index (default: `actions.json`)
    * `--overlay PATH` — a curated JSON index to merge tiers from

  ## Exit codes

    * `0` — the index was written
    * `1` — bad input (e.g. an unreadable `--overlay` file)

  ## Standalone

  The same command is available without Mix as `tiny_ci actions index`
  (see `TinyCI.CLI`).
  """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    ["index" | args]
    |> TinyCI.CLI.Actions.run()
    |> MixDelegate.halt_unless_test(:index_failed)
  end
end
