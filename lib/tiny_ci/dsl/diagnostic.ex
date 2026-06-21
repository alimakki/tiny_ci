defmodule TinyCI.DSL.Diagnostic do
  @moduledoc """
  A single load-time problem found in a pipeline file, carrying a source span.

  Produced by `TinyCI.DSL.Validator` (one per allowlist violation) and by
  `TinyCI.DSL.Interpreter` (for parse errors and graph/action problems). The
  span is 1-based and mirrors Elixir AST metadata (`line`/`column`); `end_line`
  and `end_column` are best-effort and may be `nil` when the offending construct
  carries no positional metadata.

  Both the CLI runner and the language server consume the same diagnostics, so a
  message shown in-editor matches the message the runner prints at load time.
  """

  @enforce_keys [:message]
  defstruct [
    :message,
    :end_line,
    :end_column,
    severity: :error,
    line: 1,
    column: 1
  ]

  @type severity :: :error | :warning | :information | :hint

  @type t :: %__MODULE__{
          message: String.t(),
          severity: severity(),
          line: pos_integer(),
          column: pos_integer(),
          end_line: pos_integer() | nil,
          end_column: pos_integer() | nil
        }

  @doc """
  Builds a diagnostic from a message and Elixir AST metadata.

  `meta` is the keyword list found in the second element of a quoted node
  (e.g. `[line: 3, column: 5]`). Missing keys default to the start of the file.

  ## Options

    * `:severity` — defaults to `:error`
    * `:end_line` / `:end_column` — explicit end of the span

  ## Examples

      iex> d = TinyCI.DSL.Diagnostic.new("bad", line: 4, column: 2)
      iex> {d.line, d.column, d.severity}
      {4, 2, :error}
  """
  @spec new(String.t(), keyword(), keyword()) :: t()
  def new(message, meta \\ [], opts \\ []) do
    %__MODULE__{
      message: message,
      line: Keyword.get(meta, :line, 1),
      column: Keyword.get(meta, :column, 1),
      end_line: Keyword.get(opts, :end_line),
      end_column: Keyword.get(opts, :end_column),
      severity: Keyword.get(opts, :severity, :error)
    }
  end
end
