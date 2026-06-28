defmodule Mix.Tasks.TinyCi.Actions.Audit do
  @shortdoc "Prints the resolved action supply-chain tree for a pipeline"

  @moduledoc """
  Resolves every `module:` action a pipeline uses against the project's
  `mix.lock` and prints the result — each action's owning package, version,
  pinned checksum, and supply-chain status.

  Because TinyCI actions are ordinary Hex dependencies, `mix.lock` *is* the
  action lockfile. This command is the reporting layer over that resolution; the
  same check runs automatically at the start of `mix tiny_ci.run`.

  ## Usage

      mix tiny_ci.actions.audit [NAME] [options]

  Pipeline selection mirrors `mix tiny_ci.run`:

    * `--file PATH` / `-f` — audit a specific pipeline file
    * `--root DIR` / `-r` — project root (defaults to the current directory)
    * a `NAME` positional — `.tiny_ci/<NAME>.exs`

  ## Exit codes

    * `0` — every action is locked, first-party, or otherwise sound
    * `1` — a supply-chain problem (an unpinned third-party action, or a build
      that has drifted from the lockfile), or no pipeline file found
  """

  use Mix.Task

  alias TinyCI.Action.Audit
  alias TinyCI.Discovery

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)

    {opts, positional, _invalid} =
      OptionParser.parse(args,
        switches: [file: :string, root: :string],
        aliases: [f: :file, r: :root]
      )

    root = opts[:root] || File.cwd!()

    result =
      with {:ok, spec} <- resolve_pipeline(opts, root, List.first(positional)),
           {:ok, entries} <- Audit.analyze(spec, root, root_app: root_app()) do
        IO.puts(Audit.format(entries))
        if Enum.any?(entries, &(&1.status == :error)), do: {:error, :unsound}, else: :ok
      end

    finish(result)
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

  defp root_app, do: Mix.Project.config()[:app]

  defp finish(:ok), do: halt(0)

  defp finish({:error, reason}) do
    print_error(reason)
    halt(1)
  end

  defp halt(code) do
    if Mix.env() != :test, do: System.halt(code)
    if code == 0, do: :ok, else: {:error, :audit_failed}
  end

  defp print_error(:unsound), do: :ok

  defp print_error(:not_found) do
    error("No pipeline file found. Expected tiny_ci.exs or .tiny_ci/pipeline.exs")
  end

  defp print_error({:named_not_found, name}) do
    error("Pipeline not found: #{name} (looked for .tiny_ci/#{name}.exs)")
  end

  defp print_error(reason), do: error("Error: #{inspect(reason)}")

  defp error(message) do
    IO.puts(:stderr, [IO.ANSI.red(), message, IO.ANSI.reset()])
  end
end
