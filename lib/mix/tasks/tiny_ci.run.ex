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
    * `--filter STAGES` — run only the named stage(s), comma-separated
    * `--output FORMAT` — output format: `json` for machine-readable output

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

      # Machine-readable JSON output
      mix tiny_ci.run --output json

  ## Exit Codes

    * `0` — pipeline completed successfully (or `--list` / `--dry-run`)
    * `1` — pipeline failed or no pipeline file found
  """

  use Mix.Task

  alias TinyCI.{Discovery, DryRun, Executor, Hooks, Reporter, Results}
  alias TinyCI.Listener

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [
          file: :string,
          root: :string,
          dry_run: :boolean,
          list: :boolean,
          filter: :string,
          output: :string
        ],
        aliases: [f: :file, r: :root]
      )

    root = opts[:root] || File.cwd!()
    name = List.first(positional)
    filter = parse_filter(opts[:filter])

    result =
      if opts[:list] do
        list_available_pipelines(root)
      else
        run_or_error(opts, root, name, filter)
      end

    maybe_halt(result)
    result
  end

  defp maybe_halt(:ok), do: halt_unless_test(0)
  defp maybe_halt({:error, _}), do: halt_unless_test(1)

  defp halt_unless_test(code) do
    if Mix.env() != :test, do: System.halt(code)
  end

  defp parse_output_format(nil), do: {:ok, :human}
  defp parse_output_format("json"), do: {:ok, :json}

  defp parse_output_format(other) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Unknown --output format: #{inspect(other)}.",
      IO.ANSI.reset(),
      " Supported formats: json"
    ])

    {:error, :no_pipeline}
  end

  defp resolve_pipeline(opts, root, name, output_format) do
    cond do
      opts[:file] ->
        Discovery.load_pipeline(opts[:file])

      name ->
        case Discovery.find_pipeline_by_name(root, name) do
          {:ok, path} -> load_and_announce(path, output_format)
          {:error, :not_found} -> {:error, {:named_not_found, name}}
        end

      true ->
        discover_and_load(root, output_format)
    end
  end

  defp discover_and_load(root, output_format) do
    with {:ok, path} <- Discovery.find_pipeline(root) do
      load_and_announce(path, output_format)
    end
  end

  defp load_and_announce(path, output_format) do
    with {:ok, spec} <- Discovery.load_pipeline(path) do
      if output_format != :json, do: IO.puts("Found pipeline: #{path}")
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

  defp run_or_error(opts, root, name, filter) do
    with {:ok, output_format} <- parse_output_format(opts[:output]) do
      case resolve_pipeline(opts, root, name, output_format) do
        {:ok, spec} -> run_with_filter(spec, opts[:dry_run], filter, output_format)
        {:error, reason} -> handle_error(reason)
      end
    end
  end

  defp run_with_filter(spec, dry_run, filter, output_format) do
    with :ok <- validate_filter(filter, spec.stages) do
      dispatch_pipeline(spec, dry_run, filter, output_format)
    end
  end

  defp dispatch_pipeline(spec, true, filter, _output_format), do: dry_run_pipeline(spec, filter)

  defp dispatch_pipeline(spec, _, filter, output_format),
    do: execute_pipeline(spec, filter, output_format)

  defp handle_error(reason) do
    print_error(reason)
    {:error, :no_pipeline}
  end

  defp parse_filter(nil), do: nil

  defp parse_filter(filter_str) do
    filter_str
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.map(fn
      ":" <> name -> String.to_atom(name)
      name -> String.to_atom(name)
    end)
  end

  defp validate_filter(nil, _stages), do: :ok
  defp validate_filter([], _stages), do: :ok

  defp validate_filter(filter, stages) do
    stage_names = MapSet.new(stages, & &1.name)
    unknown = Enum.reject(filter, &MapSet.member?(stage_names, &1))

    if unknown == [] do
      :ok
    else
      available = Enum.map_join(stages, ", ", fn s -> ":#{s.name}" end)
      unknown_str = Enum.map_join(unknown, ", ", &":#{&1}")

      IO.puts(:stderr, [
        IO.ANSI.red(),
        "Unknown stage filter: #{unknown_str}.",
        IO.ANSI.reset(),
        " Available stages: #{available}"
      ])

      {:error, :no_pipeline}
    end
  end

  defp dry_run_pipeline(
         %TinyCI.PipelineSpec{stages: stages, root: root, env: pipeline_env},
         filter
       ) do
    context = TinyCI.Context.build(root: root, pipeline_env: pipeline_env)
    filtered = filter_stages(stages, filter)
    DryRun.print_plan(filtered, context)
    :ok
  end

  defp execute_pipeline(
         %TinyCI.PipelineSpec{stages: stages, hooks: hooks, root: root, env: pipeline_env},
         filter,
         :json
       ) do
    context = TinyCI.Context.build(root: root, pipeline_env: pipeline_env)

    pipeline_result =
      Executor.run_pipeline(stages, context,
        filter: filter,
        output: :buffered,
        listener: Listener.Silent
      )

    stage_results = extract_stage_results(pipeline_result)

    IO.puts(Results.to_json(simplify_result(pipeline_result), stage_results))
    Hooks.run_hooks(hooks, hook_event(pipeline_result), context)

    case pipeline_result do
      {:ok, _} -> :ok
      {:error, _, _} -> {:error, :pipeline_failed}
    end
  end

  defp execute_pipeline(
         %TinyCI.PipelineSpec{stages: stages, hooks: hooks, root: root, env: pipeline_env},
         filter,
         :human
       ) do
    context = TinyCI.Context.build(root: root, pipeline_env: pipeline_env)

    case Executor.run_pipeline(stages, context, filter: filter) do
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

  defp extract_stage_results({:ok, results}), do: results
  defp extract_stage_results({:error, _, results}), do: results

  defp simplify_result({:ok, _}), do: :ok
  defp simplify_result({:error, reason, _}), do: {:error, reason}

  defp hook_event({:ok, _}), do: :on_success
  defp hook_event({:error, _, _}), do: :on_failure

  defp filter_stages(stages, nil), do: stages
  defp filter_stages(stages, []), do: stages

  defp filter_stages(stages, filter) do
    filter_set = MapSet.new(filter)
    Enum.filter(stages, &MapSet.member?(filter_set, &1.name))
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

  defp print_error({:circular_dependency, cycle}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Circular dependency detected:", IO.ANSI.reset()])

    IO.puts(:stderr, "  Stages involved: #{Enum.map_join(cycle, ", ", &":#{&1}")}")
  end

  defp print_error({:unknown_stages, errors}) do
    IO.puts(:stderr, [IO.ANSI.red(), "Unknown stage references:", IO.ANSI.reset()])
    Enum.each(errors, fn e -> IO.puts(:stderr, "  • #{e}") end)
  end

  defp print_error(reason) do
    IO.puts(:stderr, [
      IO.ANSI.red(),
      "Error: #{inspect(reason)}",
      IO.ANSI.reset()
    ])
  end
end
