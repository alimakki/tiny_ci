defmodule TinyCI.LSP.ContextTest do
  use ExUnit.Case, async: true

  alias TinyCI.LSP.Context

  # Calls Context.at/3 with the cursor placed where the `|` marker appears.
  # The marker is stripped before analysis; LSP positions are 0-based.
  defp context_at(source_with_marker) do
    [before, rest] = String.split(source_with_marker, "|", parts: 2)
    text = before <> rest

    lines_before = String.split(before, "\n")
    line = length(lines_before) - 1
    character = lines_before |> List.last() |> String.length()

    Context.at(text, line, character)
  end

  describe "top level" do
    test "empty buffer" do
      assert context_at("|") == :top_level
    end

    test "partial directive at file scope" do
      assert context_at("st|") == :top_level
    end

    test "between top-level statements" do
      assert context_at("name :p\n\n|\n\nstage :x do\nend") == :top_level
    end
  end

  describe "stage body" do
    test "inside a stage do block" do
      assert context_at("stage :build do\n  |\nend") == :stage_body
    end

    test "after an existing step in a stage" do
      assert context_at("stage :build do\n  step :a, cmd: \"x\"\n  |\nend") == :stage_body
    end
  end

  describe "step body" do
    test "inside a step do block" do
      assert context_at("stage :build do\n  step :a do\n    |\n  end\nend") == :step_body
    end
  end

  describe "hook body" do
    test "inside an on_success do block" do
      assert context_at("on_success :notify do\n  |\nend") == :hook_body
    end

    test "inside an on_failure do block" do
      assert context_at("on_failure :alert do\n  |\nend") == :hook_body
    end
  end

  describe "option contexts" do
    test "stage options after the name" do
      assert context_at("stage :build, |") == :stage_opts
    end

    test "stage options mid-key" do
      assert context_at("stage :build, mo|") == :stage_opts
    end

    test "step options after the name" do
      assert context_at("stage :build do\n  step :a, |\nend") == :step_opts
    end

    test "hook options after the name" do
      assert context_at("on_success :notify, |") == :hook_opts
    end
  end

  describe "condition context" do
    test "inside a stage when value" do
      assert context_at("stage :build, when: |") == :condition
    end

    test "mid-expression inside a when value" do
      assert context_at("stage :build, when: branch() == \"main\" and |") == :condition
    end

    test "inside a step when value" do
      assert context_at("stage :build do\n  step :a, cmd: \"x\", when: |\nend") == :condition
    end
  end

  describe "unparseable input" do
    test "returns :unknown when the fragment cannot be analyzed" do
      assert Context.at("@@@ %%% !!!", 0, 11) in [:top_level, :unknown]
    end
  end
end
