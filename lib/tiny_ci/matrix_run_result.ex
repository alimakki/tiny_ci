defmodule TinyCI.MatrixRunResult do
  @moduledoc """
  Captures the result of one matrix combination run within a matrix stage.

  Each matrix stage generates one `%MatrixRunResult{}` per variable combination.
  The parent `%TinyCI.StageResult{}` collects all run results and derives its
  overall status from them.
  """

  @type status :: :passed | :failed | :skipped

  @type t :: %__MODULE__{
          combination: keyword(String.t()),
          status: status(),
          step_results: [TinyCI.StepResult.t()],
          duration_ms: non_neg_integer(),
          store: map()
        }

  defstruct combination: [],
            status: :passed,
            step_results: [],
            duration_ms: 0,
            store: %{}
end
