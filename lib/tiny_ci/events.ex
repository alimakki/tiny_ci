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
  @moduledoc "Emitted for each line of step output in streaming mode."

  @enforce_keys [:run_id, :timestamp, :stage, :step, :line]
  defstruct [:run_id, :timestamp, :stage, :step, :line]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom(),
          line: String.t()
        }

  defimpl Jason.Encoder do
    def encode(event, opts) do
      Jason.Encode.map(
        %{
          "run_id" => event.run_id,
          "timestamp" => DateTime.to_iso8601(event.timestamp),
          "stage" => to_string(event.stage),
          "step" => to_string(event.step),
          "line" => event.line
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
  @moduledoc "Emitted when a step finishes (passed or failed)."

  @enforce_keys [:run_id, :timestamp, :stage, :step, :status, :duration_ms]
  defstruct [:run_id, :timestamp, :stage, :step, :status, :duration_ms]

  @type t :: %__MODULE__{
          run_id: String.t(),
          timestamp: DateTime.t(),
          stage: atom(),
          step: atom(),
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
          "step" => to_string(event.step),
          "status" => to_string(event.status),
          "duration_ms" => event.duration_ms
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
