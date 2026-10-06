defmodule TinyCI.Runs.Projection do
  @moduledoc """
  A run summary, folded from the run's event stream.

  This is the one place that turns events into "what happened". The recorder folds
  events as they happen to write `meta.json`, the `runs` Mix task folds a recording
  to show it, and the web UI and replay will fold the same way, so every view of a
  run is a fold over its events.

  Events are **decoded NDJSON maps** (string keys, with `"type"`, `"seq"` and
  `"ts"`), never structs. A live event is converted with
  `TinyCI.Events.Sink.NDJSON.encode_line/2 |> Jason.decode!/1` before it is applied,
  so there is one representation and one fold.

  ## Event to effect

  | `type`                                     | effect                                              |
  |--------------------------------------------|-----------------------------------------------------|
  | `run_started`                              | identity, git fields, `schema_version`, `started_at` |
  | `run_finished`                             | `status`, `finished_at`, `duration_ms`              |
  | `stage_started`                            | add the stage as `:running` if absent               |
  | `stage_skipped`                            | stage `:skipped`, with its `reason`                 |
  | `stage_finished`                           | stage status and `duration_ms`                      |
  | `step_started`                             | add the step as `:running` if absent                |
  | `step_skipped`                             | step `:skipped`                                     |
  | `step_output`                              | append the line to the step's `output`              |
  | `step_retrying`                            | step `attempts` = the event's `attempt`             |
  | `step_finished`                            | step status, `duration_ms`, `allowed_failure`, exact `output` |
  | `cache_lookup`                             | step `cache` (`:hit` or `:miss`)                    |
  | `matrix_run_started` / `_finished`         | add or update the stage's matrix run by combination |
  | `breakpoint_hit` / `breakpoint_resumed`    | one `breakpoints` entry per `pause_id`              |
  | `run_diverged`                             | `divergent?: true`                                  |
  | anything else (including `hook_*`)         | ignored, for forward compatibility                  |

  A step event that carries `matrix_combination` belongs to that combination's
  matrix run; any other step event belongs to the stage itself. Step updates are
  upserts, because a step skipped by its `when:` condition emits `step_skipped`
  without ever emitting `step_started`.

  ## Representation notes

    * A step's `output` is one string, the same type `TinyCI.Results.to_json/3`
      uses. While the step runs it is built from the `step_output` lines, joined by
      `"\\n"` (blank lines are not events, so they are missing). When the step
      finishes, `step_finished`'s `output` replaces it, so a finished step's output
      is exact. Appending to a binary is cheap, where appending a line to a list per
      event would be quadratic for a chatty step.
    * Statuses are atoms, decoded through a fixed whitelist. An unrecognised status
      becomes `:unknown`; no atom is ever created from event data.
    * `started_at` and `finished_at` stay ISO-8601 strings, as on the wire.
    * `last_seq` is the highest `seq` seen, even for ignored events.
  """

  import Kernel, except: [apply: 2]

  alias TinyCI.{MatrixRunResult, StageResult, StepResult}

  defmodule Step do
    @moduledoc "One step of a run, as folded from its events."

    @type t :: %__MODULE__{
            name: String.t(),
            status: TinyCI.Runs.Projection.status(),
            duration_ms: non_neg_integer() | nil,
            attempts: pos_integer(),
            cache: :hit | :miss | nil,
            allowed_failure: boolean(),
            output: String.t()
          }

    defstruct name: nil,
              status: :running,
              duration_ms: nil,
              attempts: 1,
              cache: nil,
              allowed_failure: false,
              output: ""
  end

  defmodule MatrixRun do
    @moduledoc "One matrix combination of a stage, with the steps that ran in it."

    @type t :: %__MODULE__{
            combination: %{optional(String.t()) => String.t()},
            status: TinyCI.Runs.Projection.status(),
            duration_ms: non_neg_integer() | nil,
            steps: [TinyCI.Runs.Projection.Step.t()]
          }

    defstruct combination: %{}, status: :running, duration_ms: nil, steps: []
  end

  defmodule Stage do
    @moduledoc "One stage of a run. A matrix stage has `matrix_runs` and no `steps`."

    @type t :: %__MODULE__{
            name: String.t(),
            status: TinyCI.Runs.Projection.status(),
            duration_ms: non_neg_integer() | nil,
            reason: String.t() | nil,
            steps: [TinyCI.Runs.Projection.Step.t()],
            matrix_runs: [TinyCI.Runs.Projection.MatrixRun.t()]
          }

    defstruct name: nil,
              status: :running,
              duration_ms: nil,
              reason: nil,
              steps: [],
              matrix_runs: []
  end

  @type status :: :running | :passed | :failed | :skipped | :aborted | :interrupted | :unknown

  @type t :: %__MODULE__{
          run_id: String.t() | nil,
          pipeline: String.t() | nil,
          status: status(),
          schema_version: pos_integer() | nil,
          branch: String.t() | nil,
          commit: String.t() | nil,
          base_ref: String.t() | nil,
          root: String.t() | nil,
          started_at: String.t() | nil,
          finished_at: String.t() | nil,
          duration_ms: non_neg_integer() | nil,
          stages: [Stage.t()],
          divergent?: boolean(),
          breakpoints: [map()],
          last_seq: non_neg_integer()
        }

  defstruct run_id: nil,
            pipeline: nil,
            status: :running,
            schema_version: nil,
            branch: nil,
            commit: nil,
            base_ref: nil,
            root: nil,
            started_at: nil,
            finished_at: nil,
            duration_ms: nil,
            stages: [],
            divergent?: false,
            breakpoints: [],
            last_seq: 0

  @doc """
  An empty projection: a run that has not started.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> Projection.new() |> Map.take([:status, :stages, :last_seq])
      %{last_seq: 0, stages: [], status: :running}
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Folds one decoded event into the projection. Anything that is not an event map is
  ignored.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> event = %{"type" => "run_finished", "seq" => 4, "status" => "passed", "duration_ms" => 9}
      iex> p = Projection.apply(Projection.new(), event)
      iex> {p.status, p.duration_ms, p.last_seq}
      {:passed, 9, 4}
  """
  @spec apply(t(), term()) :: t()
  def apply(%__MODULE__{} = projection, %{"type" => type} = event) when is_binary(type) do
    projection
    |> put_seq(event)
    |> effect(type, event)
  end

  def apply(%__MODULE__{} = projection, _other), do: projection

  @doc """
  Folds a stream of decoded events into a projection.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> Projection.fold([%{"type" => "stage_started", "stage" => "build"}]).stages |> hd() |> Map.get(:name)
      "build"
  """
  @spec fold(Enumerable.t()) :: t()
  def fold(events), do: Enum.reduce(events, new(), &apply(&2, &1))

  @doc """
  Closes off a projection whose stream ended without `run_finished`: the run, and
  every stage, step and matrix run still `:running`, becomes `:interrupted`. A run
  that did finish is returned unchanged.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> Projection.finalize(Projection.new()).status
      :interrupted
  """
  @spec finalize(t()) :: t()
  def finalize(%__MODULE__{status: :running} = projection) do
    %{projection | status: :interrupted, stages: Enum.map(projection.stages, &interrupt_stage/1)}
  end

  def finalize(%__MODULE__{} = projection), do: projection

  @doc """
  The projection as a JSON-ready map with string keys.

  It is a superset of the shape `TinyCI.Results.to_json/3` produces (`status`,
  `duration_ms`, and `stages` with their steps and matrix runs), adding the run's
  identity, timing, git fields, breakpoints and divergence.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> json = Projection.to_json(Projection.new())
      iex> {json["status"], json["stages"], json["divergent"]}
      {"running", [], false}
  """
  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = p) do
    %{
      "run_id" => p.run_id,
      "pipeline" => p.pipeline,
      "status" => Atom.to_string(p.status),
      "schema_version" => p.schema_version,
      "branch" => p.branch,
      "commit" => p.commit,
      "base_ref" => p.base_ref,
      "root" => p.root,
      "started_at" => p.started_at,
      "finished_at" => p.finished_at,
      "duration_ms" => p.duration_ms,
      "stages" => Enum.map(p.stages, &stage_to_json/1),
      "divergent" => p.divergent?,
      "breakpoints" => p.breakpoints,
      "last_seq" => p.last_seq
    }
  end

  @doc """
  The inverse of `to_json/1`, for reading a `meta.json` back. Missing keys take
  their defaults, so an older or partial file still loads.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> p = Projection.from_json(%{"run_id" => "r1", "status" => "passed"})
      iex> {p.run_id, p.status}
      {"r1", :passed}
  """
  @spec from_json(map()) :: t()
  def from_json(%{} = json) do
    %__MODULE__{
      run_id: json["run_id"],
      pipeline: json["pipeline"],
      status: status(json["status"] || "running"),
      schema_version: json["schema_version"],
      branch: json["branch"],
      commit: json["commit"],
      base_ref: json["base_ref"],
      root: json["root"],
      started_at: json["started_at"],
      finished_at: json["finished_at"],
      duration_ms: json["duration_ms"],
      stages: Enum.map(json["stages"] || [], &stage_from_json/1),
      divergent?: json["divergent"] == true,
      breakpoints: json["breakpoints"] || [],
      last_seq: json["last_seq"] || 0
    }
  end

  @doc """
  Converts the projection into `%TinyCI.StageResult{}` structs so the console
  reporter can print it exactly as it prints a live run.

  Names stay strings, because they come from a file and must not become atoms. A
  unit that never finished (`:running`, `:interrupted`, `:unknown`) is reported as
  `:aborted`. A matrix combination's variables are listed in key order, which can
  differ from the order they were declared in.

  ## Examples

      iex> alias TinyCI.Runs.Projection
      iex> events = [
      ...>   %{"type" => "stage_started", "stage" => "build"},
      ...>   %{"type" => "stage_finished", "stage" => "build", "status" => "passed", "duration_ms" => 3}
      ...> ]
      iex> [result] = events |> Projection.fold() |> Projection.to_stage_results()
      iex> {result.name, result.status, result.duration_ms}
      {"build", :passed, 3}
  """
  @spec to_stage_results(t()) :: [StageResult.t()]
  def to_stage_results(%__MODULE__{stages: stages}), do: Enum.map(stages, &stage_result/1)

  # ---------------------------------------------------------------------------
  # Folding events
  # ---------------------------------------------------------------------------

  defp put_seq(projection, %{"seq" => seq}) when is_integer(seq),
    do: %{projection | last_seq: max(projection.last_seq, seq)}

  defp put_seq(projection, _event), do: projection

  defp effect(p, "run_started", e) do
    %{
      p
      | run_id: e["run_id"],
        pipeline: e["pipeline_name"],
        schema_version: e["schema_version"],
        branch: e["branch"],
        commit: e["commit"],
        base_ref: e["base_ref"],
        root: e["root"],
        started_at: e["ts"]
    }
  end

  defp effect(p, "run_finished", e),
    do: %{p | status: status(e["status"]), finished_at: e["ts"], duration_ms: e["duration_ms"]}

  defp effect(p, "stage_started", e), do: update_stage(p, e["stage"], & &1)

  defp effect(p, "stage_skipped", e) do
    update_stage(p, e["stage"], &%{&1 | status: :skipped, reason: e["reason"], duration_ms: 0})
  end

  defp effect(p, "stage_finished", e) do
    update_stage(
      p,
      e["stage"],
      &%{&1 | status: status(e["status"]), duration_ms: e["duration_ms"]}
    )
  end

  defp effect(p, "step_started", e), do: update_step(p, e, & &1)

  defp effect(p, "step_skipped", e),
    do: update_step(p, e, &%{&1 | status: :skipped, duration_ms: 0})

  defp effect(p, "step_output", e),
    do: update_step(p, e, &%{&1 | output: append_line(&1.output, e["line"])})

  defp effect(p, "step_retrying", e),
    do: update_step(p, e, &%{&1 | attempts: integer_or(e["attempt"], &1.attempts)})

  defp effect(p, "step_finished", e) do
    update_step(p, e, fn step ->
      %{
        step
        | status: status(e["status"]),
          duration_ms: e["duration_ms"],
          allowed_failure: e["allowed_failure"] == true,
          output: finished_output(step.output, e["output"])
      }
    end)
  end

  defp effect(p, "cache_lookup", e), do: update_step(p, e, &%{&1 | cache: cache(e["result"])})

  defp effect(p, "matrix_run_started", e), do: update_matrix_run(p, e, & &1)

  defp effect(p, "matrix_run_finished", e) do
    update_matrix_run(p, e, &%{&1 | status: status(e["status"]), duration_ms: e["duration_ms"]})
  end

  defp effect(p, "breakpoint_hit", e), do: update_pause(p, e, &Map.merge(&1, hit_fields(e)))

  defp effect(p, "breakpoint_resumed", e),
    do: update_pause(p, e, &Map.merge(&1, resume_fields(e)))

  defp effect(p, "run_diverged", _event), do: %{p | divergent?: true}

  defp effect(p, _unknown_type, _event), do: p

  defp update_stage(p, name, fun) when is_binary(name) do
    %{p | stages: upsert(p.stages, &(&1.name == name), %Stage{name: name}, fun)}
  end

  defp update_stage(p, _no_stage, _fun), do: p

  defp update_step(p, %{"stage" => stage, "step" => step} = event, fun) when is_binary(step) do
    update_stage(p, stage, &put_step(&1, event["matrix_combination"], step, fun))
  end

  defp update_step(p, _event, _fun), do: p

  defp put_step(stage, combination, step, fun) when is_map(combination) do
    run_fun = &%{&1 | steps: upsert_step(&1.steps, step, fun)}
    %{stage | matrix_runs: upsert_run(stage.matrix_runs, combination, run_fun)}
  end

  defp put_step(stage, _no_combination, step, fun),
    do: %{stage | steps: upsert_step(stage.steps, step, fun)}

  defp update_matrix_run(p, %{"stage" => stage, "combination" => combination}, fun)
       when is_map(combination) do
    update_stage(p, stage, &%{&1 | matrix_runs: upsert_run(&1.matrix_runs, combination, fun)})
  end

  defp update_matrix_run(p, _event, _fun), do: p

  defp update_pause(p, %{"pause_id" => id}, fun) when is_binary(id) do
    pause = &(&1["pause_id"] == id)
    %{p | breakpoints: upsert(p.breakpoints, pause, %{"pause_id" => id}, fun)}
  end

  defp update_pause(p, _event, _fun), do: p

  defp upsert_step(steps, name, fun),
    do: upsert(steps, &(&1.name == name), %Step{name: name}, fun)

  defp upsert_run(runs, combination, fun),
    do: upsert(runs, &(&1.combination == combination), %MatrixRun{combination: combination}, fun)

  defp upsert(list, match?, default, fun) do
    case Enum.split_while(list, &(not match?.(&1))) do
      {head, [found | tail]} -> head ++ [fun.(found) | tail]
      {all, []} -> all ++ [fun.(default)]
    end
  end

  # `step_finished` carries the step's exact captured output. The line events cannot:
  # they skip blank lines and the trailing newline. So it wins when it has any.
  defp finished_output(_from_lines, output) when is_binary(output) and output != "", do: output
  defp finished_output(from_lines, _no_output), do: from_lines

  defp append_line("", line) when is_binary(line), do: line
  defp append_line(output, line) when is_binary(line), do: output <> "\n" <> line
  defp append_line(output, _not_a_line), do: output

  defp hit_fields(e) do
    e
    |> Map.take(~w(pause_id phase scope stage step breakpoint))
    |> Map.put("hit_at", e["ts"])
  end

  defp resume_fields(e) do
    e
    |> Map.take(~w(command waited_ms timed_out))
    |> Map.put("resumed_at", e["ts"])
  end

  defp integer_or(value, _default) when is_integer(value), do: value
  defp integer_or(_value, default), do: default

  defp cache("hit"), do: :hit
  defp cache("miss"), do: :miss
  defp cache(_other), do: nil

  for name <- ~w(running passed failed skipped aborted interrupted) do
    defp status(unquote(name)), do: unquote(String.to_atom(name))
  end

  defp status(_unrecognised), do: :unknown

  # ---------------------------------------------------------------------------
  # Interrupted runs
  # ---------------------------------------------------------------------------

  defp interrupt_stage(stage) do
    %{
      interrupt(stage)
      | steps: Enum.map(stage.steps, &interrupt/1),
        matrix_runs: Enum.map(stage.matrix_runs, &interrupt_run/1)
    }
  end

  defp interrupt_run(run), do: %{interrupt(run) | steps: Enum.map(run.steps, &interrupt/1)}

  defp interrupt(%{status: :running} = unit), do: %{unit | status: :interrupted}
  defp interrupt(unit), do: unit

  # ---------------------------------------------------------------------------
  # JSON
  # ---------------------------------------------------------------------------

  defp stage_to_json(%Stage{} = s) do
    %{
      "name" => s.name,
      "status" => Atom.to_string(s.status),
      "duration_ms" => s.duration_ms,
      "reason" => s.reason,
      "steps" => Enum.map(s.steps, &step_to_json/1),
      "matrix_runs" => Enum.map(s.matrix_runs, &matrix_run_to_json/1)
    }
  end

  defp step_to_json(%Step{} = s) do
    %{
      "name" => s.name,
      "status" => Atom.to_string(s.status),
      "output" => s.output,
      "duration_ms" => s.duration_ms,
      "allowed_failure" => s.allowed_failure,
      "attempts" => s.attempts,
      "cache" => s.cache && Atom.to_string(s.cache)
    }
  end

  defp matrix_run_to_json(%MatrixRun{} = r) do
    %{
      "combination" => r.combination,
      "status" => Atom.to_string(r.status),
      "duration_ms" => r.duration_ms,
      "steps" => Enum.map(r.steps, &step_to_json/1)
    }
  end

  defp stage_from_json(json) do
    %Stage{
      name: json["name"],
      status: status(json["status"]),
      duration_ms: json["duration_ms"],
      reason: json["reason"],
      steps: Enum.map(json["steps"] || [], &step_from_json/1),
      matrix_runs: Enum.map(json["matrix_runs"] || [], &matrix_run_from_json/1)
    }
  end

  defp step_from_json(json) do
    %Step{
      name: json["name"],
      status: status(json["status"]),
      output: json["output"] || "",
      duration_ms: json["duration_ms"],
      allowed_failure: json["allowed_failure"] == true,
      attempts: json["attempts"] || 1,
      cache: cache(json["cache"])
    }
  end

  defp matrix_run_from_json(json) do
    %MatrixRun{
      combination: json["combination"] || %{},
      status: status(json["status"]),
      duration_ms: json["duration_ms"],
      steps: Enum.map(json["steps"] || [], &step_from_json/1)
    }
  end

  # ---------------------------------------------------------------------------
  # Reporter bridge
  # ---------------------------------------------------------------------------

  defp stage_result(%Stage{} = s) do
    %StageResult{
      name: s.name,
      status: report_status(s.status),
      step_results: Enum.map(s.steps, &step_result/1),
      matrix_runs: Enum.map(s.matrix_runs, &matrix_run_result/1),
      duration_ms: s.duration_ms || 0
    }
  end

  defp step_result(%Step{} = s) do
    %StepResult{
      name: s.name,
      status: report_status(s.status),
      output: s.output,
      duration_ms: s.duration_ms || 0,
      allowed_failure: s.allowed_failure,
      attempts: s.attempts,
      cache_status: s.cache
    }
  end

  defp matrix_run_result(%MatrixRun{} = r) do
    %MatrixRunResult{
      combination: Enum.sort(r.combination),
      status: report_status(r.status),
      step_results: Enum.map(r.steps, &step_result/1),
      duration_ms: r.duration_ms || 0
    }
  end

  defp report_status(status) when status in [:passed, :failed, :skipped, :aborted], do: status
  defp report_status(_unfinished), do: :aborted
end
