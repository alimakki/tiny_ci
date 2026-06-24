defmodule DefnTarget do
  @moduledoc false
  def execute(_config, _ctx), do: :ok
end

defmodule TinyCI.LSP.DefinitionTest do
  use ExUnit.Case, async: true

  alias GenLSP.Structures.Location
  alias TinyCI.LSP.Definition

  @uri "file:///tmp/tiny_ci/pipeline.exs"

  # Resolve a definition at the `|` marker (0-based position).
  defp definition_at(source_with_marker) do
    [before, rest] = String.split(source_with_marker, "|", parts: 2)
    text = before <> rest

    lines_before = String.split(before, "\n")
    line = length(lines_before) - 1
    character = lines_before |> List.last() |> String.length()

    Definition.at(@uri, text, line, character)
  end

  describe "needs target → stage declaration" do
    test "jumps from a needs atom to its stage declaration" do
      source = """
      stage :build do
        step :c, cmd: "x"
      end

      stage :deploy, needs: [:bui|ld] do
        step :s, cmd: "x"
      end
      """

      assert %Location{uri: @uri, range: range} = definition_at(source)
      # `stage :build` is on line 0 (0-based).
      assert range.start.line == 0
      assert range.start.character == 0
    end

    test "returns nil for an atom that is not a stage name" do
      source = """
      stage :build, needs: [:gho|st] do
        step :s, cmd: "x"
      end
      """

      assert definition_at(source) == nil
    end
  end

  describe "module reference → module source" do
    test "jumps from a module alias to the module's source file" do
      source = """
      stage :build do
        step :run, module: Defn|Target
      end
      """

      assert %Location{uri: uri, range: range} = definition_at(source)
      assert uri =~ "definition_test.exs"
      assert String.starts_with?(uri, "file://")
      assert range.start.line == 0
    end

    test "returns nil for an unloadable module" do
      source = """
      stage :build do
        step :run, module: Totally.Bogus.Mod|ule
      end
      """

      assert definition_at(source) == nil
    end
  end

  describe "no definition" do
    test "returns nil over a plain command string" do
      source = """
      stage :build do
        step :run, cmd: "mi|x test"
      end
      """

      assert definition_at(source) == nil
    end

    test "returns nil over whitespace" do
      assert definition_at("stage :build do\n  | \nend") == nil
    end
  end
end
