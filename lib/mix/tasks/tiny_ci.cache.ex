defmodule Mix.Tasks.TinyCi.Cache do
  @shortdoc "Manages the TinyCI dependency cache"

  @moduledoc """
  Manages the local TinyCI dependency cache.

  ## Usage

      mix tiny_ci.cache COMMAND [options]

  ## Commands

    * `clean` — removes all cache entries for the current project root

  ## Examples

      # Clear all cache entries for this project
      mix tiny_ci.cache clean

      # Clear cache for a specific project root
      mix tiny_ci.cache clean --root /path/to/project
  """

  use Mix.Task

  alias TinyCI.Cache

  @impl Mix.Task
  def run(["clean" | args]) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [root: :string], aliases: [r: :root])

    root = opts[:root] || File.cwd!()
    Cache.clean(root)

    IO.puts([
      IO.ANSI.green(),
      "✓ ",
      IO.ANSI.reset(),
      "Cache cleared for project: #{root}"
    ])
  end

  def run(_) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Unknown or missing command.",
      IO.ANSI.reset(),
      "\n\nUsage: mix tiny_ci.cache clean [--root DIR]"
    ])

    if Mix.env() != :test, do: System.halt(1)
  end
end
