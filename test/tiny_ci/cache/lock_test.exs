defmodule TinyCI.Cache.LockTest do
  use ExUnit.Case, async: true

  alias TinyCI.Cache.Lock

  @moduletag :tmp_dir

  defp lock_dir(%{tmp_dir: dir}), do: Path.join(dir, "lock")

  describe "with_lock/3" do
    test "returns the function's value and removes the lock dir", ctx do
      lock = lock_dir(ctx)
      assert Lock.with_lock(lock, fn -> :value end) == :value
      refute File.exists?(lock)
    end

    test "releases the lock when the function raises", ctx do
      lock = lock_dir(ctx)
      assert_raise RuntimeError, fn -> Lock.with_lock(lock, fn -> raise "boom" end) end
      refute File.exists?(lock)
    end

    test "a second process blocks until the first releases", ctx do
      lock = lock_dir(ctx)
      parent = self()

      holder =
        spawn_link(fn ->
          Lock.with_lock(lock, fn ->
            send(parent, :held)

            receive do
              :release -> :ok
            end
          end)
        end)

      assert_receive :held
      waiter = Task.async(fn -> Lock.with_lock(lock, [poll: 5], fn -> :got_it end) end)
      refute_receive {_ref, :got_it}, 50

      send(holder, :release)
      assert Task.await(waiter) == :got_it
      refute File.exists?(lock)
    end

    test "a stale lock is stolen", ctx do
      lock = lock_dir(ctx)
      File.mkdir_p!(lock)
      File.touch!(lock, 1_577_836_800)

      assert Lock.with_lock(lock, [stale_after: 60_000], fn -> :stolen end) == :stolen
      refute File.exists?(lock)
    end

    test "a fresh held lock raises LockTimeout after the timeout", ctx do
      lock = lock_dir(ctx)
      File.mkdir_p!(lock)

      assert_raise TinyCI.Cache.LockTimeout, fn ->
        Lock.with_lock(lock, [timeout: 100, poll: 10], fn -> :never end)
      end

      assert File.dir?(lock)
    end
  end
end
