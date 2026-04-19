defmodule TinyCI.StepResult do
  @moduledoc """
  Captures the result of executing a single pipeline step.

  Includes the step name, status, any captured output, and the
  wall-clock duration of the step in milliseconds.

  When `:allowed_failure` is `true`, the step failed but was marked
  with `allow_failure: true` in its definition. Such failures do not
  cause the containing stage to fail.

  The `:store_data` field carries any key-value data that a module step
  returned via `{:ok, map}`. This data is merged into the pipeline store
  so that subsequent steps and stages can access it through `context.store`.
  Shell command steps always have an empty `store_data`.
  """

  @type status :: :passed | :failed | :skipped

  @type t :: %__MODULE__{
          name: atom(),
          status: status(),
          output: String.t(),
          duration_ms: non_neg_integer(),
          allowed_failure: boolean(),
          store_data: map()
        }

  @enforce_keys [:name, :status]
  defstruct name: nil,
            status: :passed,
            output: "",
            duration_ms: 0,
            allowed_failure: false,
            store_data: %{}
end
