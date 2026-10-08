defmodule Mix.Tasks.TinyCi.Runs do
  @shortdoc "Lists, shows, and prunes recorded pipeline runs"

  @moduledoc TinyCI.CLI.Runs.help("mix tiny_ci.runs") <>
               """

               ## Standalone

               The same command is available without Mix as `tiny_ci runs`
               (see `TinyCI.CLI`).
               """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)
    args |> TinyCI.CLI.Runs.run() |> MixDelegate.raise_on_error()
  end
end
