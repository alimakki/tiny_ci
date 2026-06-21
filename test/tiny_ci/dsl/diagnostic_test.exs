defmodule TinyCI.DSL.DiagnosticTest do
  use ExUnit.Case, async: true

  alias TinyCI.DSL.Diagnostic

  doctest TinyCI.DSL.Diagnostic

  describe "new/3" do
    test "defaults span to start of file and severity to :error" do
      d = Diagnostic.new("boom")
      assert d.message == "boom"
      assert d.line == 1
      assert d.column == 1
      assert d.severity == :error
      assert d.end_line == nil
      assert d.end_column == nil
    end

    test "reads line and column from AST metadata" do
      d = Diagnostic.new("boom", line: 7, column: 12)
      assert d.line == 7
      assert d.column == 12
    end

    test "accepts explicit end span and severity overrides" do
      d = Diagnostic.new("boom", [line: 1], severity: :warning, end_line: 1, end_column: 9)
      assert d.severity == :warning
      assert d.end_line == 1
      assert d.end_column == 9
    end
  end
end
