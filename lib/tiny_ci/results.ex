defmodule TinyCI.Results do
  @moduledoc """
  Serializes pipeline run results to JSON.

  Converts the `[%StageResult{}]` list returned by `TinyCI.Executor.run_pipeline/3`
  into a single JSON string suitable for machine consumption.
  """

  alias TinyCI.{MatrixRunResult, StageResult, StepResult}

  @doc """
  Encodes pipeline results to a JSON string.

  ## Parameters

    * `pipeline_result` — the raw return value from `Executor.run_pipeline/3`:
      either `:ok` or `{:error, reason}`
    * `stage_results`   — the list of `%StageResult{}` structs from the run

  ## Returns

  A JSON-encoded binary string with the shape:

      {
        "status": "passed" | "failed",
        "duration_ms": integer,
        "stages": [
          {
            "name": string,
            "status": string,
            "duration_ms": integer,
            "steps": [...],
            "matrix_runs": [...]
          }
        ]
      }
  """
  @spec to_json(:ok | {:error, term()}, [StageResult.t()]) :: String.t()
  def to_json(pipeline_result, stage_results) do
    status = pipeline_status(pipeline_result)
    total_ms = Enum.sum(Enum.map(stage_results, & &1.duration_ms))

    %{
      status: status,
      duration_ms: total_ms,
      stages: Enum.map(stage_results, &encode_stage/1)
    }
    |> Jason.encode!()
  end

  defp pipeline_status(:ok), do: "passed"
  defp pipeline_status({:error, _}), do: "failed"

  defp encode_stage(%StageResult{
         name: name,
         status: status,
         duration_ms: duration_ms,
         step_results: step_results,
         matrix_runs: matrix_runs
       }) do
    %{
      name: Atom.to_string(name),
      status: Atom.to_string(status),
      duration_ms: duration_ms,
      steps: Enum.map(step_results, &encode_step/1),
      matrix_runs: Enum.map(matrix_runs, &encode_matrix_run/1)
    }
  end

  defp encode_step(%StepResult{
         name: name,
         status: status,
         output: output,
         duration_ms: duration_ms,
         allowed_failure: allowed_failure,
         attempts: attempts
       }) do
    %{
      name: Atom.to_string(name),
      status: Atom.to_string(status),
      output: output,
      duration_ms: duration_ms,
      allowed_failure: allowed_failure,
      attempts: attempts
    }
  end

  defp encode_matrix_run(%MatrixRunResult{
         combination: combination,
         status: status,
         duration_ms: duration_ms,
         step_results: step_results
       }) do
    %{
      combination: Map.new(combination, fn {k, v} -> {Atom.to_string(k), v} end),
      status: Atom.to_string(status),
      duration_ms: duration_ms,
      steps: Enum.map(step_results, &encode_step/1)
    }
  end
end
