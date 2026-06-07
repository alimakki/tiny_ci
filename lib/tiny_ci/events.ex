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

  @schema_version 1

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
          status: :passed | :failed,
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
          status: :passed | :failed,
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
          status: :passed | :failed,
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
          status: :passed | :failed,
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
          status: :passed | :failed,
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
