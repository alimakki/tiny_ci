defmodule Mix.Tasks.TinyCi.Cache do
  @shortdoc "Manages the TinyCI dependency cache"

  @moduledoc TinyCI.CLI.Cache.help("mix tiny_ci.cache") <>
               """

               ## Standalone

               The same command is available without Mix as `tiny_ci cache`
               (see `TinyCI.CLI`).
               """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    args
    |> TinyCI.CLI.Cache.run()
    |> MixDelegate.halt_unless_test(:cache_failed, halt_on_ok: false)
  end
end
