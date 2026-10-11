defmodule AuditLocalAction do
  @moduledoc false
  def execute(_config, _ctx), do: :ok
end

defmodule TinyCI.Action.AuditTest do
  use ExUnit.Case, async: true

  alias TinyCI.Action.Audit
  alias TinyCI.{PipelineSpec, Stage, Step}

  defp spec(modules) do
    steps = Enum.map(modules, fn m -> %Step{name: :s, module: m} end)

    %PipelineSpec{
      name: :p,
      stages: [%Stage{name: :a, steps: steps}],
      hooks: %{on_success: [], on_failure: []}
    }
  end

  describe "analyze/3 against the real lockfile" do
    test "classifies a hex dep, the root app, and a local module" do
      {:ok, entries} =
        Audit.analyze(spec([Jason, TinyCI.DAG, AuditLocalAction]), File.cwd!(),
          root_app: :tiny_ci
        )

      by_module = Map.new(entries, &{&1.module, &1})

      assert by_module[Jason].source == :hex
      assert by_module[Jason].status == :ok
      assert by_module[Jason].version =~ ~r/^\d+\./
      assert by_module[Jason].checksum != nil

      assert by_module[TinyCI.DAG].source == :first_party
      assert by_module[AuditLocalAction].source == :local
    end

    test "verify/3 passes when every action is locked or first-party" do
      assert Audit.verify(spec([Jason, TinyCI.DAG]), File.cwd!(), root_app: :tiny_ci) == :ok
    end
  end

  describe "verify/3 fail-closed" do
    @tag :tmp_dir
    test "a hex dep missing from the lockfile is refused", %{tmp_dir: dir} do
      lock = Path.join(dir, "mix.lock")
      File.write!(lock, "%{}")

      assert {:error, {:action_lock, [message]}} =
               Audit.verify(spec([Jason]), dir, root_app: :tiny_ci, lock_path: lock)

      assert message =~ ":jason"
      assert message =~ "lockfile" or message =~ "pinned"
    end
  end

  describe "format/1" do
    test "renders a tree with status marks" do
      {:ok, entries} =
        Audit.analyze(spec([Jason, AuditLocalAction]), File.cwd!(), root_app: :tiny_ci)

      output = Audit.format(entries)
      assert output =~ "Resolved actions (2)"
      assert output =~ "Jason"
      assert output =~ "✓"
    end

    test "handles a pipeline with no module actions" do
      assert Audit.format([]) =~ "No module actions"
    end
  end

  describe "no lockfile (not an Elixir project)" do
    @tag :tmp_dir
    test "lockfile_status/2 is :missing when there is no mix.lock", %{tmp_dir: dir} do
      assert Audit.lockfile_status(dir) == :missing
    end

    @tag :tmp_dir
    test "a present lockfile is :present", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "mix.lock"), "%{}")
      assert Audit.lockfile_status(dir) == :present
    end

    @tag :tmp_dir
    test "format/2 notes the missing lockfile when nothing errored", %{tmp_dir: dir} do
      {:ok, entries} = Audit.analyze(spec([AuditLocalAction]), dir, root_app: nil)

      output = Audit.format(entries, lockfile: :missing)
      assert output =~ "Resolved actions (1)"
      assert output =~ "no lockfile (not an Elixir project)"
    end

    @tag :tmp_dir
    test "the note also appears when the pipeline has no module actions", %{tmp_dir: dir} do
      {:ok, entries} = Audit.analyze(spec([]), dir, root_app: nil)

      assert Audit.format(entries, lockfile: :missing) =~
               "no lockfile (not an Elixir project)"
    end

    @tag :tmp_dir
    test "an erroring action is not hidden behind the note", %{tmp_dir: dir} do
      {:ok, entries} = Audit.analyze(spec([Jason]), dir, root_app: :tiny_ci)

      refute Audit.format(entries, lockfile: :missing) =~ "no lockfile"
    end

    @tag :tmp_dir
    test "verify/3 fails closed for a third-party action with no lockfile at all", %{tmp_dir: dir} do
      assert {:error, {:action_lock, [message]}} =
               Audit.verify(spec([Jason]), dir, root_app: :tiny_ci)

      assert message =~ ":jason"
      assert message =~ "lockfile" or message =~ "pinned"
    end

    @tag :tmp_dir
    test "verify/3 passes for local actions with no lockfile", %{tmp_dir: dir} do
      assert Audit.verify(spec([AuditLocalAction]), dir, root_app: nil) == :ok
    end
  end
end
