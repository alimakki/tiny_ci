defmodule TinyCI.CLI.Actions do
  @moduledoc false
  # `tiny_ci actions audit | index | search`, the bodies of the three
  # `mix tiny_ci.actions.*` tasks. The Mix tasks keep their own, longer
  # documentation; `help/0` is the concise group help for the standalone command.
  #
  # These return `:ok` or `{:error, reason}`. On failure they have already printed
  # their diagnostics, so the dispatcher prints nothing more.

  @behaviour TinyCI.CLI.Subcommand

  alias TinyCI.Action.Audit
  alias TinyCI.Discovery
  alias TinyCI.Registry
  alias TinyCI.Registry.{Entry, Index}

  @default_out "actions.json"

  @impl TinyCI.CLI.Subcommand
  def help do
    """
    Audits a pipeline's third-party actions and searches the action registry.

    Usage:

        tiny_ci actions audit [NAME] [--file PATH] [--root DIR]
        tiny_ci actions index [--out PATH] [--overlay PATH]
        tiny_ci actions search [TERM] [--index PATH] [--capability CAP] [--tier TIER]

    Commands:

      * `audit` — resolves every `module:` action the pipeline uses against `mix.lock`
        and prints each action's package, version, checksum, and supply-chain status.
        Exit code 1 on a supply-chain problem.
      * `index` — scans installed packages for self-identified actions and writes a
        static JSON index (default `actions.json`). `--overlay` merges review tiers
        from a curated index.
      * `search` — finds actions by name or summary, from installed packages or from
        an `--index`. `--tier` is one of `verified`, `community`, `unreviewed`.
    """
  end

  @impl TinyCI.CLI.Subcommand
  def run(["audit" | args]), do: audit(args)
  def run(["index" | args]), do: index(args)
  def run(["search" | args]), do: search(args)

  def run(_args),
    do: {:error, {:usage, "Unknown or missing command. Use audit, index, or search."}}

  # ---------------------------------------------------------------------------
  # audit
  # ---------------------------------------------------------------------------

  defp audit(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [file: :string, root: :string],
        aliases: [f: :file, r: :root]
      )

    root = opts[:root] || File.cwd!()

    with {:ok, spec} <- resolve_pipeline(opts, root, List.first(positional)),
         {:ok, entries} <- Audit.analyze(spec, root, root_app: TinyCI.Project.root_app()) do
      IO.puts(Audit.format(entries, lockfile: Audit.lockfile_status(root)))
      if Enum.any?(entries, &(&1.status == :error)), do: {:error, :unsound}, else: :ok
    else
      {:error, reason} -> audit_failed(reason)
    end
  end

  defp resolve_pipeline(opts, root, name) do
    cond do
      opts[:file] -> Discovery.load_pipeline(opts[:file])
      name -> load_named(root, name)
      true -> discover(root)
    end
  end

  defp load_named(root, name) do
    case Discovery.find_pipeline_by_name(root, name) do
      {:ok, path} -> Discovery.load_pipeline(path)
      {:error, :not_found} -> {:error, {:named_not_found, name}}
    end
  end

  defp discover(root) do
    with {:ok, path} <- Discovery.find_pipeline(root), do: Discovery.load_pipeline(path)
  end

  defp audit_failed(:not_found) do
    error("No pipeline file found. Expected tiny_ci.exs or .tiny_ci/pipeline.exs")
  end

  defp audit_failed({:named_not_found, name}) do
    error("Pipeline not found: #{name} (looked for .tiny_ci/#{name}.exs)")
  end

  defp audit_failed(reason), do: error("Error: #{inspect(reason)}")

  # ---------------------------------------------------------------------------
  # index
  # ---------------------------------------------------------------------------

  defp index(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        switches: [out: :string, overlay: :string],
        aliases: [o: :out]
      )

    out = opts[:out] || @default_out

    case build_index(opts[:overlay]) do
      {:ok, index} ->
        File.write!(out, Index.to_json(index))
        report_index(index, out)

      {:error, reason} ->
        error("Index generation failed: #{inspect(reason)}", reason)
    end
  end

  defp build_index(nil), do: {:ok, Registry.scan()}

  defp build_index(overlay_path) do
    with {:ok, overlay} <- Registry.load(overlay_path) do
      {:ok, Index.merge(Registry.scan(), overlay)}
    end
  end

  defp report_index(index, out) do
    count = index |> Index.search(nil) |> length()
    IO.puts([IO.ANSI.green(), "✓ ", IO.ANSI.reset(), "wrote #{count} action(s) to #{out}"])
  end

  # ---------------------------------------------------------------------------
  # search
  # ---------------------------------------------------------------------------

  defp search(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [index: :string, capability: :string, tier: :string],
        aliases: [i: :index, c: :capability, t: :tier]
      )

    term = List.first(positional)

    case Registry.search(term, search_opts(opts)) do
      {:ok, entries} -> print_results(term, entries)
      {:error, reason} -> error("Search failed: #{inspect(reason)}", reason)
    end
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
    IO.puts("Try a broader term, or generate an index with `actions index`.")
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

  # ---------------------------------------------------------------------------
  # shared
  # ---------------------------------------------------------------------------

  # Prints the diagnostic and returns the error for the exit code.
  defp error(message, reason \\ :failed) do
    IO.puts(:stderr, [IO.ANSI.red(), message, IO.ANSI.reset()])
    {:error, reason}
  end
end
