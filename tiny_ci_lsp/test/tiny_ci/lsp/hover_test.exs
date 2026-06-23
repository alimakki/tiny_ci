defmodule TinyCI.LSP.HoverTest do
  use ExUnit.Case, async: true

  alias GenLSP.Structures.Hover
  alias TinyCI.LSP.Hover, as: HoverProvider

  # Hovers at the `|` marker (cursor placed inside the symbol). 0-based position.
  defp hover_at(source_with_marker) do
    [before, rest] = String.split(source_with_marker, "|", parts: 2)
    text = before <> rest

    lines_before = String.split(before, "\n")
    line = length(lines_before) - 1
    character = lines_before |> List.last() |> String.length()

    HoverProvider.at(text, line, character)
  end

  defp value(source), do: source |> hover_at() |> Map.fetch!(:contents) |> Map.fetch!(:value)

  describe "directives" do
    test "documents the stage directive" do
      assert %Hover{} = hover_at("sta|ge :build do\nend")
      doc = value("sta|ge :build do\nend")
      assert doc =~ "**stage**"
      assert doc =~ "stage :build"
    end

    test "documents step inside a stage" do
      assert value("stage :b do\n  st|ep :a, cmd: \"x\"\nend") =~ "**step**"
    end
  end

  describe "option keys" do
    test "documents a stage option key" do
      doc = value("stage :build, mo|de: :serial do\nend")
      assert doc =~ "**mode**"
      assert doc =~ ":serial"
    end

    test "documents a step option key" do
      assert value("stage :b do\n  step :a, ca|che: []\nend") =~ "**cache**"
    end
  end

  describe "condition primitives" do
    test "documents branch() inside a when value" do
      assert value("stage :build, when: bra|nch() == \"main\" do\nend") =~ "**branch**"
    end

    test "documents file_changed? inside a when value" do
      assert value("stage :b, when: file_chan|ged?(\"*.ex\") do\nend") =~ "**file_changed?**"
    end
  end

  describe "context disambiguation" do
    test "env at the top level resolves to the directive" do
      assert value("en|v MIX_ENV: \"test\"") =~ "shared by the steps"
    end

    test "env as a step option resolves to the option" do
      assert value("stage :b do\n  step :a, en|v: %{}\nend") =~ "merged over the stage"
    end

    test "env inside a when value resolves to the primitive" do
      assert value("stage :b, when: en|v(\"CI\") != nil do\nend") =~
               "environment variable, or nil"
    end
  end

  describe "no hover" do
    test "returns nil over an unknown symbol" do
      assert hover_at("stage :build do\n  step :a, cmd: \"x\"\n  bog|us :y\nend") == nil
    end

    test "returns nil over whitespace" do
      assert hover_at("stage :build do\n   | \nend") == nil
    end
  end
end
