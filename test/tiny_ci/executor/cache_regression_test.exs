defmodule TinyCI.Executor.CacheRegressionTest do
  # The cache location is configured through global application environment.
  use ExUnit.Case, async: false

  alias TinyCI.{Executor, RegressionActions, Stage, Step}

  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    previous = Application.fetch_env(:tiny_ci, :cache_base_dir)
    Application.put_env(:tiny_ci, :cache_base_dir, Path.join(root, "cache"))
    File.mkdir_p!(Path.join(root, "deps"))
    File.write!(Path.join(root, "mix.lock"), "locked")
    File.write!(Path.join(root, "deps/item"), "cached")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:tiny_ci, :cache_base_dir, value)
        :error -> Application.delete_env(:tiny_ci, :cache_base_dir)
      end
    end)
  end

  defp run(root, attrs) do
    step = struct!(Step, [name: :cached, cache: %{paths: ["deps"], key: "mix.lock"}] ++ attrs)

    Executor.execute(
      %Stage{name: :cached, steps: [step]},
      %{root: root},
      :buffered,
      TinyCI.Listener.Silent
    )
  end

  test "a changed command cannot reuse a passing result", %{tmp_dir: root} do
    assert run(root, cmd: "true").status == :passed
    assert run(root, cmd: "false").status == :failed
  end

  test "a changed effective environment invalidates the cache", %{tmp_dir: root} do
    cmd = "test \"$VALUE\" = good"
    assert run(root, cmd: cmd, env: %{"VALUE" => "good"}).status == :passed
    assert run(root, cmd: cmd, env: %{"VALUE" => "bad"}).status == :failed
  end

  test "a changed working directory invalidates the cache", %{tmp_dir: root} do
    File.mkdir_p!(Path.join(root, "other"))
    assert run(root, cmd: "test -d deps").status == :passed
    assert run(root, cmd: "test -d deps", working_dir: "other").status == :failed
  end

  test "module caches never discard action store writes", %{tmp_dir: root} do
    for _ <- 1..2 do
      assert %{status: :passed, store: %{tag: "new"}} = run(root, module: RegressionActions)
    end
  end
end
