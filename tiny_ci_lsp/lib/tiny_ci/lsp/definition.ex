defmodule TinyCI.LSP.Definition do
  @moduledoc """
  `textDocument/definition` for TinyCI pipeline files.

  Resolves the symbol under the cursor (via `Code.Fragment.surround_context/2`,
  AST-aware rather than regex) into a `GenLSP.Structures.Location`:

    * a **`needs:` atom** (or any atom naming a stage) jumps to that `stage`
      declaration in the same file;
    * a **`module:` alias** jumps to the module's source file, when the module is
      loadable on the server's code path.

  Returns `nil` when there is no resolvable definition.
  """

  alias GenLSP.Structures.{Location, Position, Range}

  @doc """
  Returns the definition `Location` for the 0-based `line`/`character` position,
  or `nil`. `uri` is the document being edited (the target file for stage jumps).
  """
  @spec at(String.t(), String.t(), non_neg_integer(), non_neg_integer()) :: Location.t() | nil
  def at(uri, text, line, character) do
    case Code.Fragment.surround_context(text, {line + 1, character + 1}) do
      %{context: {:unquoted_atom, chars}} -> stage_definition(uri, text, List.to_string(chars))
      %{context: {:alias, chars}} -> module_definition(chars)
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # needs atom / stage name → stage declaration
  # ---------------------------------------------------------------------------

  # Compares against stage names by string so we never intern an atom that may
  # not exist yet (the buffer may not have been parsed elsewhere).
  defp stage_definition(uri, text, name) do
    case stage_meta(text, name) do
      nil -> nil
      meta -> %Location{uri: uri, range: keyword_range(meta, "stage")}
    end
  end

  defp stage_meta(text, name) do
    case Code.string_to_quoted(text, columns: true) do
      {:ok, ast} -> ast |> unwrap_block() |> Enum.find_value(&stage_match(&1, name))
      _ -> nil
    end
  end

  defp stage_match({:stage, meta, [stage_name | _]}, name)
       when is_atom(stage_name) do
    if Atom.to_string(stage_name) == name, do: meta
  end

  defp stage_match(_node, _name), do: nil

  # ---------------------------------------------------------------------------
  # module alias → module source file
  # ---------------------------------------------------------------------------

  defp module_definition(chars) do
    module = chars |> List.to_string() |> String.split(".") |> Module.concat()

    with true <- Code.ensure_loaded?(module),
         source when is_list(source) <- module_source(module) do
      path = List.to_string(source)
      %Location{uri: "file://" <> path, range: zero_range()}
    else
      _ -> nil
    end
  end

  defp module_source(module) do
    module.module_info(:compile)[:source]
  rescue
    _ -> nil
  end

  # ---------------------------------------------------------------------------
  # Ranges
  # ---------------------------------------------------------------------------

  # A range covering a leading keyword (e.g. `stage`) at the given AST meta.
  defp keyword_range(meta, keyword) do
    line = Keyword.get(meta, :line, 1) - 1
    col = Keyword.get(meta, :column, 1) - 1

    %Range{
      start: %Position{line: line, character: col},
      end: %Position{line: line, character: col + String.length(keyword)}
    }
  end

  defp zero_range do
    %Range{
      start: %Position{line: 0, character: 0},
      end: %Position{line: 0, character: 0}
    }
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp unwrap_block({:__block__, _meta, exprs}), do: exprs
  defp unwrap_block(single), do: [single]
end
