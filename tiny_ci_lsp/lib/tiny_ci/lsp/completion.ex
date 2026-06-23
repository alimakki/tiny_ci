defmodule TinyCI.LSP.Completion do
  @moduledoc """
  Builds `textDocument/completion` items for a given DSL context.

  Every item — directives, option keys, and condition primitives — is derived
  from `TinyCI.DSL.Spec`, so the suggestions can never drift from what the
  validator accepts. `TinyCI.LSP.Context` decides which context the cursor is in;
  this module turns that into a list of `GenLSP.Structures.CompletionItem`.
  """

  alias GenLSP.Enumerations.CompletionItemKind
  alias GenLSP.Structures.CompletionItem
  alias TinyCI.DSL.Spec
  alias TinyCI.DSL.Spec.Entry
  alias TinyCI.LSP.Context
  alias TinyCI.LSP.Doc

  @doc """
  Returns the completion items offered in the given context.

  Returns `[]` for `:unknown` (or any unrecognized context).
  """
  @spec items(Context.t()) :: [CompletionItem.t()]
  def items(:top_level), do: directive_items(:top_level)
  def items(:stage_body), do: directive_items(:stage)
  def items(:step_body), do: directive_items(:step)
  def items(:hook_body), do: directive_items(:hook)
  def items(:stage_opts), do: option_items(:stage)
  def items(:step_opts), do: option_items(:step)
  def items(:hook_opts), do: option_items(:hook)
  def items(:condition), do: Enum.map(Spec.condition_primitives(), &primitive_item/1)
  def items(_other), do: []

  defp directive_items(context), do: context |> Spec.directives() |> Enum.map(&directive_item/1)
  defp option_items(context), do: context |> Spec.options() |> Enum.map(&option_item/1)

  defp directive_item(%Entry{} = entry) do
    name = Atom.to_string(entry.name)

    %CompletionItem{
      label: name,
      kind: CompletionItemKind.keyword(),
      detail: entry.summary,
      insert_text: name,
      documentation: Doc.markup(entry)
    }
  end

  defp option_item(%Entry{} = entry) do
    %CompletionItem{
      label: Atom.to_string(entry.name),
      kind: CompletionItemKind.field(),
      detail: entry.type,
      insert_text: "#{entry.name}: ",
      documentation: Doc.markup(entry)
    }
  end

  defp primitive_item(%Entry{} = entry) do
    name = Atom.to_string(entry.name)
    {label, insert} = primitive_call(name, entry.type)

    %CompletionItem{
      label: label,
      kind: CompletionItemKind.function(),
      detail: entry.summary,
      insert_text: insert,
      documentation: Doc.markup(entry)
    }
  end

  # Zero-arity primitives (type signature begins with `()`) insert a complete
  # call; arg-taking ones leave the cursor inside the parentheses.
  defp primitive_call(name, type) do
    if String.starts_with?(type, "()") do
      {name <> "()", name <> "()"}
    else
      {name <> "(...)", name <> "("}
    end
  end
end
