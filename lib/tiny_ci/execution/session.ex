defmodule TinyCI.Execution.Session do
  @moduledoc """
  An open execution session: the backend that owns it, its opaque reference, and
  the spec it was opened from.

  Created by `TinyCI.Execution.with_session/3` and passed to
  `TinyCI.Execution.exec/3`. Callers treat `:ref` as opaque; only the backend that
  opened the session reads it.
  """

  @enforce_keys [:backend, :ref, :spec]
  defstruct [:backend, :ref, :spec]

  @type t :: %__MODULE__{
          backend: module(),
          ref: term(),
          spec: TinyCI.Execution.SessionSpec.t()
        }
end
