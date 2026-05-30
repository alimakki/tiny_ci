defmodule TinyCI.Cache do
  @moduledoc """
  Local filesystem cache for pipeline steps.

  Cache entries are keyed by the SHA256 hash of a designated file (e.g. `mix.lock`).
  Directories are stored at `~/.cache/tiny_ci/<project_id>/<cache_key>/`.

  A project ID is derived from the pipeline root path so that different projects
  maintain independent caches while sharing the same cache base directory.
  """

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

  @doc "Returns the full cache entry directory path for the given root and key."
  @spec cache_entry_dir(String.t(), String.t()) :: String.t()
  def cache_entry_dir(root, key) do
    Path.join([base_dir(), project_id(root), key])
  end

  @doc """
  Returns `true` when a valid cache entry exists for all declared paths.

  A hit requires the entry directory to exist and every path inside it.
  """
  @spec hit?(String.t(), String.t(), [String.t()]) :: boolean()
  def hit?(root, key, paths) do
    entry_dir = cache_entry_dir(root, key)

    File.dir?(entry_dir) and
      Enum.all?(paths, fn p -> File.exists?(Path.join(entry_dir, p)) end)
  end

  @doc """
  Restores cached directories into `working_dir` (falls back to `root`).

  Each path in `paths` is copied from the cache entry into `working_dir/<path>`.
  Existing destination trees are replaced.
  """
  @spec restore(String.t(), String.t(), [String.t()], String.t() | nil) :: :ok
  def restore(root, key, paths, working_dir) do
    entry_dir = cache_entry_dir(root, key)
    dest_base = working_dir || root

    Enum.each(paths, fn path ->
      src = Path.join(entry_dir, path)
      dst = Path.join(dest_base, path)
      File.rm_rf!(dst)
      File.mkdir_p!(Path.dirname(dst))
      copy_path(src, dst)
    end)

    :ok
  end

  @doc """
  Saves directories from `working_dir` (falls back to `root`) into the cache.

  Each path in `paths` is copied from `working_dir/<path>` to the cache entry.
  Paths that do not exist in the working directory are silently skipped.
  """
  @spec save(String.t(), String.t(), [String.t()], String.t() | nil) :: :ok
  def save(root, key, paths, working_dir) do
    entry_dir = cache_entry_dir(root, key)
    src_base = working_dir || root

    Enum.each(paths, fn path ->
      src = Path.join(src_base, path)

      if File.exists?(src) do
        dst = Path.join(entry_dir, path)
        File.rm_rf!(dst)
        File.mkdir_p!(Path.dirname(dst))
        copy_path(src, dst)
      end
    end)

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

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

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
end
