defmodule TinyCI.PipelineSpec do
  @moduledoc """
  The output of the DSL interpreter — a fully-resolved pipeline definition.

  `%PipelineSpec{}` is what `TinyCI.DSL.Interpreter` produces from a pipeline
  file. It is the only representation of a pipeline the runtime works with:
  no module is compiled and no code runs while a pipeline is loaded.

  ## Fields

    * `:name`   — atom identifier for the pipeline, either from a `name` directive
      in the file or derived from the filename stem
    * `:stages` — list of `%TinyCI.Stage{}` structs in declaration order
    * `:hooks`  — map with `:on_success` and `:on_failure` lists of `%TinyCI.Hook{}`
  """

  @enforce_keys [:name, :stages, :hooks]
  defstruct [:name, :stages, :hooks, root: nil, env: %{}]

  @type t :: %__MODULE__{
          name: atom(),
          stages: [TinyCI.Stage.t()],
          hooks: %{on_success: [TinyCI.Hook.t()], on_failure: [TinyCI.Hook.t()]},
          root: String.t() | nil,
          env: %{optional(String.t()) => String.t()}
        }
end
