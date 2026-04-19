defmodule TinyCI.Discovery do
  @moduledoc """
  Discovers and loads pipeline definition files.

  Searches for pipeline files in conventional locations and interprets them
  into `%TinyCI.PipelineSpec{}` structs. The search order is:

    1. `tiny_ci.exs` in the project root
    2. `.tiny_ci/pipeline.exs` in the project root

  The first match wins. Files are parsed via `TinyCI.DSL.Interpreter` — no
  Elixir module is compiled, no bytecode is produced, and no code runs during
  loading. The pipeline file must use the flat DSL format (no `defmodule`).
  """

  alias TinyCI.{DSL.Interpreter, PipelineSpec}

  @conventional_paths [
    "tiny_ci.exs",
    ".tiny_ci/pipeline.exs"
  ]

  @doc """
  Finds a pipeline file in the given project root directory.

  Checks conventional locations in priority order and returns the path
  to the first file found.

  ## Parameters

    * `root` — the project root directory to search in

  ## Returns

    * `{:ok, path}` — when a pipeline file is found
    * `{:error, :not_found}` — when no pipeline file exists
  """
  @spec find_pipeline(String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def find_pipeline(root) do
    @conventional_paths
    |> Enum.map(&Path.join(root, &1))
    |> Enum.find(&File.exists?/1)
    |> case do
      nil -> {:error, :not_found}
      path -> {:ok, path}
    end
  end

  @doc """
  Loads and interprets a pipeline file, returning a `%TinyCI.PipelineSpec{}`.

  The file is parsed via `TinyCI.DSL.Interpreter` — no Elixir compilation
  occurs. The pipeline file must use the new flat DSL format.

  ## Parameters

    * `path` — absolute or relative path to an `.exs` pipeline file

  ## Returns

    * `{:ok, %TinyCI.PipelineSpec{}}` on success
    * `{:error, :file_not_found}` — when the file does not exist
    * `{:error, {:parse_error, message}}` — when the file has syntax errors
    * `{:error, {:validation_error, violations}}` — when the file uses
      disallowed constructs
  """
  @spec load_pipeline(String.t()) ::
          {:ok, PipelineSpec.t()}
          | {:error, :file_not_found}
          | {:error, {:parse_error, String.t()}}
          | {:error, {:validation_error, [String.t()]}}
  def load_pipeline(path) do
    if File.exists?(path) do
      Interpreter.interpret_file(path)
    else
      {:error, :file_not_found}
    end
  end

  @doc """
  Finds a pipeline file by name within the `.tiny_ci/` directory.

  The name maps directly to a file path: `"deploy"` resolves to
  `.tiny_ci/deploy.exs`, and `"jobs/release"` resolves to
  `.tiny_ci/jobs/release.exs`.

  Path traversal is prevented: the resolved path must remain inside the
  `.tiny_ci/` directory. Names containing `..` segments that would escape
  the directory return `{:error, :not_found}`.

  ## Parameters

    * `root` — the project root directory to search in
    * `name` — the pipeline name (slash-separated for nested files)

  ## Returns

    * `{:ok, path}` — when the named pipeline file exists
    * `{:error, :not_found}` — when no matching file is found or path escapes
  """
  @spec find_pipeline_by_name(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def find_pipeline_by_name(root, name) do
    base = Path.expand(Path.join(root, ".tiny_ci"))
    path = Path.expand(Path.join([root, ".tiny_ci", "#{name}.exs"]))

    if String.starts_with?(path, base <> "/") and File.exists?(path) do
      {:ok, path}
    else
      {:error, :not_found}
    end
  end

  @doc """
  Lists all pipeline files available in the `.tiny_ci/` directory.

  Recursively scans `.tiny_ci/` for `.exs` files and returns each as a
  `{name, path}` pair, where `name` is the relative path from `.tiny_ci/`
  without the `.exs` extension (e.g. `"deploy"` or `"jobs/release"`).

  Results are sorted alphabetically by name.

  ## Parameters

    * `root` — the project root directory to scan

  ## Returns

  A list of `{name, path}` tuples, or `[]` if `.tiny_ci/` does not exist
  or contains no `.exs` files.
  """
  @spec list_pipelines(String.t()) :: [{String.t(), String.t()}]
  def list_pipelines(root) do
    dir = Path.join(root, ".tiny_ci")

    if File.exists?(dir) do
      dir
      |> Path.join("**/*.exs")
      |> Path.wildcard()
      |> Enum.map(fn path ->
        name = path |> Path.relative_to(dir) |> Path.rootname()
        {name, path}
      end)
      |> Enum.sort_by(fn {name, _} -> name end)
    else
      []
    end
  end
end
