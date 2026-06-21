defmodule TinyCI.LSP.DiagnosticMapperTest do
  use ExUnit.Case, async: true

  alias GenLSP.Structures.{Diagnostic, Position, Range}
  alias TinyCI.DSL.Diagnostic, as: CoreDiagnostic
  alias TinyCI.LSP.DiagnosticMapper

  describe "to_lsp_diagnostic/2" do
    test "converts 1-based core spans to 0-based LSP positions" do
      core = CoreDiagnostic.new("boom", line: 3, column: 5)

      assert %Diagnostic{
               range: %Range{start: %Position{line: 2, character: 4}},
               severity: 1,
               source: "tiny_ci",
               message: "boom"
             } =
               DiagnosticMapper.to_lsp_diagnostic(core, "line one\nline two\nline three is long")
    end

    test "extends the end to the end of the offending line when no end span is given" do
      text = "stage :deploy, when: dangerous() == 0 do"
      core = CoreDiagnostic.new("bad condition", line: 1, column: 22)

      assert %Diagnostic{range: %Range{end: %Position{line: 0, character: end_char}}} =
               DiagnosticMapper.to_lsp_diagnostic(core, text)

      assert end_char == String.length(text)
    end

    test "respects an explicit end span" do
      core =
        CoreDiagnostic.new("ranged", [line: 2, column: 3], end_line: 2, end_column: 10)

      assert %Diagnostic{
               range: %Range{
                 start: %Position{line: 1, character: 2},
                 end: %Position{line: 1, character: 9}
               }
             } = DiagnosticMapper.to_lsp_diagnostic(core, "a\nbbbbbbbbbbb")
    end

    test "maps severities to LSP integers" do
      for {sev, code} <- [error: 1, warning: 2, information: 3, hint: 4] do
        core = %{CoreDiagnostic.new("x") | severity: sev}
        assert %Diagnostic{severity: ^code} = DiagnosticMapper.to_lsp_diagnostic(core, "x")
      end
    end

    test "never produces a zero-width range" do
      core = CoreDiagnostic.new("eof", line: 1, column: 1)

      assert %Diagnostic{range: %Range{start: start, end: stop}} =
               DiagnosticMapper.to_lsp_diagnostic(core, "")

      refute start == stop
    end
  end

  describe "to_lsp/2" do
    test "maps a list against shared document text" do
      text = "stage :test do\n  step :unit, bogus: 1\nend\n"

      diags = [
        CoreDiagnostic.new("first", line: 1, column: 1),
        CoreDiagnostic.new("second", line: 2, column: 3)
      ]

      assert [%Diagnostic{message: "first"}, %Diagnostic{message: "second"}] =
               DiagnosticMapper.to_lsp(diags, text)
    end
  end
end
