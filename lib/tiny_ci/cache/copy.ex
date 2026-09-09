defmodule TinyCI.Cache.Copy do
  @moduledoc """
  Copies a file or directory tree for the cache, cloning blocks where the
  filesystem can.

  On macOS `cp -c` asks APFS to clone; on Linux `--reflink=auto` does the same
  on Btrfs/XFS. Both fall back to a plain copy on filesystems that cannot clone,
  and everything else falls back to `File.cp_r/2`. Hardlinks are deliberately
  not used: a hardlinked file shares its inode with the working tree, so an
  in-place write in either place would corrupt the other. Symlinks are copied
  as symlinks.
  """

  @doc """
  Copies `src` (a file or a directory) to `dst`, creating `dst`'s parent.

  `dst` must not already exist. Returns `:ok` or `{:error, reason}`.
  """
  @spec copy_tree(String.t(), String.t()) :: :ok | {:error, term()}
  def copy_tree(src, dst) do
    if File.exists?(src) or symlink?(src) do
      File.mkdir_p!(Path.dirname(dst))
      do_copy(:os.type(), src, dst)
    else
      {:error, :enoent}
    end
  end

  defp do_copy({:unix, :darwin}, src, dst) do
    case cp(["-Rpc", src, dst]) do
      :ok -> :ok
      {:error, _} -> retry_plain(["-Rp", src, dst], src, dst)
    end
  end

  defp do_copy({:unix, :linux}, src, dst) do
    case cp(["-Rp", "--reflink=auto", src, dst]) do
      :ok -> :ok
      {:error, _} -> retry_plain(["-Rp", src, dst], src, dst)
    end
  end

  defp do_copy(_other, src, dst), do: fallback(src, dst)

  # A failed clone may have left a partial destination behind; clear it before
  # the plain copy, and fall back to Elixir's copier if `cp` itself is missing.
  defp retry_plain(args, src, dst) do
    File.rm_rf(dst)

    case cp(args) do
      :ok -> :ok
      {:error, :no_cp} -> fallback(src, dst)
      {:error, _} = error -> error
    end
  end

  defp cp(args) do
    case System.find_executable("cp") do
      nil ->
        {:error, :no_cp}

      exe ->
        case System.cmd(exe, args, stderr_to_stdout: true) do
          {_, 0} -> :ok
          {output, status} -> {:error, {:cp_failed, status, String.trim(output)}}
        end
    end
  end

  defp fallback(src, dst) do
    File.rm_rf(dst)

    case File.cp_r(src, dst) do
      {:ok, _} -> :ok
      {:error, reason, path} -> {:error, {reason, path}}
    end
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end
end
