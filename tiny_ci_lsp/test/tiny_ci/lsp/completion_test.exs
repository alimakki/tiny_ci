defmodule TinyCI.LSP.CompletionTest do
  use ExUnit.Case, async: true

  alias GenLSP.Structures.CompletionItem
  alias TinyCI.LSP.Completion

  defp labels(context), do: context |> Completion.items() |> Enum.map(& &1.label) |> Enum.sort()

  describe "items/1 by context" do
    test "top level offers the file-scope directives" do
      assert labels(:top_level) == ["env", "name", "on_failure", "on_success", "stage"]
    end

    test "stage body offers step and env" do
      assert labels(:stage_body) == ["env", "step"]
    end

    test "step body offers set" do
      assert labels(:step_body) == ["set"]
    end

    test "hook body offers set" do
      assert labels(:hook_body) == ["set"]
    end

    test "stage options offer the stage option keys" do
      assert labels(:stage_opts) ==
               ["allow_failure", "matrix", "max_parallel", "mode", "needs", "when", "working_dir"]
    end

    test "step options offer the step option keys" do
      assert "cmd" in labels(:step_opts)
      assert "cache" in labels(:step_opts)
      refute "matrix" in labels(:step_opts)
    end

    test "hook options offer the hook option keys" do
      assert labels(:hook_opts) == ["cmd", "env", "module", "timeout"]
    end

    test "condition offers the primitives" do
      assert labels(:condition) == ["branch()", "env(...)", "file_changed?(...)"]
    end

    test "unknown context offers nothing" do
      assert Completion.items(:unknown) == []
    end
  end

  describe "completion item shape" do
    test "option items insert a `key: ` snippet and carry documentation" do
      item = :stage_opts |> Completion.items() |> Enum.find(&(&1.label == "mode"))
      assert %CompletionItem{} = item
      assert item.insert_text == "mode: "
      assert item.detail =~ ":serial"
      assert %{value: doc} = item.documentation
      assert doc =~ "**mode**"
      assert doc =~ "mode: :serial"
    end

    test "directive items insert their name" do
      item = :top_level |> Completion.items() |> Enum.find(&(&1.label == "stage"))
      assert item.insert_text == "stage"
      assert item.documentation.value =~ "stage :build"
    end

    test "primitive items insert a callable form" do
      items = Completion.items(:condition)
      assert Enum.find(items, &(&1.label == "branch()")).insert_text == "branch()"
      assert Enum.find(items, &(&1.label == "env(...)")).insert_text == "env("
    end
  end
end
