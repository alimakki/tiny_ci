defmodule TinyCI.Events do
  @moduledoc """
  Typed event vocabulary for pipeline execution.

  Every phase of a run — pipeline, stage, step, matrix combination, hook —
  produces one or more of the structs defined here. All structs share two
  mandatory fields:

  - `run_id` — globally unique identifier for the pipeline run
  - `timestamp` — wall-clock `DateTime` at the moment the event occurred

  All structs implement `Jason.Encoder`, so they can be serialized to JSON
  directly. Atoms are encoded as strings; `DateTime` values are encoded as
  ISO 8601 strings.
  """

  @schema_version 2

  @doc """
  The current event-stream schema version, emitted on the `run_started` line.
  Bump this when the event schema changes in a backwards-incompatible way.
  """
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc """
  Emits an event to the run's dispatcher, if one is present on the context.

  The dispatcher pid is carried on the context under `:events` (set by the
  executor at run start). When absent — e.g. a unit that builds events without a
  running dispatcher — this is a no-op, so emitting is always safe.
  """
  @spec emit(map(), t()) :: :ok
  def emit(ctx, event) do
    case Map.get(ctx, :events) do
      pid when is_pid(pid) -> TinyCI.Events.Dispatcher.emit(pid, event)
      _ -> :ok
    end
  end

  @type t ::
          TinyCI.Events.PipelineStarted.t()
          | TinyCI.Events.PipelineCompleted.t()
          | TinyCI.Events.StageStarted.t()
          | TinyCI.Events.StageSkipped.t()
          | TinyCI.Events.StageCompleted.t()
          | TinyCI.Events.StepStarted.t()
          | TinyCI.Events.StepSkipped.t()
          | TinyCI.Events.StepOutputLine.t()
          | TinyCI.Events.StepRetrying.t()
          | TinyCI.Events.StepCompleted.t()
          | TinyCI.Events.MatrixRunStarted.t()
          | TinyCI.Events.MatrixRunCompleted.t()
          | TinyCI.Events.HookStarted.t()
          | TinyCI.Events.HookCompleted.t()
          | TinyCI.Events.CacheLookup.t()
          | TinyCI.Events.BreakpointHit.t()
          | TinyCI.Events.BreakpointResumed.t()
          | TinyCI.Events.RunDiverged.t()

  @doc """
  Returns the stable wire `type` string for an event struct.

  These strings form the documented `event_type` vocabulary used in the NDJSON
  event stream (see `docs/events.md`). The struct module is the type in Elixir;
  this maps it to the cross-language discriminator emitted on each NDJSON line.

  ## Examples

      iex> TinyCI.Events.type(%TinyCI.Events.StageStarted{
      ...>   run_id: "r", timestamp: DateTime.utc_now(), stage: :build
      ...> })
      "stage_started"
  """
  # Matches on the `__struct__` key (rather than `%Mod{}`) so this function can
  # live at the top of the file, ahead of the struct definitions below.
  @spec type(t()) :: String.t()
  def type(%{__struct__: TinyCI.Events.PipelineStarted}), do: "run_started"
  def type(%{__struct__: TinyCI.Events.PipelineCompleted}), do: "run_finished"
  def type(%{__struct__: TinyCI.Events.StageStarted}), do: "stage_started"
  def type(%{__struct__: TinyCI.Events.StageSkipped}), do: "stage_skipped"
  def type(%{__struct__: TinyCI.Events.StageCompleted}), do: "stage_finished"
  def type(%{__struct__: TinyCI.Events.StepStarted}), do: "step_started"
  def type(%{__struct__: TinyCI.Events.StepSkipped}), do: "step_skipped"
  def type(%{__struct__: TinyCI.Events.StepOutputLine}), do: "step_output"
  def type(%{__struct__: TinyCI.Events.StepRetrying}), do: "step_retrying"
  def type(%{__struct__: TinyCI.Events.StepCompleted}), do: "step_finished"
  def type(%{__struct__: TinyCI.Events.MatrixRunStarted}), do: "matrix_run_started"
  def type(%{__struct__: TinyCI.Events.MatrixRunCompleted}), do: "matrix_run_finished"
  def type(%{__struct__: TinyCI.Events.HookStarted}), do: "hook_started"
  def type(%{__struct__: TinyCI.Events.HookCompleted}), do: "hook_finished"
  def type(%{__struct__: TinyCI.Events.CacheLookup}), do: "cache_lookup"
  def type(%{__struct__: TinyCI.Events.BreakpointHit}), do: "breakpoint_hit"
  def type(%{__struct__: TinyCI.Events.BreakpointResumed}), do: "breakpoint_resumed"
  def type(%{__struct__: TinyCI.Events.RunDiverged}), do: "run_diverged"
end

defmodule TinyCI.Events.PipelineStarted do
  @moduledoc "Emitted when a pipeline run begins."

  @enforce_keys [:run_id, :timestamp, :pipeline_name]
  defstruct [:run_id, :timestamp, :pipeline_name]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          pipeline_name: atom()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "pipeline_name" => to_string(event.pipeline_name)
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.PipelineCompleted do
  @moduledoc "Emitted when a pipeline run finishes (passed or failed)."

  @enforce_keys [:run_id, :timestamp, :status, :duration_ms]
  defstruct [:run_id, :timestamp, :status, :duration_ms]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          status: :passed | :failed | :skipped | :aborted,
          duration_ms: non_neg_integer()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "status" => to_string(event.status),
          "duration_ms" => event.duration_ms
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StageStarted do
  @moduledoc "Emitted when a stage begins executing."

  @enforce_keys [:run_id, :timestamp, :stage]
  defstruct [:run_id, :timestamp, :stage]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage)
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StageSkipped do
  @moduledoc "Emitted when a stage is skipped due to a condition or filter."

  @enforce_keys [:run_id, :timestamp, :stage, :reason]
  defstruct [:run_id, :timestamp, :stage, :reason]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          reason: String.t()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "reason" => event.reason
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StageCompleted do
  @moduledoc "Emitted when a stage finishes (passed or failed)."

  @enforce_keys [:run_id, :timestamp, :stage, :status, :duration_ms]
  defstruct [:run_id, :timestamp, :stage, :status, :duration_ms]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          status: :passed | :failed | :skipped | :aborted,
          duration_ms: non_neg_integer()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "status" => to_string(event.status),
          "duration_ms" => event.duration_ms
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StepStarted do
  @moduledoc "Emitted when a step begins executing within a stage."

  @enforce_keys [:run_id, :timestamp, :stage, :step]
  defstruct [:run_id, :timestamp, :stage, :step]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "step" => to_string(event.step)
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StepSkipped do
  @moduledoc "Emitted when a step is skipped due to a condition."

  @enforce_keys [:run_id, :timestamp, :stage, :step, :reason]
  defstruct [:run_id, :timestamp, :stage, :step, :reason]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom(),
          reason: String.t()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "step" => to_string(event.step),
          "reason" => event.reason
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StepOutputLine do
  @moduledoc """
  Emitted for a line of step output.

  The `stream` field distinguishes `:stdout` from `:stderr`. The executor
  currently merges stderr into stdout when running commands, so in practice
  every line is `:stdout` today; the field exists so consumers can rely on it
  once the streams are separated.
  """

  @enforce_keys [:run_id, :timestamp, :stage, :step, :line]
  defstruct [:run_id, :timestamp, :stage, :step, :line, stream: :stdout]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom(),
          line: String.t(),
          stream: :stdout | :stderr
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "step" => to_string(event.step),
          "line" => event.line,
          "stream" => to_string(event.stream)
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StepRetrying do
  @moduledoc "Emitted when a step is about to be retried after a failure."

  @enforce_keys [:run_id, :timestamp, :stage, :step, :attempt]
  defstruct [:run_id, :timestamp, :stage, :step, :attempt]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom(),
          attempt: pos_integer()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "step" => to_string(event.step),
          "attempt" => event.attempt
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.StepCompleted do
  @moduledoc """
  Emitted when a step finishes (passed or failed).

  Carries the step's captured `output` so console/buffered consumers can render
  it without reaching into executor internals. May be empty when output was
  streamed live.
  """

  @enforce_keys [:run_id, :timestamp, :stage, :step, :status, :duration_ms]
  defstruct [:run_id, :timestamp, :stage, :step, :status, :duration_ms, output: ""]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom(),
          status: :passed | :failed | :skipped | :aborted,
          duration_ms: non_neg_integer(),
          output: String.t()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "step" => to_string(event.step),
          "status" => to_string(event.status),
          "duration_ms" => event.duration_ms,
          "output" => event.output
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.MatrixRunStarted do
  @moduledoc "Emitted when one matrix combination begins executing."

  @enforce_keys [:run_id, :timestamp, :stage, :combination]
  defstruct [:run_id, :timestamp, :stage, :combination]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          combination: keyword(String.t())
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "combination" => Map.new(event.combination, fn {k, v} -> {to_string(k), v} end)
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.MatrixRunCompleted do
  @moduledoc "Emitted when one matrix combination finishes (passed or failed)."

  @enforce_keys [:run_id, :timestamp, :stage, :combination, :status, :duration_ms]
  defstruct [:run_id, :timestamp, :stage, :combination, :status, :duration_ms]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          combination: keyword(String.t()),
          status: :passed | :failed | :skipped | :aborted,
          duration_ms: non_neg_integer()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "combination" => Map.new(event.combination, fn {k, v} -> {to_string(k), v} end),
          "status" => to_string(event.status),
          "duration_ms" => event.duration_ms
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.HookStarted do
  @moduledoc "Emitted when a pipeline hook (on_success, on_failure) begins."

  @enforce_keys [:run_id, :timestamp, :hook]
  defstruct [:run_id, :timestamp, :hook]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          hook: atom()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "hook" => to_string(event.hook)
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.HookCompleted do
  @moduledoc "Emitted when a pipeline hook finishes (passed or failed)."

  @enforce_keys [:run_id, :timestamp, :hook, :status, :duration_ms]
  defstruct [:run_id, :timestamp, :hook, :status, :duration_ms]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          hook: atom(),
          status: :passed | :failed | :skipped | :aborted,
          duration_ms: non_neg_integer()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "hook" => to_string(event.hook),
          "status" => to_string(event.status),
          "duration_ms" => event.duration_ms
        },
        opts
      )
    end
  end
end

defmodule TinyCI.Events.CacheLookup do
  @moduledoc "Emitted when a cached step resolves its cache key (hit or miss)."

  @enforce_keys [:run_id, :timestamp, :stage, :step, :key, :result]
  defstruct [:run_id, :timestamp, :stage, :step, :key, :result]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom() | nil,
          step: atom(),
          key: String.t(),
          result: :hit | :miss
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => stage_to_string(event.stage),
          "step" => to_string(event.step),
          "key" => event.key,
          "result" => to_string(event.result)
        },
        opts
      )
    end

    defp stage_to_string(nil), do: nil
    defp stage_to_string(stage), do: to_string(stage)
  end
end

defmodule TinyCI.Events.BreakpointHit do
  @moduledoc """
  Emitted when execution reaches an armed breakpoint and the responsible process
  is about to block awaiting a control command (T10).

  This is the richest event in the stream: it carries everything needed to reason
  about the paused boundary without reaching into executor internals — the
  resolved environment, working directory, pipeline store snapshot, git context,
  and (inside a matrix stage) the combination being run. On an `:after` boundary
  it additionally carries the `result` that is about to be recorded.

  `env` and `store` values are already coerced to JSON-safe terms and passed
  through secret redaction by `TinyCI.Control.Session` before the event is built.
  """

  @enforce_keys [:run_id, :timestamp, :pause_id, :phase, :scope, :stage]
  defstruct [
    :run_id,
    :timestamp,
    :pause_id,
    :phase,
    :scope,
    :stage,
    :step,
    :breakpoint,
    :working_dir,
    :branch,
    :commit,
    :matrix_combination,
    :result,
    env: %{},
    store: %{}
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          pause_id: String.t(),
          phase: :before | :after,
          scope: :stage | :step,
          stage: atom(),
          step: atom() | nil,
          breakpoint: String.t() | nil,
          working_dir: String.t() | nil,
          branch: String.t() | nil,
          commit: String.t() | nil,
          matrix_combination: keyword(String.t()) | nil,
          result: map() | nil,
          env: %{optional(String.t()) => String.t()},
          store: %{optional(String.t()) => term()}
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "pause_id" => event.pause_id,
          "phase" => to_string(event.phase),
          "scope" => to_string(event.scope),
          "stage" => to_string(event.stage),
          "step" => maybe_string(event.step),
          "breakpoint" => event.breakpoint,
          "working_dir" => event.working_dir,
          "branch" => event.branch,
          "commit" => event.commit,
          "matrix_combination" => combination(event.matrix_combination),
          "result" => event.result,
          "env" => event.env,
          "store" => event.store
        },
        opts
      )
    end

    defp maybe_string(nil), do: nil
    defp maybe_string(value), do: to_string(value)

    defp combination(nil), do: nil
    defp combination(combo), do: Map.new(combo, fn {k, v} -> {to_string(k), v} end)
  end
end

defmodule TinyCI.Events.BreakpointResumed do
  @moduledoc """
  Emitted when a paused breakpoint is released by a terminal control command
  (T10) — `continue`, `skip`, `retry`, or `abort`.

  `set_store` does not produce this event: it mutates the paused session's store
  and leaves the process paused, so it surfaces as `run_diverged` instead.

  When the pause was released by `--break-timeout` rather than by an operator,
  `timed_out` is `true` and `command` is the configured timeout action.
  """

  @enforce_keys [:run_id, :timestamp, :pause_id, :command, :waited_ms]
  defstruct [
    :run_id,
    :timestamp,
    :pause_id,
    :command,
    :waited_ms,
    :stage,
    :step,
    timed_out: false
  ]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          pause_id: String.t(),
          command: :continue | :skip | :retry | :abort,
          waited_ms: non_neg_integer(),
          stage: atom() | nil,
          step: atom() | nil,
          timed_out: boolean()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "pause_id" => event.pause_id,
          "command" => to_string(event.command),
          "waited_ms" => event.waited_ms,
          "stage" => maybe_string(event.stage),
          "step" => maybe_string(event.step),
          "timed_out" => event.timed_out
        },
        opts
      )
    end

    defp maybe_string(nil), do: nil
    defp maybe_string(value), do: to_string(value)
  end
end

defmodule TinyCI.Events.RunDiverged do
  @moduledoc """
  Emitted every time manual execution control alters what a run would otherwise
  have done (T10) — a `set_store`, a forced `skip`, or a forced `retry`.

  One event per divergent command, so the stream records *what* was changed and
  not merely that something was. `set_store` in particular produces no
  `breakpoint_resumed` (it leaves the process paused), so this is its only trace.

  A diverged run is **not a CI result**: it is carried through to provenance (T7),
  where `TinyCI.Provenance` flags it and attestation refuses to sign it. See
  `docs/execution-control.md`.
  """

  @enforce_keys [:run_id, :timestamp, :reason]
  defstruct [:run_id, :timestamp, :reason, :stage, :step, :detail]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          reason: :set_store | :skip | :retry,
          stage: atom() | nil,
          step: atom() | nil,
          detail: String.t() | nil
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "reason" => to_string(event.reason),
          "stage" => maybe_string(event.stage),
          "step" => maybe_string(event.step),
          "detail" => event.detail
        },
        opts
      )
    end

    defp maybe_string(nil), do: nil
    defp maybe_string(value), do: to_string(value)
  end
end
