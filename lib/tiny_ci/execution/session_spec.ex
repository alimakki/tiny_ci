defmodule TinyCI.Execution.SessionSpec do
  @moduledoc """
  Describes the environment a group of steps runs in.

  A session is created per stage, per matrix combination, and per shell hook. The
  Local backend ignores every field except `:run_id` (which it carries so a future
  cancellation registry can identify the run); the Container backend (M1.5-02)
  consumes `:image`, `:network`, and `:limits`.

  `:workspace` is the project root, not a step's working directory. A step's
  directory stays on `TinyCI.Execution.Command.working_dir`, so the Container
  backend can map it under its mounted workspace.
  """

  @enforce_keys [:workspace]
  defstruct [:workspace, :run_id, image: nil, network: true, limits: %{}]

  @type t :: %__MODULE__{
          workspace: String.t(),
          run_id: String.t() | nil,
          image: String.t() | nil,
          network: boolean(),
          limits: map()
        }
end
