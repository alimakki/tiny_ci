defmodule TinyCI.Cache.LockTimeout do
  @moduledoc """
  Raised by `TinyCI.Cache.Lock.with_lock/3` when a lock stays held past the timeout.
  """
  defexception [:message, :lock_dir]

  @impl true
  def exception(opts) do
    lock_dir = Keyword.fetch!(opts, :lock_dir)
    timeout = Keyword.fetch!(opts, :timeout)

    %__MODULE__{
      lock_dir: lock_dir,
      message: "timed out after #{timeout}ms waiting for cache lock #{lock_dir}"
    }
  end
end

defmodule TinyCI.Cache.Lock do
  @moduledoc """
  A filesystem advisory lock that works across OS processes.

  The cache is shared by every run on a machine — parallel matrix combinations,
  DAG stages, and (later) concurrent server runs — so a lock held in one BEAM
  is not enough. This lock is a directory: `File.mkdir/1` is atomic on POSIX,
  so whoever creates the directory holds the lock, and everyone else polls until
  it disappears. A lock whose directory is older than `:stale_after` is assumed
  to belong to a dead process and is stolen.
  """

  alias TinyCI.Cache.LockTimeout

  @default_timeout 60_000
  @default_stale_after 600_000
  @default_poll 50

  @doc """
  Runs `fun` while holding the lock at `lock_dir`, releasing it afterwards.

  ## Options

    * `:timeout` — how long to wait for a held lock, in ms (default 60 000).
      Raises `TinyCI.Cache.LockTimeout` when it elapses.
    * `:stale_after` — a held lock older than this many ms is removed and
      re-acquired (default 600 000).
    * `:poll` — ms between acquisition attempts (default 50).

  The lock directory is always removed when `fun` returns or raises.
  """
  @spec with_lock(String.t(), keyword(), (-> result)) :: result when result: term()
  def with_lock(lock_dir, opts \\ [], fun) when is_function(fun, 0) do
    acquire(lock_dir, opts, System.monotonic_time(:millisecond))

    try do
      fun.()
    after
      File.rm_rf(lock_dir)
    end
  end

  defp acquire(lock_dir, opts, started_at) do
    File.mkdir_p!(Path.dirname(lock_dir))

    case File.mkdir(lock_dir) do
      :ok ->
        write_owner(lock_dir)

      {:error, :eexist} ->
        if stale?(lock_dir, Keyword.get(opts, :stale_after, @default_stale_after)) do
          File.rm_rf(lock_dir)
        else
          wait_or_raise(lock_dir, opts, started_at)
        end

        acquire(lock_dir, opts, started_at)

      {:error, reason} ->
        raise File.Error, reason: reason, action: "create lock directory", path: lock_dir
    end
  end

  defp wait_or_raise(lock_dir, opts, started_at) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    if System.monotonic_time(:millisecond) - started_at >= timeout do
      raise LockTimeout, lock_dir: lock_dir, timeout: timeout
    end

    Process.sleep(Keyword.get(opts, :poll, @default_poll))
  end

  # The owner file is purely diagnostic: it tells a human who held a lock that
  # looks stuck. Locking correctness never depends on it.
  defp write_owner(lock_dir) do
    owner = "#{System.pid()} #{node()} #{DateTime.utc_now()}\n"
    File.write(Path.join(lock_dir, "owner"), owner)
    :ok
  end

  defp stale?(lock_dir, stale_after) do
    case File.stat(lock_dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> (System.os_time(:second) - mtime) * 1000 > stale_after
      # Vanished between mkdir and stat: the holder just released it.
      {:error, _} -> false
    end
  end
end
