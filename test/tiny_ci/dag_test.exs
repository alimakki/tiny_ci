defmodule TinyCI.DAGTest do
  use ExUnit.Case, async: true

  alias TinyCI.{DAG, Stage}

  defp stage(name, needs \\ []) do
    %Stage{name: name, needs: needs, steps: [], mode: :parallel}
  end

  describe "validate/1" do
    test "returns :ok for empty stage list" do
      assert :ok = DAG.validate([])
    end

    test "returns :ok for stages with no needs" do
      stages = [stage(:build), stage(:test), stage(:deploy)]
      assert :ok = DAG.validate(stages)
    end

    test "returns :ok for a valid linear dependency chain" do
      stages = [stage(:build), stage(:test, [:build]), stage(:deploy, [:test])]
      assert :ok = DAG.validate(stages)
    end

    test "returns :ok for a diamond dependency graph" do
      stages = [
        stage(:source),
        stage(:compile, [:source]),
        stage(:lint, [:source]),
        stage(:package, [:compile, :lint])
      ]

      assert :ok = DAG.validate(stages)
    end

    test "returns circular_dependency error for a direct self-loop" do
      stages = [stage(:a, [:a])]
      assert {:error, {:circular_dependency, cycle}} = DAG.validate(stages)
      assert :a in cycle
    end

    test "returns circular_dependency error for a two-stage cycle" do
      stages = [stage(:a, [:b]), stage(:b, [:a])]
      assert {:error, {:circular_dependency, cycle}} = DAG.validate(stages)
      assert :a in cycle
      assert :b in cycle
    end

    test "returns circular_dependency error for a three-stage cycle" do
      stages = [stage(:a, [:c]), stage(:b, [:a]), stage(:c, [:b])]
      assert {:error, {:circular_dependency, cycle}} = DAG.validate(stages)
      assert length(cycle) == 3
    end

    test "returns unknown_stages error for a reference to an undefined stage" do
      stages = [stage(:deploy, [:build])]
      assert {:error, {:unknown_stages, errors}} = DAG.validate(stages)
      assert Enum.any?(errors, &String.contains?(&1, "build"))
    end

    test "returns unknown_stages error listing all missing references" do
      stages = [stage(:deploy, [:build, :test])]
      assert {:error, {:unknown_stages, errors}} = DAG.validate(stages)
      assert length(errors) == 2
    end
  end

  describe "build_levels/1" do
    test "returns empty list for empty input" do
      assert {:ok, []} = DAG.build_levels([])
    end

    test "puts all independent stages in one level" do
      stages = [stage(:a), stage(:b), stage(:c)]
      assert {:ok, [level]} = DAG.build_levels(stages)
      names = MapSet.new(level, & &1.name)
      assert names == MapSet.new([:a, :b, :c])
    end

    test "separates dependent stages into sequential levels" do
      stages = [stage(:build), stage(:test, [:build])]
      assert {:ok, [level0, level1]} = DAG.build_levels(stages)
      assert [%Stage{name: :build}] = level0
      assert [%Stage{name: :test}] = level1
    end

    test "fan-out: one stage, two parallel dependents" do
      stages = [stage(:source), stage(:lint, [:source]), stage(:test, [:source])]
      assert {:ok, [level0, level1]} = DAG.build_levels(stages)
      assert [%Stage{name: :source}] = level0
      assert length(level1) == 2
      names = MapSet.new(level1, & &1.name)
      assert names == MapSet.new([:lint, :test])
    end

    test "fan-in: two parallel stages feed one stage" do
      stages = [stage(:build), stage(:lint), stage(:package, [:build, :lint])]
      assert {:ok, [level0, level1]} = DAG.build_levels(stages)
      assert length(level0) == 2
      assert [%Stage{name: :package}] = level1
    end

    test "diamond: source -> {compile, lint} -> package" do
      stages = [
        stage(:source),
        stage(:compile, [:source]),
        stage(:lint, [:source]),
        stage(:package, [:compile, :lint])
      ]

      assert {:ok, [level0, level1, level2]} = DAG.build_levels(stages)
      assert [%Stage{name: :source}] = level0
      assert length(level1) == 2
      assert [%Stage{name: :package}] = level2
    end
  end

  describe "dag_mode?/1" do
    test "returns false when no stage has needs" do
      stages = [stage(:a), stage(:b)]
      refute DAG.dag_mode?(stages)
    end

    test "returns true when at least one stage has needs" do
      stages = [stage(:a), stage(:b, [:a])]
      assert DAG.dag_mode?(stages)
    end

    test "returns false for empty list" do
      refute DAG.dag_mode?([])
    end
  end
end
