defmodule TinyCI.DSL.Spec.Entry do
  @moduledoc """
  One symbol in the TinyCI DSL — a directive, an option key, or a condition
  primitive — as described by `TinyCI.DSL.Spec`.

  Entries are pure data: a name, the contexts they are valid in, a one-line
  summary, and a usage example. They carry no editor- or LSP-specific details,
  so the validator, the language server, and documentation can all read the same
  source without coupling core to any consumer.
  """

  @enforce_keys [:name, :kind, :summary, :example]
  defstruct [:name, :kind, :summary, :example, :type, contexts: []]

  @typedoc "Where a symbol may appear in a pipeline file."
  @type context :: :top_level | :stage | :step | :hook | :condition

  @typedoc "What kind of symbol this entry describes."
  @type kind :: :directive | :option | :primitive

  @type t :: %__MODULE__{
          name: atom(),
          kind: kind(),
          summary: String.t(),
          example: String.t(),
          type: String.t() | nil,
          contexts: [context()]
        }
end
