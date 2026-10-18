defmodule Mix.Tasks.TinyCi.Run do
  @shortdoc "Discovers and runs a TinyCI pipeline"

  @moduledoc TinyCI.CLI.Run.help("mix tiny_ci.run") <>
               """

               ## Standalone

               The same command is available without Mix as `tiny_ci run`
               (see `TinyCI.CLI`).
               """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    if Enum.member?(args, "--isolate") do
      IO.puts(
        :stderr,
        "warning: --isolate isolates pipeline steps, but Mix has already loaded this " <>
          "project (including mix.exs). Use the `tiny_ci` escript when the checkout " <>
          "itself is untrusted."
      )
    end

    args
    |> TinyCI.CLI.Run.run()
    |> MixDelegate.raise_on_error("TinyCI run failed")
  end
end
