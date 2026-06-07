defmodule TinyCI.Listener do
  @moduledoc """
  Behaviour for pipeline execution lifecycle events.

  Implementations decide how to handle events emitted by the executor during
  a pipeline run. The executor always calls these callbacks regardless of output
  mode — it is the listener's responsibility to act or no-op.

  Two implementations are provided:

    * `TinyCI.Listener.Human` — prints human-readable progress to stdout
    * `TinyCI.Listener.Silent` — no-ops all callbacks (used for JSON output)

  > #### Migrating to the event stream {: .info}
  >
  > Stage start/skip progress now flows through the structured event stream
  > (`TinyCI.Events`) and is rendered by `TinyCI.Events.Sink.Console`. The
  > executor still uses this behaviour for the buffered step-output, matrix, and
  > retry-attempt renderings; the `listener:` option doubles as the selector for
  > which console event sink is attached. See `docs/events.md`.
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
