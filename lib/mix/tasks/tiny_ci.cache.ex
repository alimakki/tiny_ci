defmodule Mix.Tasks.TinyCi.Cache do
  @shortdoc "Manages the TinyCI dependency cache"

  @moduledoc """
  Manages the local TinyCI dependency cache.

  ## Usage

      mix tiny_ci.cache COMMAND [options]

  ## Commands

    * `clean [--root DIR]` — removes all cache entries for the project root
    * `prune [--max-bytes N] [--max-age-days N]` — evicts entries unused for
      longer than the age limit, then least-recently-used entries until the
      cache is under the size limit (defaults: 30 days, 5 GiB; see
      `TinyCI.Cache.prune/1` for the environment overrides)
    * `stats` — prints entry count, total size, and project count

  ## Examples

      mix tiny_ci.cache clean
      mix tiny_ci.cache clean --root /path/to/project
      mix tiny_ci.cache prune --max-bytes 1073741824 --max-age-days 7
      mix tiny_ci.cache stats
  """

  use Mix.Task

  alias TinyCI.Cache

  @impl Mix.Task
  def run(["clean" | args]) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [root: :string], aliases: [r: :root])

    root = opts[:root] || File.cwd!()
    Cache.clean(root)
    print_ok("Cache cleared for project: #{root}")
  end

  def run(["prune" | args]) do
    {opts, _, _} =
      OptionParser.parse(args, switches: [max_bytes: :integer, max_age_days: :integer])

    %{removed: removed, bytes_freed: freed} =
      Cache.prune(Keyword.take(opts, [:max_bytes, :max_age_days]))

    print_ok("Removed #{plural(removed, "entry", "entries")}, freed #{format_bytes(freed)}")
  end

  def run(["stats"]) do
    %{entries: entries, bytes: bytes, projects: projects} = Cache.stats()

    IO.puts(
      "#{plural(entries, "entry", "entries")}, #{format_bytes(bytes)}, " <>
        "#{plural(projects, "project", "projects")} in #{Cache.base_dir()}"
    )
  end

  def run(_) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Unknown or missing command.",
      IO.ANSI.reset(),
      "\n\nUsage: mix tiny_ci.cache clean [--root DIR] | prune [--max-bytes N] [--max-age-days N] | stats"
    ])

    if Mix.env() != :test, do: System.halt(1)
  end

  defp print_ok(message) do
    IO.puts([IO.ANSI.green(), "✓ ", IO.ANSI.reset(), message])
  end

  defp plural(1, singular, _plural), do: "1 #{singular}"
  defp plural(n, _singular, plural), do: "#{n} #{plural}"

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1024 * 1024, do: "#{Float.round(bytes / 1024, 1)} KiB"

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024,
    do: "#{Float.round(bytes / (1024 * 1024), 1)} MiB"

  defp format_bytes(bytes), do: "#{Float.round(bytes / (1024 * 1024 * 1024), 2)} GiB"
end
