defmodule Mix.Tasks.TinyCi.Runs do
  @shortdoc "Lists, shows, and prunes recorded pipeline runs"

  @moduledoc """
  Reads the run history that `mix tiny_ci.run` records.

  Every run (except `--dry-run` and `--no-record`) leaves its event stream and a
  summary under the data dir. See `docs/runs.md`.

  ## Usage

      mix tiny_ci.runs [options]
      mix tiny_ci.runs show RUN_ID [options]
      mix tiny_ci.runs prune [options]

  ## Commands

    * *(none)* — lists the project's runs, newest first, as a table of run id,
      status, pipeline, branch, commit, duration, and start time
    * `show RUN_ID` — prints one run: its identity, the same stage and step tree the
      console prints after a live run, and the last lines of each failed step's output
    * `prune` — deletes the oldest runs, keeping the newest `--keep`

  ## Options

    * `--root DIR` / `-r` — the project whose runs to read (default: current directory)
    * `--limit N` — list at most `N` runs (default 20)
    * `--output json` — machine-readable output: a list of run summaries for the
      listing, one run summary for `show`
    * `--events` — with `show`, print the raw NDJSON recording instead
    * `--keep N` — with `prune`, how many runs to keep (default 200; `0` removes all)

  A run killed before it finished has no summary and is listed as `interrupted`;
  so is a run that is still in progress.

  ## Examples

      mix tiny_ci.runs
      mix tiny_ci.runs --limit 5 --output json
      mix tiny_ci.runs show 20260102_030405_abc1234_0f3c...
      mix tiny_ci.runs show 20260102_030405_abc1234_0f3c... --events
      mix tiny_ci.runs prune --keep 50
  """

  use Mix.Task

  alias TinyCI.{Matrix, Reporter, Runs}
  alias TinyCI.Runs.Projection

  # How many trailing lines of a failed step's output `show` prints.
  @failure_lines 50

  @impl Mix.Task
  def run(["show" | args]), do: show(args)
  def run(["prune" | args]), do: prune(args)
  def run(["list" | args]), do: list(args)
  def run(args), do: list(args)

  # ---------------------------------------------------------------------------
  # list
  # ---------------------------------------------------------------------------

  defp list(args) do
    {opts, root} = parse(args, limit: :integer, output: :string)
    format = output_format(opts[:output])
    runs = Runs.list(root, limit(opts))

    case format do
      :json -> runs |> Enum.map(&Projection.to_json/1) |> Jason.encode!() |> IO.puts()
      :human -> print_runs(runs, root)
    end
  end

  defp print_runs([], root), do: IO.puts("No runs recorded for #{root}.")

  defp print_runs(runs, _root) do
    header = ["RUN ID", "STATUS", "PIPELINE", "BRANCH", "COMMIT", "DURATION", "STARTED"]
    widths = column_widths([header | Enum.map(runs, &row/1)])

    IO.puts(format_row(header, widths, nil))
    Enum.each(runs, &IO.puts(format_row(row(&1), widths, &1.status)))
  end

  defp limit(opts) do
    case Keyword.fetch(opts, :limit) do
      :error -> []
      {:ok, limit} when limit >= 1 -> [limit: limit]
      {:ok, _non_positive} -> Mix.raise("--limit must be a positive integer")
    end
  end

  defp row(%Projection{} = run) do
    [
      run.run_id,
      Atom.to_string(run.status),
      run.pipeline || "-",
      run.branch || "-",
      short_commit(run.commit),
      duration(run.duration_ms),
      started(run.started_at)
    ]
  end

  defp column_widths(rows) do
    rows
    |> Enum.zip_with(& &1)
    |> Enum.map(fn column -> column |> Enum.map(&String.length/1) |> Enum.max() end)
  end

  # Pad first, then colour, so escape codes never skew the columns.
  defp format_row(cells, widths, status) do
    cells
    |> Enum.zip(widths)
    |> Enum.with_index()
    |> Enum.map_join("  ", fn
      {{cell, width}, 1} -> colorize(status, String.pad_trailing(cell, width))
      {{cell, width}, _} -> String.pad_trailing(cell, width)
    end)
    |> String.trim_trailing()
  end

  # ---------------------------------------------------------------------------
  # show
  # ---------------------------------------------------------------------------

  defp show(args) do
    {opts, positional, root} = parse_with_positional(args, output: :string, events: :boolean)

    case positional do
      [run_id] -> show_run(root, run_id, opts)
      _ -> Mix.raise("Usage: mix tiny_ci.runs show RUN_ID [--output json] [--events]")
    end
  end

  defp show_run(root, run_id, opts) do
    format = output_format(opts[:output])

    cond do
      opts[:events] -> print_events(root, run_id)
      format == :json -> print_json(root, run_id)
      true -> print_run(root, run_id)
    end
  end

  defp print_events(root, run_id) do
    case Runs.events_path(root, run_id) do
      {:ok, path} -> path |> File.stream!() |> Enum.each(&IO.write/1)
      {:error, :not_found} -> not_found(root, run_id)
    end
  end

  defp print_json(root, run_id) do
    root |> fetch(run_id) |> Projection.to_json() |> Jason.encode!() |> IO.puts()
  end

  defp print_run(root, run_id) do
    run = fetch(root, run_id)

    print_header(run)
    run |> Projection.to_stage_results() |> Reporter.print_summary()
    print_failures(run)
    print_footer(run)
  end

  # The tree says which step failed; this says why. Only steps that actually failed
  # the run count, not tolerated `allow_failure:` ones, and only their last lines,
  # since `--output json` and `--events` have the rest.
  defp print_failures(%Projection{} = run) do
    for {label, step} <- failed_steps(run), step.output != "" do
      print_failed_step(label, step.output)
    end

    :ok
  end

  defp failed_steps(%Projection{stages: stages}) do
    Enum.flat_map(stages, fn stage ->
      own = for step <- stage.steps, do: {"#{stage.name}/#{step.name}", step}

      matrix =
        for run <- stage.matrix_runs, step <- run.steps do
          {"#{stage.name}[#{Matrix.label(Enum.sort(run.combination))}]/#{step.name}", step}
        end

      Enum.filter(own ++ matrix, fn {_label, step} ->
        step.status == :failed and not step.allowed_failure
      end)
    end)
  end

  defp print_failed_step(label, output) do
    lines = String.split(output, "\n", trim: true)
    omitted = max(length(lines) - @failure_lines, 0)

    IO.puts([IO.ANSI.red(), "Output of failed step ", label, ":", IO.ANSI.reset()])

    if omitted > 0 do
      IO.puts("  ... #{omitted} earlier lines omitted (see --output json or --events)")
    end

    lines |> Enum.take(-@failure_lines) |> Enum.each(&IO.puts("  " <> &1))
    IO.puts("")
  end

  defp fetch(root, run_id) do
    case Runs.projection(root, run_id) do
      {:ok, run} -> run
      {:error, :not_found} -> not_found(root, run_id)
    end
  end

  defp not_found(root, run_id), do: Mix.raise("Run #{inspect(run_id)} not found for #{root}")

  defp print_header(%Projection{} = run) do
    IO.puts([IO.ANSI.bright(), "Run ", run.run_id || "-", IO.ANSI.reset()])
    IO.puts("  pipeline  #{run.pipeline || "-"}")
    IO.puts(["  status    ", colorize(run.status, Atom.to_string(run.status))])
    IO.puts("  git       #{run.branch || "-"}@#{short_commit(run.commit)}")
    IO.puts("  started   #{started(run.started_at)}")
    IO.puts("  duration  #{duration(run.duration_ms)}")
  end

  defp print_footer(%Projection{} = run) do
    if run.status == :interrupted do
      warn(
        "This run is interrupted: no run_finished was recorded (it died, or is still running)."
      )
    end

    if run.divergent? do
      warn("This run is divergent: manual execution control altered it. It is not a CI result.")
    end
  end

  # ---------------------------------------------------------------------------
  # prune
  # ---------------------------------------------------------------------------

  defp prune(args) do
    {opts, root} = parse(args, keep: :integer)
    keep = keep(opts)
    %{removed: removed} = Runs.prune(root, keep)

    IO.puts([IO.ANSI.green(), "✓ ", IO.ANSI.reset(), "Removed #{plural(removed)} for #{root}"])
  end

  defp keep(opts) do
    case Keyword.fetch(opts, :keep) do
      :error -> []
      {:ok, keep} when keep >= 0 -> [keep: keep]
      {:ok, _negative} -> keep_error()
    end
  end

  defp keep_error, do: Mix.raise("--keep must be a non-negative integer")

  defp plural(1), do: "1 run"
  defp plural(n), do: "#{n} runs"

  # ---------------------------------------------------------------------------
  # shared
  # ---------------------------------------------------------------------------

  defp parse(args, switches) do
    {opts, positional, root} = parse_with_positional(args, switches)

    if positional != [] do
      Mix.raise("Unknown command: #{Enum.join(positional, " ")}. Use show, prune, or no command.")
    end

    {opts, root}
  end

  defp parse_with_positional(args, switches) do
    {opts, positional, invalid} =
      OptionParser.parse(args, strict: [root: :string] ++ switches, aliases: [r: :root])

    if invalid != [] do
      flags = Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
      Mix.raise("Invalid option: #{flags}")
    end

    {opts, positional, Path.expand(opts[:root] || File.cwd!())}
  end

  defp output_format(nil), do: :human
  defp output_format("json"), do: :json

  defp output_format(other),
    do: Mix.raise("Unknown --output format: #{inspect(other)}. Supported formats: json")

  defp short_commit(nil), do: "-"
  defp short_commit(commit), do: String.slice(commit, 0, 7)

  defp duration(nil), do: "-"
  defp duration(ms), do: Reporter.format_duration(ms)

  defp started(nil), do: "-"
  defp started(iso), do: String.slice(iso, 0, 19) |> String.replace("T", " ") |> Kernel.<>("Z")

  defp warn(message), do: IO.puts([IO.ANSI.yellow(), message, IO.ANSI.reset()])

  defp colorize(:passed, text), do: IO.ANSI.green() <> text <> IO.ANSI.reset()
  defp colorize(:failed, text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  defp colorize(:aborted, text), do: IO.ANSI.red() <> text <> IO.ANSI.reset()
  defp colorize(:interrupted, text), do: IO.ANSI.yellow() <> text <> IO.ANSI.reset()
  defp colorize(_other, text), do: text
end
