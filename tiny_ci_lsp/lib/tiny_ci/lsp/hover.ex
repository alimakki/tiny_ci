defmodule TinyCI.LSP.Hover do
  @moduledoc """
  Builds `textDocument/hover` popups for the symbol under the cursor.

  The symbol is located with `Code.Fragment.surround_context/2` (AST-aware, not a
  regex), classified into a DSL context with `TinyCI.LSP.Context`, and looked up
  in `TinyCI.DSL.Spec`. The popup shows the same one-line description and example
  as completion — both read from the single source of truth.
  """

  alias GenLSP.Structures.Hover
  alias TinyCI.DSL.Spec
  alias TinyCI.DSL.Spec.Entry
  alias TinyCI.LSP.Context
  alias TinyCI.LSP.Doc

  @doc """
  Returns a hover popup for the 0-based `line`/`character` position, or `nil`
  when there is no known DSL symbol under the cursor.
  """
  @spec at(String.t(), non_neg_integer(), non_neg_integer()) :: Hover.t() | nil
  def at(text, line, character) do
    with {:ok, name} <- symbol_at(text, line, character),
         scope = text |> Context.at(line, character) |> Context.spec_scope(),
         %Entry{} = entry <- Spec.lookup(name, scope) do
      %Hover{contents: Doc.markup(entry)}
    else
      _ -> nil
    end
  end

  # surround_context uses 1-based positions; LSP positions are 0-based. We accept
  # the identifier shapes the DSL uses: bare names (directives), keyword keys
  # (options), and zero-/one-arg calls (condition primitives).
  defp symbol_at(text, line, character) do
    case Code.Fragment.surround_context(text, {line + 1, character + 1}) do
      %{context: {kind, chars}} when kind in [:local_or_var, :key, :local_call] ->
        {:ok, List.to_string(chars)}

      _ ->
        :error
    end
  end
end
