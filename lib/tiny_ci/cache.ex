defmodule TinyCI.Cache do
  @moduledoc """
  Local filesystem cache for pipeline steps.

  Cache entries are keyed by the SHA256 hash of a designated file (e.g. `mix.lock`).
  Directories are stored at `~/.cache/tiny_ci/<project_id>/<cache_key>/`.

  A project ID is derived from the pipeline root path so that different projects
  maintain independent caches while sharing the same cache base directory.

  ## Atomicity and locking

  An entry is either complete or absent. A save copies into a staging directory
  under `<project>/.tmp/`, writes `.meta.json`, and then publishes it with a single
  `File.rename/2` — so an interrupted save leaves at most a stale staging directory,
  never a half-written entry. Savers and restorers of one key serialise on a
  `TinyCI.Cache.Lock` under `<project>/.lock/<key>/`, which works across OS
  processes, so concurrent matrix combinations, DAG stages, or runs cannot
  interleave. Copies go through `TinyCI.Cache.Copy`, which clones blocks where
  the filesystem supports it.

  An entry without `.meta.json` predates this scheme and is treated as a miss so
  it gets rewritten atomically.

  ## Eviction

  `prune/1` removes entries unused for longer than `max_age_days`, then the
  least recently used entries until the cache is under `max_bytes`. It runs
  with the default limits after every save and on demand via
  `mix tiny_ci.cache prune`.
  """

  alias TinyCI.Cache.{Copy, Lock, LockTimeout}

  @meta_file ".meta.json"
  @tmp_dir ".tmp"
  @lock_dir ".lock"
  @default_max_bytes 5 * 1024 * 1024 * 1024
  @default_max_age_days 30
  @stage_max_age_seconds 3600

  @doc "Returns the base cache directory, configurable via :tiny_ci :cache_base_dir."
  def base_dir do
    Application.get_env(
      :tiny_ci,
      :cache_base_dir,
      Path.join(System.user_home!(), ".cache/tiny_ci")
    )
  end

  @doc "Computes a stable 16-character project identifier from the root path."
  def project_id(root) do
    :crypto.hash(:sha256, root)
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc """
  Computes the cache key as the hex-encoded SHA256 of the key file's contents.

  Returns `{:ok, hex_key}` or `{:error, reason}` if the file cannot be read.
  """
  @spec compute_key(String.t()) :: {:ok, String.t()} | {:error, term()}
  def compute_key(key_file_path) do
    case File.read(key_file_path) do
      {:ok, content} ->
        key = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
        {:ok, key}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Hashes the key file's contents together with explicit execution inputs.

  Callers supply deterministic terms describing command/action, runtime, matrix,
  environment, and effective working directory as appropriate. Use maps for
  unordered inputs; list and tuple order is significant. No ambient context is
  captured. File contents and inputs are encoded as a deterministic Erlang tuple
  before hashing so their boundaries cannot collide.

  Returns `{:ok, hex_key}` or `{:error, reason}` if the file cannot be read.
  `compute_key/1` retains its content-only key format.
  """
  @spec compute_key(String.t(), term()) :: {:ok, String.t()} | {:error, term()}
  def compute_key(key_file_path, inputs) do
    with {:ok, content} <- File.read(key_file_path) do
      encoded = :erlang.term_to_binary({content, inputs}, [:deterministic])
      {:ok, :crypto.hash(:sha256, encoded) |> Base.encode16(case: :lower)}
    end
  end

  @doc "Returns the full cache entry directory path for the given root and key."
  @spec cache_entry_dir(String.t(), String.t()) :: String.t()
  def cache_entry_dir(root, key) do
    Path.join([base_dir(), project_id(root), key])
  end

  @doc """
  Returns `true` when a complete cache entry exists for all declared paths.

  A hit requires the entry's `.meta.json` and every declared path to be present.
  """
  @spec hit?(String.t(), String.t(), [String.t()]) :: boolean()
  def hit?(root, key, paths) do
    entry_dir = cache_entry_dir(root, key)

    File.exists?(Path.join(entry_dir, @meta_file)) and
      Enum.all?(paths, fn p -> File.exists?(Path.join(entry_dir, p)) end)
  end

  @doc """
  Restores cached directories into `working_dir` (falls back to `root`).

  Returns `:ok` even on a miss. Use `restore_if_present/4` when deciding whether
  execution can be skipped.
  """
  @spec restore(String.t(), String.t(), [String.t()], String.t() | nil) :: :ok
  def restore(root, key, paths, working_dir) do
    restore_if_present(root, key, paths, working_dir)
    :ok
  end

  @doc """
  Checks completeness and restores an entry while holding the same entry lock.

  Returns `:hit` after replacing all declared destination paths and marking the
  entry as used, or `:miss` without modifying the working directory or metadata.
  `working_dir` falls back to `root` when nil. Savers and pruners use this lock
  too, so neither can remove or replace the entry between the check and copy.
  """
  @spec restore_if_present(String.t(), String.t(), [String.t()], String.t() | nil) :: :hit | :miss
  def restore_if_present(root, key, paths, working_dir) do
    entry_dir = cache_entry_dir(root, key)
    dest_base = working_dir || root

    with_entry_lock(root, key, fn ->
      if hit?(root, key, paths) do
        Enum.each(paths, &restore_path(Path.join(entry_dir, &1), Path.join(dest_base, &1)))
        touch_last_used(entry_dir)
        :hit
      else
        :miss
      end
    end)
  end

  defp restore_path(src, dst) do
    File.rm_rf!(dst)
    :ok = Copy.copy_tree(src, dst)
  end

  @doc """
  Saves directories from `working_dir` (falls back to `root`) into the cache.

  Each path in `paths` is copied from `working_dir/<path>` into a staging
  directory, which is then published atomically as the entry. Paths that do not
  exist in the working directory are silently skipped; when none exist, nothing
  is saved. A successful save is followed by `prune/1` with the default limits.
  """
  @spec save(String.t(), String.t(), [String.t()], String.t() | nil) :: :ok
  def save(root, key, paths, working_dir) do
    src_base = working_dir || root

    if Enum.any?(paths, &File.exists?(Path.join(src_base, &1))) do
      with_entry_lock(root, key, fn ->
        stage = stage_entry(root, key, paths, working_dir)
        commit_entry(root, key, stage)
      end)

      prune([])
    end

    :ok
  end

  @doc false
  # Copies the existing `paths` into a fresh staging directory under
  # `<project>/.tmp/` and writes its metadata. Returns the staging path; the
  # entry is not visible until `commit_entry/3`. Public so tests can interrupt a
  # save between the two halves.
  @spec stage_entry(String.t(), String.t(), [String.t()], String.t() | nil) :: String.t()
  def stage_entry(root, key, paths, working_dir) do
    src_base = working_dir || root
    stage = Path.join(project_tmp_dir(root), "#{key}-#{unique()}")
    File.mkdir_p!(stage)

    saved_paths =
      Enum.filter(paths, fn path ->
        src = Path.join(src_base, path)

        if File.exists?(src) do
          :ok = Copy.copy_tree(src, Path.join(stage, path))
          true
        else
          false
        end
      end)

    now = DateTime.utc_now() |> DateTime.to_iso8601()

    write_meta(stage, %{
      "saved_at" => now,
      "last_used_at" => now,
      "paths" => saved_paths,
      "bytes" => tree_bytes(stage)
    })

    stage
  end

  @doc false
  # Publishes a staged entry by renaming it into place. An existing entry is
  # renamed aside first (rename onto a non-empty directory fails) and removed
  # after the new one is live. Both renames stay on one filesystem.
  @spec commit_entry(String.t(), String.t(), String.t()) :: :ok
  def commit_entry(root, key, stage) do
    entry_dir = cache_entry_dir(root, key)
    File.mkdir_p!(Path.dirname(entry_dir))
    old = Path.join(project_tmp_dir(root), "#{key}-old-#{unique()}")

    if File.exists?(entry_dir), do: File.rename!(entry_dir, old)
    File.rename!(stage, entry_dir)
    File.rm_rf!(old)
    :ok
  end

  @doc """
  Removes all cache entries for the given project root.

  Returns `:ok` regardless of whether entries existed.
  """
  @spec clean(String.t()) :: :ok
  def clean(root) do
    project_dir = Path.join(base_dir(), project_id(root))
    File.rm_rf!(project_dir)
    :ok
  end

  @doc """
  Evicts cache entries across every project under `base_dir/0`.

  Removes entries whose `last_used_at` is older than `:max_age_days`, then the
  least recently used entries until the total is under `:max_bytes`, and any
  staging directory older than an hour. An entry whose lock is currently held
  is never removed.

  ## Options

    * `:max_bytes` — default 5 GiB; overridden by `TINY_CI_CACHE_MAX_BYTES` or
      application env `:cache_max_bytes`.
    * `:max_age_days` — default 30; overridden by `TINY_CI_CACHE_MAX_AGE_DAYS` or
      application env `:cache_max_age_days`.

  Returns `%{removed: count, bytes_freed: bytes}`.
  """
  @spec prune(keyword()) :: %{removed: non_neg_integer(), bytes_freed: non_neg_integer()}
  def prune(opts \\ []) do
    max_bytes = limit(opts, :max_bytes, "TINY_CI_CACHE_MAX_BYTES", @default_max_bytes)
    max_age_days = limit(opts, :max_age_days, "TINY_CI_CACHE_MAX_AGE_DAYS", @default_max_age_days)
    Enum.each(project_dirs(), &prune_stale_stages/1)

    cutoff = DateTime.add(DateTime.utc_now(), -max_age_days * 86_400, :second)

    {expired, live} =
      Enum.split_with(entries(), &(DateTime.compare(&1.last_used_at, cutoff) == :lt))

    removed_expired = Enum.filter(expired, &remove_entry/1)

    live_bytes = live |> Enum.map(& &1.bytes) |> Enum.sum()

    removed_lru =
      live |> Enum.sort_by(& &1.last_used_at, DateTime) |> evict_lru(live_bytes, max_bytes)

    removed = removed_expired ++ removed_lru
    %{removed: length(removed), bytes_freed: removed |> Enum.map(& &1.bytes) |> Enum.sum()}
  end

  @doc """
  Summarises the cache: `%{entries: n, bytes: total, projects: n}`.
  """
  @spec stats() :: %{
          entries: non_neg_integer(),
          bytes: non_neg_integer(),
          projects: non_neg_integer()
        }
  def stats do
    all = entries()

    %{
      entries: length(all),
      bytes: all |> Enum.map(& &1.bytes) |> Enum.sum(),
      projects: all |> Enum.map(& &1.project_dir) |> Enum.uniq() |> length()
    }
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp with_entry_lock(root, key, fun) do
    Lock.with_lock(lock_dir(Path.join(base_dir(), project_id(root)), key), fun)
  end

  defp lock_dir(project_dir, key), do: Path.join([project_dir, @lock_dir, key])
  defp project_tmp_dir(root), do: Path.join([base_dir(), project_id(root), @tmp_dir])
  defp unique, do: Integer.to_string(System.unique_integer([:positive]))

  defp write_meta(dir, meta) do
    File.write!(Path.join(dir, @meta_file), Jason.encode!(meta))
  end

  # Rewritten through a temp file + rename so a reader never sees a torn file.
  defp touch_last_used(entry_dir) do
    with {:ok, meta} <- read_meta(entry_dir) do
      now = DateTime.utc_now() |> DateTime.to_iso8601()
      tmp = Path.join(entry_dir, @meta_file <> ".tmp")
      File.write!(tmp, Jason.encode!(%{meta | "last_used_at" => now}))
      File.rename!(tmp, Path.join(entry_dir, @meta_file))
    end

    :ok
  end

  defp read_meta(entry_dir) do
    with {:ok, json} <- File.read(Path.join(entry_dir, @meta_file)),
         {:ok, %{} = meta} <- Jason.decode(json) do
      {:ok, meta}
    else
      _ -> :error
    end
  end

  defp tree_bytes(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        path |> File.ls!() |> Enum.map(&tree_bytes(Path.join(path, &1))) |> Enum.sum()

      {:ok, %File.Stat{type: :regular, size: size}} ->
        size

      _ ->
        0
    end
  end

  defp limit(opts, key, env_var, default) do
    opts[key] || env_limit(env_var) || Application.get_env(:tiny_ci, :"cache_#{key}") || default
  end

  defp env_limit(env_var) do
    case System.get_env(env_var) do
      nil -> nil
      value -> parse_limit(value)
    end
  end

  defp parse_limit(value) do
    case Integer.parse(String.trim(value)) do
      {n, ""} when n >= 0 -> n
      _ -> nil
    end
  end

  defp project_dirs do
    base = base_dir()

    case File.ls(base) do
      {:ok, names} -> names |> Enum.map(&Path.join(base, &1)) |> Enum.filter(&File.dir?/1)
      {:error, _} -> []
    end
  end

  defp entries do
    Enum.flat_map(project_dirs(), fn project_dir ->
      project_dir
      |> File.ls!()
      |> Enum.reject(&(&1 in [@tmp_dir, @lock_dir]))
      |> Enum.map(&Path.join(project_dir, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(&entry_info(project_dir, &1))
    end)
  end

  # A pre-metadata entry is measured by walking it and dated by its mtime, so
  # age-based eviction still reaches it eventually.
  defp entry_info(project_dir, dir) do
    base = %{project_dir: project_dir, dir: dir, key: Path.basename(dir)}

    case read_meta(dir) do
      {:ok, meta} ->
        Map.merge(base, %{
          last_used_at: parse_time(meta["last_used_at"]) || mtime(dir),
          bytes: if(is_integer(meta["bytes"]), do: meta["bytes"], else: tree_bytes(dir))
        })

      :error ->
        Map.merge(base, %{last_used_at: mtime(dir), bytes: tree_bytes(dir)})
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: t}} -> DateTime.from_unix!(t)
      _ -> DateTime.from_unix!(0)
    end
  end

  defp evict_lru(_sorted, total, max_bytes) when total <= max_bytes, do: []

  defp evict_lru([], _total, _max_bytes), do: []

  defp evict_lru([entry | rest], total, max_bytes) do
    if remove_entry(entry) do
      [entry | evict_lru(rest, total - entry.bytes, max_bytes)]
    else
      evict_lru(rest, total, max_bytes)
    end
  end

  # Takes the entry's own lock with no wait: a held lock means a save or restore
  # is in flight, and that entry is left alone this round.
  defp remove_entry(%{project_dir: project_dir, key: key, dir: dir}) do
    Lock.with_lock(lock_dir(project_dir, key), [timeout: 0], fn ->
      File.rm_rf!(dir)
      true
    end)
  rescue
    LockTimeout -> false
  end

  defp prune_stale_stages(project_dir) do
    tmp = Path.join(project_dir, @tmp_dir)
    cutoff = System.os_time(:second) - @stage_max_age_seconds

    case File.ls(tmp) do
      {:ok, names} ->
        names
        |> Enum.map(&Path.join(tmp, &1))
        |> Enum.filter(fn path ->
          match?({:ok, %File.Stat{mtime: t}} when t < cutoff, File.stat(path, time: :posix))
        end)
        |> Enum.each(&File.rm_rf!/1)

      {:error, _} ->
        :ok
    end
  end
end
