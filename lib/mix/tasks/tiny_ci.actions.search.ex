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
  """

  use Mix.Task

  alias TinyCI.Registry
  alias TinyCI.Registry.Entry

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [index: :string, capability: :string, tier: :string],
        aliases: [i: :index, c: :capability, t: :tier]
      )

    term = List.first(positional)

    result =
      case Registry.search(term, search_opts(opts)) do
        {:ok, entries} ->
          print_results(term, entries)
          :ok

        {:error, reason} ->
          {:error, reason}
      end

    finish(result)
  end

  defp search_opts(opts) do
    []
    |> put_opt(:index, opts[:index])
    |> put_opt(:capability, atomize(opts[:capability]))
    |> put_opt(:tier, atomize(opts[:tier]))
  end

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)

  defp atomize(nil), do: nil
  defp atomize(value), do: String.to_atom(value)

  defp print_results(term, []) do
    IO.puts("No actions found#{for_term(term)}.")
    IO.puts("Try a broader term, or generate an index with `mix tiny_ci.actions.index`.")
  end

  defp print_results(term, entries) do
    IO.puts("#{length(entries)} action(s)#{for_term(term)}:\n")
    Enum.each(entries, &print_entry/1)
  end

  defp print_entry(%Entry{} = entry) do
    version = entry.version || "—"

    IO.puts([
      "  ",
      IO.ANSI.bright(),
      entry.name,
      IO.ANSI.reset(),
      "  #{version}  ",
      tier_badge(entry.tier)
    ])

    IO.puts("      #{entry.package} — #{inspect(entry.module)}")
    IO.puts("      caps: #{capabilities(entry.capabilities)}")
    if entry.summary, do: IO.puts("      #{entry.summary}")
    IO.puts("")
  end

  defp for_term(nil), do: ""
  defp for_term(term), do: " matching #{inspect(term)}"

  defp capabilities([]), do: "none"
  defp capabilities(caps), do: Enum.map_join(caps, ", ", &to_string/1)

  defp tier_badge(:verified), do: [IO.ANSI.green(), "[verified]", IO.ANSI.reset()]
  defp tier_badge(:community), do: [IO.ANSI.cyan(), "[community]", IO.ANSI.reset()]
  defp tier_badge(tier), do: [IO.ANSI.faint(), "[#{tier}]", IO.ANSI.reset()]

  defp finish(:ok), do: halt(0)

  defp finish({:error, reason}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Search failed: #{inspect(reason)}", IO.ANSI.reset()])
    halt(1)
  end

  defp halt(code) do
    if Mix.env() != :test, do: System.halt(code)
    if code == 0, do: :ok, else: {:error, :search_failed}
  end
end
