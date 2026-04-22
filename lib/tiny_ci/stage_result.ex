defmodule TinyCI.StageResult do
  @moduledoc """
  Captures the result of executing a pipeline stage.

  Includes the stage name, overall status, individual step results,
  the total wall-clock duration of the stage in milliseconds, and
  the accumulated pipeline store after this stage completed.

  The `:store` field reflects the full pipeline store state after this
  stage's steps have been executed and their `store_data` merged. Later
  stages receive this store via the pipeline context.
  """

  @type status :: :passed | :failed | :skipped

  @type t :: %__MODULE__{
          name: atom(),
          status: status(),
          step_results: [TinyCI.StepResult.t()],
          matrix_runs: [TinyCI.MatrixRunResult.t()],
          duration_ms: non_neg_integer(),
          store: map()
        }

  @enforce_keys [:name, :status]
  defstruct name: nil,
            status: :passed,
            step_results: [],
            matrix_runs: [],
            duration_ms: 0,
            store: %{}
end
