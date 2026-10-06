defmodule TinyCI.Runs do
  @moduledoc """
  The run store: every run's recording, on disk.

  A run is a directory:

      <base_dir>/<project_id>/<run_id>/events.ndjson   # the recording, appended during the run
      <base_dir>/<project_id>/<run_id>/meta.json       # the summary, written once at close

  `events.ndjson` is the authoritative record, in the same format `--events`
  writes. `meta.json` is `TinyCI.Runs.Projection.to_json/1` of that stream, kept so
  a listing does not have to fold every recording. There is no database: the
  directories and NDJSON are the store.

  `project_id` is `TinyCI.Artifacts.project_id/1` of the expanded project root, and
  `run_id` is the id `TinyCI.Artifacts.generate_run_id/1` gave the run. It sorts
  chronologically as a string, to the second.
  """

  alias TinyCI.Artifacts
  alias TinyCI.Runs.Projection

  @events_file "events.ndjson"
  @meta_file "meta.json"
  @default_limit 20
  @default_keep 200

  @doc """
  The base directory of the run store.

  Configurable with `config :tiny_ci, :runs_base_dir`; otherwise
  `$XDG_DATA_HOME/tiny_ci/runs`, falling back to `~/.local/share/tiny_ci/runs`.
  """
  @spec base_dir() :: String.t()
  def base_dir do
    Application.get_env(:tiny_ci, :runs_base_dir) || default_base_dir()
  end

  defp default_base_dir do
    data_home =
      case System.get_env("XDG_DATA_HOME") do
        home when home in [nil, ""] -> Path.join(System.user_home!(), ".local/share")
        home -> home
      end

    Path.join([data_home, "tiny_ci", "runs"])
  end

  @doc """
  The directory holding every run of the project at `root`.

  The root is expanded first, so `--root .` and the absolute path the executor
  records under are the same project.

  ## Examples

      iex> TinyCI.Runs.project_dir("/work/app") |> Path.basename() |> String.length()
      16
  """
  @spec project_dir(String.t()) :: String.t()
  def project_dir(root) do
    Path.join(base_dir(), root |> Path.expand() |> Artifacts.project_id())
  end

  @doc """
  The directory of one run of the project at `root`.

  ## Examples

      iex> TinyCI.Runs.dir("/work/app", "run1") |> Path.basename()
      "run1"
  """
  @spec dir(String.t(), String.t()) :: String.t()
  def dir(root, run_id), do: Path.join(project_dir(root), run_id)

  @doc false
  @spec events_file() :: String.t()
  def events_file, do: @events_file

  @doc false
  @spec meta_file() :: String.t()
  def meta_file, do: @meta_file

  @doc """
  Writes `projection` as `meta.json` in `dir`, atomically.

  The JSON goes to `meta.json.tmp` first and is then renamed into place, so a
  reader sees the old file or the whole new one, never a torn write.
  """
  @spec write_meta(String.t(), Projection.t()) :: :ok | {:error, term()}
  def write_meta(dir, %Projection{} = projection) do
    tmp = Path.join(dir, @meta_file <> ".tmp")
    json = projection |> Projection.to_json() |> Jason.encode!()

    with :ok <- File.write(tmp, json) do
      File.rename(tmp, Path.join(dir, @meta_file))
    end
  end

  @doc """
  Lists the project's runs as projections, newest first.

  Each run is read from its `meta.json` when that is present and decodes, and
  otherwise folded from its recording, so a run that died before closing (no
  `meta.json`) lists as `:interrupted`. A run that is still in progress has no
  `meta.json` yet and lists the same way until it finishes.

  ## Options

    * `:limit` — the most runs to return (default #{@default_limit})
  """
  @spec list(String.t(), keyword()) :: [Projection.t()]
  def list(root, opts \\ []) do
    limit = Keyword.get(opts, :limit, @default_limit)

    root
    |> run_ids()
    |> Enum.sort(:desc)
    |> Stream.flat_map(&summary(root, &1))
    |> Enum.take(limit)
  end

  @doc """
  Deletes the project's oldest runs, keeping the newest `:keep` (default
  #{@default_keep}). Only run directories are removed.

  ## Options

    * `:keep` — how many runs to keep; `0` removes them all
  """
  @spec prune(String.t(), keyword()) :: %{removed: non_neg_integer()}
  def prune(root, opts \\ []), do: prune_to(root, Keyword.get(opts, :keep, @default_keep))

  defp prune_to(root, keep) when is_integer(keep) and keep >= 0 do
    removed =
      root
      |> run_ids()
      |> Enum.sort(:desc)
      |> Enum.drop(keep)
      |> Enum.count(&match?({:ok, _}, File.rm_rf(dir(root, &1))))

    %{removed: removed}
  end

  defp prune_to(_root, keep) do
    raise ArgumentError, "keep must be a non-negative integer, got: #{inspect(keep)}"
  end

  defp run_ids(root) do
    project_dir = project_dir(root)

    case File.ls(project_dir) do
      {:ok, entries} -> Enum.filter(entries, &File.dir?(Path.join(project_dir, &1)))
      {:error, _} -> []
    end
  end

  defp summary(root, run_id) do
    case read_meta(dir(root, run_id)) do
      {:ok, projection} -> [named(projection, run_id)]
      :error -> folded_summary(root, run_id)
    end
  end

  defp read_meta(dir) do
    with {:ok, content} <- File.read(Path.join(dir, @meta_file)),
         {:ok, %{} = json} <- Jason.decode(content) do
      {:ok, Projection.from_json(json)}
    else
      _ -> :error
    end
  rescue
    # A meta.json that decodes but has the wrong shape is as good as a corrupt one:
    # fall back to the recording.
    _ -> :error
  end

  defp folded_summary(root, run_id) do
    case projection(root, run_id) do
      {:ok, projection} -> [named(projection, run_id)]
      {:error, :not_found} -> []
    end
  rescue
    # One unreadable recording must not take the whole listing down.
    _ -> []
  end

  # A recording cut off before `run_started` has no id of its own; its directory does.
  defp named(%Projection{run_id: nil} = projection, run_id), do: %{projection | run_id: run_id}
  defp named(%Projection{} = projection, _run_id), do: projection

  @doc """
  The folded projection of a run, read from its recording.

  Folds `events.ndjson` rather than reading `meta.json`, since the recording is the
  authoritative source. A recording that ends without `run_finished` is reported as
  `:interrupted`.
  """
  @spec projection(String.t(), String.t()) :: {:ok, Projection.t()} | {:error, :not_found}
  def projection(root, run_id) do
    with {:ok, events} <- load(root, run_id) do
      {:ok, events |> Projection.fold() |> Projection.finalize()}
    end
  end

  @doc """
  A run's recording as a lazy stream of decoded event maps.

  Blank and undecodable lines are skipped, because a run killed mid-write can leave
  a truncated last line. The stream holds the file open while it is consumed, so
  consume it fully (or use `Enum.to_list/1`).
  """
  @spec load(String.t(), String.t()) :: {:ok, Enumerable.t()} | {:error, :not_found}
  def load(root, run_id) do
    with {:ok, path} <- events_path(root, run_id) do
      {:ok, path |> File.stream!() |> Stream.flat_map(&decode_line/1)}
    end
  end

  @doc """
  The path of a run's `events.ndjson`, for reading it verbatim.

  `{:error, :not_found}` when there is no such recording, or when `run_id` is not a
  bare directory name.
  """
  @spec events_path(String.t(), String.t()) :: {:ok, String.t()} | {:error, :not_found}
  def events_path(root, run_id) do
    with true <- bare_name?(run_id),
         path = Path.join(dir(root, run_id), @events_file),
         true <- File.regular?(path) do
      {:ok, path}
    else
      _ -> {:error, :not_found}
    end
  end

  defp decode_line(line) do
    case Jason.decode(line) do
      {:ok, %{} = event} -> [event]
      _ -> []
    end
  end

  # A run id names a directory; anything that could climb out of the project
  # directory is not a run id.
  defp bare_name?(name),
    do: is_binary(name) and name not in ["", ".", ".."] and Path.basename(name) == name
end
