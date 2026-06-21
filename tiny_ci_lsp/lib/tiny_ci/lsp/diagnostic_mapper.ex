defmodule TinyCI.LSP.DiagnosticMapper do
  @moduledoc """
  Converts core `TinyCI.DSL.Diagnostic` structs into LSP `Diagnostic` structures.

  Core diagnostics use **1-based** line/column spans (matching Elixir AST
  metadata); the Language Server Protocol uses **0-based** positions. When a
  core diagnostic carries no explicit end position, the range is extended to the
  end of the offending line so the editor underlines the construct rather than a
  single character.
  """

  alias GenLSP.Structures.{Diagnostic, Position, Range}
  alias TinyCI.DSL.Diagnostic, as: CoreDiagnostic

  @source "tiny_ci"

  @severities %{error: 1, warning: 2, information: 3, hint: 4}

  @doc """
  Maps a list of core diagnostics against the document `text` they describe.
  """
  @spec to_lsp([CoreDiagnostic.t()], String.t()) :: [Diagnostic.t()]
  def to_lsp(diagnostics, text) when is_list(diagnostics) do
    lines = String.split(text, "\n")
    Enum.map(diagnostics, &to_lsp_diagnostic(&1, lines))
  end

  @doc """
  Maps a single core diagnostic against the document `text` it describes.
  """
  @spec to_lsp_diagnostic(CoreDiagnostic.t(), String.t()) :: Diagnostic.t()
  def to_lsp_diagnostic(%CoreDiagnostic{} = diagnostic, text) when is_binary(text) do
    to_lsp_diagnostic(diagnostic, String.split(text, "\n"))
  end

  def to_lsp_diagnostic(%CoreDiagnostic{} = diagnostic, lines) when is_list(lines) do
    %Diagnostic{
      range: range(diagnostic, lines),
      severity: Map.get(@severities, diagnostic.severity, 1),
      source: @source,
      message: diagnostic.message
    }
  end

  defp range(diagnostic, lines) do
    start_line = max(diagnostic.line - 1, 0)
    start_char = max(diagnostic.column - 1, 0)
    {end_line, end_char} = end_position(diagnostic, lines, start_line, start_char)

    %Range{
      start: %Position{line: start_line, character: start_char},
      end: %Position{line: end_line, character: end_char}
    }
  end

  # Explicit end span when the diagnostic provides one; otherwise underline from
  # the start column to the end of that line (at least one character wide).
  defp end_position(%{end_line: el, end_column: ec}, _lines, _sl, _sc)
       when is_integer(el) and is_integer(ec) do
    {max(el - 1, 0), max(ec - 1, 0)}
  end

  defp end_position(_diagnostic, lines, start_line, start_char) do
    line_length = lines |> Enum.at(start_line, "") |> String.length()
    {start_line, max(line_length, start_char + 1)}
  end
end
