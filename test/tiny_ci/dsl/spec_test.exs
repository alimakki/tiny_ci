defmodule TinyCI.DSL.SpecTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.Spec
  alias TinyCI.DSL.Spec.Entry

  describe "directives/1" do
    test "top-level offers the file-scope directives" do
      names = Spec.directives(:top_level) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:env, :name, :on_failure, :on_success, :stage]
    end

    test "stage body offers step and env" do
      names = Spec.directives(:stage) |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:env, :step]
    end

    test "step body offers set" do
      assert [%Entry{name: :set}] = Spec.directives(:step)
    end

    test "hook body offers set" do
      assert [%Entry{name: :set}] = Spec.directives(:hook)
    end

    test "every directive entry is tagged :directive" do
      assert Enum.all?(Spec.directives(), &(&1.kind == :directive))
    end
  end

  describe "options/1 and option_keys/1" do
    test "stage options match the documented set" do
      assert Spec.option_keys(:stage) |> Enum.sort() ==
               [:allow_failure, :matrix, :max_parallel, :mode, :needs, :when, :working_dir]
    end

    test "step options match the documented set" do
      assert Spec.option_keys(:step) |> Enum.sort() ==
               [
                 :allow_failure,
                 :artifact,
                 :cache,
                 :cmd,
                 :env,
                 :module,
                 :retry,
                 :retry_delay,
                 :timeout,
                 :when,
                 :working_dir
               ]
    end

    test "hook options match the documented set" do
      assert Spec.option_keys(:hook) |> Enum.sort() == [:cmd, :env, :module, :timeout]
    end

    test "options carry a type and are tagged :option" do
      for entry <- Spec.options(:stage) do
        assert entry.kind == :option
        assert is_binary(entry.type) and entry.type != ""
      end
    end
  end

  describe "condition_primitives/0" do
    test "offers the condition helpers" do
      names = Spec.condition_primitives() |> Enum.map(& &1.name) |> Enum.sort()
      assert names == [:branch, :env, :file_changed?]
    end

    test "primitives are tagged :primitive and scoped to :condition" do
      for entry <- Spec.condition_primitives() do
        assert entry.kind == :primitive
        assert :condition in entry.contexts
      end
    end
  end

  describe "metadata completeness" do
    test "every entry has a non-empty summary and example" do
      all = Spec.directives() ++ Spec.all_options() ++ Spec.condition_primitives()

      for entry <- all do
        assert is_binary(entry.summary) and entry.summary != "", "missing summary: #{entry.name}"
        assert is_binary(entry.example) and entry.example != "", "missing example: #{entry.name}"
      end
    end
  end

  describe "lookup/2" do
    test "finds a directive by name" do
      assert %Entry{name: :stage, kind: :directive} = Spec.lookup(:stage, :top_level)
    end

    test "finds an option scoped to its context" do
      assert %Entry{name: :mode, kind: :option} = Spec.lookup(:mode, :stage)
    end

    test "finds a condition primitive" do
      assert %Entry{name: :branch, kind: :primitive} = Spec.lookup(:branch, :condition)
    end

    test "disambiguates env by context" do
      assert %Entry{name: :env, kind: :directive} = Spec.lookup(:env, :top_level)
      assert %Entry{name: :env, kind: :option} = Spec.lookup(:env, :step)
      assert %Entry{name: :env, kind: :primitive} = Spec.lookup(:env, :condition)
    end

    test "accepts string names" do
      assert %Entry{name: :stage} = Spec.lookup("stage", :top_level)
    end

    test "falls back to any context when the given one has no match" do
      assert %Entry{name: :stage} = Spec.lookup(:stage, :step)
    end

    test "returns nil for unknown symbols" do
      assert Spec.lookup(:definitely_not_a_directive, :top_level) == nil
    end
  end
end
