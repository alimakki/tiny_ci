defmodule TinyCI.Artifacts do
  @moduledoc """
  Artifact persistence for pipeline steps.

  Artifacts declared on a step are copied to a per-run directory after the
  step completes successfully. Each run gets an isolated subdirectory derived
  from a timestamp, commit SHA, and random suffix to isolate concurrent runs.

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

  Format: `<YYYYMMDD_HHMMSS>_<commit7>_<random128>`. The timestamp prefix sorts
  chronologically to the second; a cryptographically random suffix isolates
  runs with the same timestamp and commit.
  """
  @spec generate_run_id(map()) :: String.t()
  def generate_run_id(context) do
    ts = Map.get(context, :timestamp, DateTime.utc_now())
    commit = Map.get(context, :commit) || "unknown"
    short_commit = String.slice(commit, 0, 7)

    formatted =
      "#{zero_pad(ts.year, 4)}#{zero_pad(ts.month, 2)}#{zero_pad(ts.day, 2)}" <>
        "_#{zero_pad(ts.hour, 2)}#{zero_pad(ts.minute, 2)}#{zero_pad(ts.second, 2)}"

    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    "#{formatted}_#{short_commit}_#{suffix}"
  end

  @doc "Returns the full artifacts directory path for the given project root and run ID."
  @spec run_artifacts_dir(String.t(), String.t()) :: String.t()
  def run_artifacts_dir(root, run_id) do
    Path.join([base_dir(), project_id(root), run_id])
  end

  @doc """
  Persists declared artifact paths from `src_base` into `run_dir/<name>/`.

  Names and paths must be relative, without `..` components. Symlinks are
  dereferenced only within their respective source/run root; cycles are rejected.
  All paths are checked before copying, so unsafe declarations publish nothing.

  Returns:
    - `{:ok, artifact_path}` — all paths copied successfully
    - `{:warning, artifact_path, [missing]}` — some paths missing, artifact not required
    - `{:error, {:missing_required, name, [missing]}}` — required paths absent
    - `{:error, {:unsafe_path, name, path}}` - an unsafe name or path
  """
  @spec persist(
          %{name: String.t(), paths: [String.t()], required: boolean()},
          String.t(),
          String.t()
        ) ::
          {:ok, String.t()}
          | {:warning, String.t(), [String.t()]}
          | {:error, {:missing_required, String.t(), [String.t()]}}
          | {:error, {:unsafe_path, String.t(), String.t()}}
  def persist(%{name: name, paths: paths, required: required}, src_base, run_dir) do
    with :ok <- validate_paths(name, paths, src_base, run_dir) do
      persist_paths(name, paths, required, src_base, run_dir)
    end
  end

  defp persist_paths(name, paths, required, src_base, run_dir) do
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

  defp validate_paths(name, paths, src_base, run_dir) do
    roots = {Path.expand(src_base), Path.expand(run_dir)}

    with true <- relative_path?(name) and Path.expand(name, elem(roots, 1)) != elem(roots, 1),
         {:ok, _} <- resolve_inside(Path.join(elem(roots, 1), name), elem(roots, 1)) do
      unsafe =
        Enum.find(paths, fn path ->
          not relative_path?(path) or
            validate_tree(Path.join(src_base, path), Path.join([run_dir, name, path]), roots) !=
              :ok
        end)

      if unsafe, do: {:error, {:unsafe_path, name, unsafe}}, else: :ok
    else
      _ -> {:error, {:unsafe_path, name, name}}
    end
  end

  defp relative_path?(path) do
    is_binary(path) and path != "" and Path.type(path) == :relative and
      ".." not in Path.split(path) and not String.contains?(path, <<0>>)
  end

  defp validate_tree(src, dst, {src_root, dst_root} = roots, ancestors \\ MapSet.new()) do
    with {:ok, src} <- resolve_inside(Path.expand(src), src_root),
         {:ok, dst} <- resolve_inside(Path.expand(dst), dst_root) do
      validate_resolved_tree(src, dst, roots, ancestors)
    end
  end

  defp validate_resolved_tree(src, dst, roots, ancestors) do
    cond do
      MapSet.member?(ancestors, src) -> :error
      File.dir?(src) and inside?(dst, src) -> :error
      File.dir?(src) -> validate_children(src, dst, roots, MapSet.put(ancestors, src))
      true -> :ok
    end
  end

  defp validate_children(src, dst, roots, ancestors) do
    Enum.reduce_while(File.ls!(src), :ok, fn child, :ok ->
      case validate_tree(Path.join(src, child), Path.join(dst, child), roots, ancestors) do
        :ok -> {:cont, :ok}
        :error -> {:halt, :error}
      end
    end)
  end

  defp inside?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  defp resolve_inside(path, root) do
    if inside?(path, root) and not match?({:ok, %File.Stat{type: :symlink}}, File.lstat(root)) do
      resolve_parts(root, Path.split(Path.relative_to(path, root)), root, 0)
    else
      :error
    end
  end

  defp resolve_parts(_current, _parts, _root, hops) when hops > 40, do: :error
  defp resolve_parts(current, [], _root, _hops), do: {:ok, current}

  defp resolve_parts(current, ["." | rest], root, hops),
    do: resolve_parts(current, rest, root, hops)

  defp resolve_parts(current, [".." | rest], root, hops) do
    if current == root, do: :error, else: resolve_parts(Path.dirname(current), rest, root, hops)
  end

  defp resolve_parts(current, [part | rest], root, hops) do
    path = Path.join(current, part)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :symlink}} ->
        resolve_link(current, File.read_link!(path), rest, root, hops + 1)

      {:ok, _} ->
        resolve_parts(path, rest, root, hops)

      {:error, reason} when reason in [:enoent, :enotdir] ->
        resolve_parts(path, rest, root, hops)

      {:error, :eloop} ->
        :error

      {:error, reason} ->
        raise File.Error, reason: reason, action: "validate artifact path", path: path
    end
  end

  defp resolve_link(current, target, rest, root, hops) do
    case Path.type(target) do
      :relative ->
        resolve_parts(current, Path.split(target) ++ rest, root, hops)

      :absolute ->
        if inside?(target, root) do
          resolve_parts(root, Path.split(Path.relative_to(target, root)) ++ rest, root, hops)
        else
          :error
        end
    end
  end

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
