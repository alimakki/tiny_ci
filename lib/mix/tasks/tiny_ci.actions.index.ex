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
  """

  use Mix.Task

  alias TinyCI.Registry
  alias TinyCI.Registry.Index

  @default_out "actions.json"

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    {opts, _positional, _invalid} =
      OptionParser.parse(args,
        switches: [out: :string, overlay: :string],
        aliases: [o: :out]
      )

    out = opts[:out] || @default_out

    result =
      with {:ok, index} <- build_index(opts[:overlay]) do
        File.write!(out, Index.to_json(index))
        report(index, out)
        :ok
      end

    finish(result)
  end

  defp build_index(nil), do: {:ok, Registry.scan()}

  defp build_index(overlay_path) do
    with {:ok, overlay} <- Registry.load(overlay_path) do
      {:ok, Index.merge(Registry.scan(), overlay)}
    end
  end

  defp report(index, out) do
    count = index |> Index.search(nil) |> length()
    IO.puts([IO.ANSI.green(), "✓ ", IO.ANSI.reset(), "wrote #{count} action(s) to #{out}"])
  end

  defp finish(:ok), do: halt(0)

  defp finish({:error, reason}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Index generation failed: #{inspect(reason)}",
      IO.ANSI.reset()
    ])

    halt(1)
  end

  defp halt(code) do
    if Mix.env() != :test, do: System.halt(code)
    if code == 0, do: :ok, else: {:error, :index_failed}
  end
end
