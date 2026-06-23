defmodule TinyCI.LSP.Doc do
  @moduledoc """
  Renders a `TinyCI.DSL.Spec.Entry` into Markdown for completion documentation
  and hover popups. Both features show the same one-line description plus a usage
  example, derived from the single source of truth in `TinyCI.DSL.Spec`.
  """

  alias GenLSP.Enumerations.MarkupKind
  alias GenLSP.Structures.MarkupContent
  alias TinyCI.DSL.Spec.Entry

  @doc "Wraps `markdown/1` in an LSP `MarkupContent` value."
  @spec markup(Entry.t()) :: MarkupContent.t()
  def markup(%Entry{} = entry) do
    %MarkupContent{kind: MarkupKind.markdown(), value: markdown(entry)}
  end

  @doc """
  Renders an entry as Markdown: a bold name, the summary, an optional type line,
  and a fenced Elixir example.
  """
  @spec markdown(Entry.t()) :: String.t()
  def markdown(%Entry{} = entry) do
    """
    **#{entry.name}** — #{entry.summary}#{type_line(entry.type)}

    ```elixir
    #{entry.example}
    ```
    """
  end

  defp type_line(nil), do: ""
  defp type_line(type), do: "\n\n_#{type}_"
end
