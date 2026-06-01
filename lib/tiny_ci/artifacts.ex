defmodule TinyCI.Artifacts do
  @moduledoc """
  Artifact persistence for pipeline steps.

  Artifacts declared on a step are copied to a per-run directory after the
  step completes successfully. Each run gets an isolated subdirectory derived
  from a timestamp and commit SHA, so runs never overwrite each other.

  Default storage location: `~/.local/share/tiny_ci/artifacts/<project_id>/<run_id>/<name>/`

  The artifact path is injected into the pipeline store under the key
  `artifact_<name>` (atom) so that downstream steps and stages can read it.
  """

  @doc "Returns the base artifacts directory, configurable via :tiny_ci :artifacts_base_dir."
  def base_dir do
    Application.get_env(
      :tiny_ci,
      :artifacts_base_dir,
      Path.join([System.user_home!(), ".local", "share", "tiny_ci", "artifacts"])
    )
  end

  @doc "Computes a stable 16-character project identifier from the root path."
  @spec project_id(String.t()) :: String.t()
  def project_id(root) do
    :crypto.hash(:sha256, root)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Generates a run identifier from pipeline context.

  Format: `<YYYYMMDD_HHMMSS>_<commit7>` — lexicographic order equals
  chronological order, making it trivial to find the latest run.
  """
  @spec generate_run_id(map()) :: String.t()
  def generate_run_id(context) do
    ts = Map.get(context, :timestamp, DateTime.utc_now())
    commit = Map.get(context, :commit, "unknown")
    short_commit = String.slice(commit, 0, 7)

    formatted =
      "#{zero_pad(ts.year, 4)}#{zero_pad(ts.month, 2)}#{zero_pad(ts.day, 2)}" <>
        "_#{zero_pad(ts.hour, 2)}#{zero_pad(ts.minute, 2)}#{zero_pad(ts.second, 2)}"

    "#{formatted}_#{short_commit}"
  end

  @doc "Returns the full artifacts directory path for the given project root and run ID."
  @spec run_artifacts_dir(String.t(), String.t()) :: String.t()
  def run_artifacts_dir(root, run_id) do
    Path.join([base_dir(), project_id(root), run_id])
  end

  @doc """
  Persists declared artifact paths from `src_base` into `run_dir/<name>/`.

  Returns:
    - `{:ok, artifact_path}` — all paths copied successfully
    - `{:warning, artifact_path, [missing]}` — some paths missing, artifact not required
    - `{:error, {:missing_required, name, [missing]}}` — required paths absent
  """
  @spec persist(
          %{name: String.t(), paths: [String.t()], required: boolean()},
          String.t(),
          String.t()
        ) ::
          {:ok, String.t()}
          | {:warning, String.t(), [String.t()]}
          | {:error, {:missing_required, String.t(), [String.t()]}}
  def persist(%{name: name, paths: paths, required: required}, src_base, run_dir) do
    artifact_path = Path.join(run_dir, name)

    {found, missing} =
      Enum.split_with(paths, fn path -> File.exists?(Path.join(src_base, path)) end)

    if missing == [] or found != [] do
      Enum.each(found, fn path ->
        src = Path.join(src_base, path)
        dst = Path.join(artifact_path, path)
        File.mkdir_p!(Path.dirname(dst))
        copy_path(src, dst)
      end)
    end

    cond do
      missing == [] ->
        {:ok, artifact_path}

      required ->
        {:error, {:missing_required, name, missing}}

      true ->
        {:warning, artifact_path, missing}
    end
  end

  @doc """
  Lists all artifact runs for the given project root, sorted oldest-first.

  Returns a list of `{run_id, [artifact_name]}` tuples.
  """
  @spec list_runs(String.t()) :: [{String.t(), [String.t()]}]
  def list_runs(root) do
    project_dir = Path.join(base_dir(), project_id(root))

    case File.ls(project_dir) do
      {:ok, entries} ->
        entries
        |> Enum.sort()
        |> Enum.map(fn run_id ->
          run_dir = Path.join(project_dir, run_id)
          artifacts = list_run_artifacts(run_dir)
          {run_id, artifacts}
        end)

      {:error, _} ->
        []
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp list_run_artifacts(run_dir) do
    case File.ls(run_dir) do
      {:ok, entries} -> Enum.sort(entries)
      {:error, _} -> []
    end
  end

  defp copy_path(src, dst) do
    if File.dir?(src) do
      File.mkdir_p!(dst)

      src
      |> File.ls!()
      |> Enum.each(fn entry ->
        copy_path(Path.join(src, entry), Path.join(dst, entry))
      end)
    else
      File.cp!(src, dst)
    end
  end

  defp zero_pad(n, width), do: String.pad_leading(Integer.to_string(n), width, "0")
end
