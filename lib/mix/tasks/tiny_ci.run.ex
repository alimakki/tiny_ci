defmodule Mix.Tasks.TinyCi.Run do
  @shortdoc "Discovers and runs a TinyCI pipeline"

  @moduledoc """
  Discovers and executes a TinyCI pipeline definition file.

  ## Usage

      mix tiny_ci.run [NAME] [options]

  An optional `NAME` selects a pipeline by name from the `.tiny_ci/` directory.
  Slash-separated names resolve to nested files (e.g. `jobs/release` looks for
  `.tiny_ci/jobs/release.exs`).

  ## Options

    * `--file PATH` / `-f` — path to a specific pipeline file (skips discovery)
    * `--root DIR` / `-r` — project root directory (defaults to current directory)
    * `--dry-run` — show what would execute without running anything
    * `--list` — list all available pipelines in `.tiny_ci/` and exit

  ## Pipeline Selection

  Resolution order (first match wins):

    1. `--file PATH` — explicit path, no discovery
    2. `NAME` positional argument — loads `.tiny_ci/<NAME>.exs`
    3. Auto-discovery — checks `tiny_ci.exs`, then `.tiny_ci/pipeline.exs`

  ## Examples

      # Run the default pipeline
      mix tiny_ci.run

      # Run a named pipeline from .tiny_ci/
      mix tiny_ci.run deploy

      # Run a nested pipeline from .tiny_ci/jobs/release.exs
      mix tiny_ci.run jobs/release

      # List all available pipelines
      mix tiny_ci.run --list

      # Preview a named pipeline without executing
      mix tiny_ci.run deploy --dry-run

  ## Exit Codes

    * `0` — pipeline completed successfully (or `--list` / `--dry-run`)
    * `1` — pipeline failed or no pipeline file found
  """

  use Mix.Task

  alias TinyCI.{Discovery, DryRun, Executor, Hooks, Reporter}

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)
    Application.ensure_all_started(:porcelain)

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [file: :string, root: :string, dry_run: :boolean, list: :boolean],
        aliases: [f: :file, r: :root]
      )

    root = opts[:root] || File.cwd!()
    name = List.first(positional)

    result =
      if opts[:list] do
        list_available_pipelines(root)
      else
        case resolve_pipeline(opts, root, name) do
          {:ok, spec} -> dispatch_pipeline(spec, opts[:dry_run])
          {:error, reason} -> handle_error(reason)
        end
      end

    maybe_halt(result)
    result
  end

  defp maybe_halt(:ok), do: halt_unless_test(0)
  defp maybe_halt({:error, _}), do: halt_unless_test(1)

  defp halt_unless_test(code) do
    if Mix.env() != :test, do: System.halt(code)
  end

  defp resolve_pipeline(opts, root, name) do
    cond do
      opts[:file] ->
        Discovery.load_pipeline(opts[:file])

      name ->
        case Discovery.find_pipeline_by_name(root, name) do
          {:ok, path} -> load_and_announce(path)
          {:error, :not_found} -> {:error, {:named_not_found, name}}
        end

      true ->
        discover_and_load(root)
    end
  end

  defp discover_and_load(root) do
    with {:ok, path} <- Discovery.find_pipeline(root) do
      load_and_announce(path)
    end
  end

  defp load_and_announce(path) do
    with {:ok, spec} <- Discovery.load_pipeline(path) do
      IO.puts("Found pipeline: #{path}")
      {:ok, spec}
    end
  end

  defp list_available_pipelines(root) do
    case Discovery.list_pipelines(root) do
      [] ->
        IO.puts("No pipelines found in .tiny_ci/")

      pipelines ->
        IO.puts("Available pipelines:")

        Enum.each(pipelines, fn {name, path} ->
          IO.puts("  #{name}  #{path}")
        end)
    end

    :ok
  end

  defp dispatch_pipeline(spec, true), do: dry_run_pipeline(spec)
  defp dispatch_pipeline(spec, _), do: execute_pipeline(spec)

  defp handle_error(reason) do
    print_error(reason)
    {:error, :no_pipeline}
  end

  defp dry_run_pipeline(%TinyCI.PipelineSpec{stages: stages, root: root}) do
    context = TinyCI.Context.build(root: root)
    DryRun.print_plan(stages, context)
    :ok
  end

  defp execute_pipeline(%TinyCI.PipelineSpec{stages: stages, hooks: hooks, root: root}) do
    context = TinyCI.Context.build(root: root)

    case Executor.run_pipeline(stages, context) do
      {:ok, stage_results} ->
        Reporter.print_summary(stage_results)
        Hooks.run_hooks(hooks, :on_success, context)
        IO.puts([IO.ANSI.green(), "Pipeline completed successfully.", IO.ANSI.reset()])
        :ok

      {:error, _reason, stage_results} ->
        Reporter.print_summary(stage_results)
        Hooks.run_hooks(hooks, :on_failure, context)

        IO.puts(:stderr, [
          IO.ANSI.red(),
          "Pipeline failed.",
          IO.ANSI.reset()
        ])

        {:error, :pipeline_failed}
    end
  end

  defp print_error(:not_found) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "No pipeline file found. ",
      IO.ANSI.reset(),
      "Expected tiny_ci.exs or .tiny_ci/pipeline.exs"
    ])
  end

  defp print_error(:file_not_found) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Pipeline file not found.",
      IO.ANSI.reset()
    ])
  end

  defp print_error({:parse_error, message}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Failed to parse pipeline: ",
      IO.ANSI.reset(),
      message
    ])
  end

  defp print_error({:validation_error, violations}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Invalid pipeline file:", IO.ANSI.reset()])

    Enum.each(violations, fn v ->
      IO.puts(:stderr, "  • #{v}")
    end)
  end

  defp print_error({:named_not_found, name}) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Pipeline not found: ",
      IO.ANSI.reset(),
      "#{name} (looked for .tiny_ci/#{name}.exs)"
    ])
  end

  defp print_error(reason) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Error: #{inspect(reason)}",
      IO.ANSI.reset()
    ])
  end
end
