defmodule TinyCI.Listener do
  @moduledoc """
  Behaviour for pipeline execution lifecycle events.

  Implementations decide how to handle events emitted by the executor during
  a pipeline run. The executor always calls these callbacks regardless of output
  mode — it is the listener's responsibility to act or no-op.

  Two implementations are provided:

    * `TinyCI.Listener.Human` — prints human-readable progress to stdout
    * `TinyCI.Listener.Silent` — no-ops all callbacks (used for JSON output)
  """

  alias TinyCI.{MatrixRunResult, StageResult}

  @doc "Called when a stage begins execution consideration."
  @callback stage_started(stage_name :: atom()) :: :ok

  @doc "Called when a stage is skipped before any steps run."
  @callback stage_skipped(
              stage_name :: atom(),
              reason :: :condition_not_met | :dependency_failed
            ) :: :ok

  @doc """
  Called after a stage finishes (passed or failed) in buffered output mode.

  Used to print buffered step output after the stage completes. Not called
  in streaming mode because output was already printed in real time.
  """
  @callback stage_finished(StageResult.t()) :: :ok

  @doc "Called after all matrix combinations for a stage complete."
  @callback matrix_stage_finished([MatrixRunResult.t()]) :: :ok

  @doc "Called at the start of each retry attempt."
  @callback step_attempt(attempt :: pos_integer(), total :: pos_integer()) :: :ok
end
