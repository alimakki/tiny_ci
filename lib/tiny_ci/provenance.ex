defmodule TinyCI.Provenance do
  @moduledoc """
  Builds a signed-attestation *statement* describing exactly what a run did.

  The statement is an [in-toto](https://in-toto.io) Statement carrying a TinyCI
  provenance predicate: the run's identity and outcome, every step that executed
  (with status and duration), and every action that ran (with the version and
  checksum pinned by the lockfile, from `TinyCI.Action.Audit`).

  ## Source of truth

  "What ran" is read from the **T1 event stream** (collected by
  `TinyCI.Provenance.Collector`), never from executor internals — so the
  attestation reflects observed execution. The static step→action mapping comes
  from the `%TinyCI.PipelineSpec{}`, and version/checksum data from the resolved
  action graph.

  `build/1` is pure; signing and envelope wrapping live in
  `TinyCI.Provenance.Attestation`.

  ## Divergent runs

  A run that execution control altered (T10 — `set_store`, a forced `skip`, a
  forced `retry`) is flagged `divergent` in the predicate, with each change listed
  under `divergences`. `divergent?/1` exposes the same judgement, and
  `mix tiny_ci.run --attest` refuses to sign such a run: it records what an
  operator made happen, not what the pipeline does.
  """

  alias TinyCI.Events.{
    PipelineCompleted,
    PipelineStarted,
    RunDiverged,
    StepCompleted,
    StepSkipped
  }

  alias TinyCI.PipelineSpec

  @statement_type "https://in-toto.io/Statement/v1"
  @predicate_type "https://tiny-ci.dev/provenance/v0.1"
  @tool "tiny_ci"

  @doc """
  Builds an in-toto provenance statement (a JSON-ready map with string keys).

  ## Options

    * `:events`  — the collected `TinyCI.Events` structs for the run (required)
    * `:spec`    — the `%TinyCI.PipelineSpec{}` that ran (required)
    * `:actions` — resolved action entries from `TinyCI.Action.Audit.analyze/3`
    * `:commit`  — the git commit SHA
    * `:branch`  — the git branch
    * `:tool_version` — the tiny_ci version recorded as the builder (defaults `"0.1.0"`)
  """
  @spec build(keyword()) :: map()
  def build(opts) do
    events = Keyword.fetch!(opts, :events)
    spec = Keyword.fetch!(opts, :spec)
    actions = Keyword.get(opts, :actions, [])
    commit = Keyword.get(opts, :commit, "unknown")
    branch = Keyword.get(opts, :branch, "unknown")
    tool_version = Keyword.get(opts, :tool_version, "0.1.0")

    step_actions = step_action_map(spec)
    steps = build_steps(events, step_actions)
    executed = executed_modules(steps)

    %{
      "_type" => @statement_type,
      "predicateType" => @predicate_type,
      "subject" => [
        %{"name" => to_string(spec.name), "digest" => %{"gitCommit" => commit}}
      ],
      "predicate" => %{
        "runId" => run_id(events),
        "pipeline" => to_string(spec.name),
        "branch" => branch,
        "commit" => commit,
        "outcome" => outcome(events),
        "startedAt" => started_at(events),
        "finishedAt" => finished_at(events),
        "builder" => %{"tool" => @tool, "version" => tool_version},
        "divergent" => divergent?(events),
        "divergences" => build_divergences(events),
        "actions" => build_actions(actions, executed, steps),
        "steps" => steps
      }
    }
  end

  @doc """
  Returns `true` when execution control altered the run (T10).

  A `set_store`, a forced `skip`, or a forced `retry` each emit
  `TinyCI.Events.RunDiverged`. Such a run describes what an operator made happen,
  not what the pipeline does, so `mix tiny_ci.run --attest` refuses to sign it —
  the statement is still buildable so the divergence can be inspected.

  ## Examples

      iex> TinyCI.Provenance.divergent?([])
      false

      iex> event = %TinyCI.Events.RunDiverged{
      ...>   run_id: "r", timestamp: DateTime.utc_now(), reason: :set_store
      ...> }
      iex> TinyCI.Provenance.divergent?([event])
      true
  """
  @spec divergent?([TinyCI.Events.t()]) :: boolean()
  def divergent?(events), do: Enum.any?(events, &match?(%RunDiverged{}, &1))

  # ---------------------------------------------------------------------------
  # Divergences (from the event stream)
  # ---------------------------------------------------------------------------

  defp build_divergences(events) do
    for %RunDiverged{} = event <- events do
      %{
        "reason" => to_string(event.reason),
        "stage" => stage_or_step(event.stage),
        "step" => stage_or_step(event.step),
        "detail" => event.detail,
        "at" => iso(event.timestamp)
      }
    end
  end

  defp stage_or_step(nil), do: nil
  defp stage_or_step(name), do: to_string(name)

  # ---------------------------------------------------------------------------
  # Steps (from the event stream)
  # ---------------------------------------------------------------------------

  defp build_steps(events, step_actions) do
    Enum.flat_map(events, &step_entry(&1, step_actions))
  end

  defp step_entry(%StepCompleted{} = e, step_actions) do
    [
      %{
        "stage" => to_string(e.stage),
        "step" => to_string(e.step),
        "status" => to_string(e.status),
        "durationMs" => e.duration_ms,
        "action" => action_name(step_actions[{e.stage, e.step}])
      }
    ]
  end

  defp step_entry(%StepSkipped{} = e, step_actions) do
    [
      %{
        "stage" => to_string(e.stage),
        "step" => to_string(e.step),
        "status" => "skipped",
        "durationMs" => nil,
        "action" => action_name(step_actions[{e.stage, e.step}])
      }
    ]
  end

  defp step_entry(_other, _step_actions), do: []

  # A step "executed" when it produced a step_finished event (skipped steps did not).
  defp executed_modules(steps) do
    for %{"status" => status, "action" => action} <- steps,
        status != "skipped",
        action != nil,
        into: MapSet.new(),
        do: action
  end

  # ---------------------------------------------------------------------------
  # Actions (from the resolved graph, filtered to those that executed)
  # ---------------------------------------------------------------------------

  defp build_actions(actions, executed, steps) do
    actions
    |> Enum.filter(&MapSet.member?(executed, action_name(&1.module)))
    |> Enum.map(fn action ->
      name = action_name(action.module)

      %{
        "module" => name,
        "app" => app_string(action.app),
        "version" => action.version,
        "checksum" => action.checksum,
        "source" => to_string(action.source),
        "steps" => steps_using(steps, name)
      }
    end)
  end

  defp steps_using(steps, action_name) do
    for %{"action" => ^action_name, "stage" => stage, "step" => step} <- steps,
        do: %{"stage" => stage, "step" => step}
  end

  # ---------------------------------------------------------------------------
  # Spec: step → module
  # ---------------------------------------------------------------------------

  defp step_action_map(%PipelineSpec{stages: stages}) do
    for %{name: stage, steps: steps} <- stages,
        %{name: step, module: module} <- steps,
        not is_nil(module),
        into: %{},
        do: {{stage, step}, module}
  end

  # ---------------------------------------------------------------------------
  # Event lookups
  # ---------------------------------------------------------------------------

  defp run_id(events), do: find_value(events, &match?(%PipelineStarted{}, &1), & &1.run_id)

  defp started_at(events),
    do: find_value(events, &match?(%PipelineStarted{}, &1), &iso(&1.timestamp))

  defp finished_at(events),
    do: find_value(events, &match?(%PipelineCompleted{}, &1), &iso(&1.timestamp))

  defp outcome(events) do
    case find_value(events, &match?(%PipelineCompleted{}, &1), & &1.status) do
      :passed -> "success"
      :failed -> "failure"
      other when is_atom(other) and not is_nil(other) -> to_string(other)
      _ -> "unknown"
    end
  end

  defp find_value(events, pred, extract) do
    case Enum.find(events, pred) do
      nil -> nil
      event -> extract.(event)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp action_name(nil), do: nil
  defp action_name(module) when is_atom(module), do: inspect(module)

  defp app_string(nil), do: nil
  defp app_string(app), do: to_string(app)

  defp iso(nil), do: nil
  defp iso(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
end
