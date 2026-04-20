defmodule TinyCI.PipelineSpec do
  @moduledoc """
  The output of the DSL interpreter — a fully-resolved pipeline definition.

  `%PipelineSpec{}` is what `TinyCI.DSL.Interpreter` produces from a pipeline
  file. It replaces the old pattern of compiling a module and calling
  `module.__pipeline__()/0` and `module.__hooks__()/0`.

  ## Fields

    * `:name`   — atom identifier for the pipeline, either from a `name` directive
      in the file or derived from the filename stem
    * `:stages` — list of `%TinyCI.Stage{}` structs in declaration order
    * `:hooks`  — map with `:on_success` and `:on_failure` lists of `%TinyCI.Hook{}`
  """

  @enforce_keys [:name, :stages, :hooks]
  defstruct [:name, :stages, :hooks, root: nil]

  @type t :: %__MODULE__{
          name: atom(),
          stages: [TinyCI.Stage.t()],
          hooks: %{on_success: [TinyCI.Hook.t()], on_failure: [TinyCI.Hook.t()]},
          root: String.t() | nil
        }
end
