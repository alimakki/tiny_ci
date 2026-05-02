# User Story: T0.5 — Event Structs

## Story

As a pipeline author and tooling developer,  
I want a complete, typed vocabulary of pipeline execution events defined as Elixir structs,  
so that every phase of a run (pipeline, stage, step, matrix, hooks) can be captured, serialized, and consumed by downstream systems (event log, web dashboard, TUI) in a consistent, type-safe way.

## Acceptance Criteria

- `lib/tiny_ci/events.ex` defines all 14 event structs:
  `PipelineStarted`, `PipelineCompleted`, `StageStarted`, `StageSkipped`, `StageCompleted`,
  `StepStarted`, `StepSkipped`, `StepOutputLine`, `StepRetrying`, `StepCompleted`,
  `MatrixRunStarted`, `MatrixRunCompleted`, `HookStarted`, `HookCompleted`
- All structs include `run_id: String.t()` and `timestamp: DateTime.t()` as `@enforce_keys`
- All structs carry a complete `@type t` spec with field-level types
- All structs implement `Jason.Encoder` so they serialize to clean JSON via `Jason.encode!/1`
- `timestamp` serializes as an ISO 8601 string (e.g. `"2024-01-15T10:30:00.000000Z"`)
- `atom()` fields (stage, step, hook, pipeline_name, status) serialize as strings in JSON
- Round-trip: a struct serialized to JSON and decoded back produces the same values
- `mix compile --warnings-as-errors` — zero warnings
- `mix credo` — no issues

---

## Tasks

### Tests (written first)

- [x] Write struct construction tests for all 14 events (enforce_keys are required)
- [x] Write type/field tests: every struct has `run_id` and `timestamp` fields
- [x] Write Jason.Encoder tests: `Jason.encode!/1` succeeds for each struct
- [x] Write JSON field tests: `timestamp` serializes as ISO 8601 string
- [x] Write JSON field tests: atom fields (`stage`, `step`, `status`, etc.) serialize as strings
- [x] Write JSON field tests: integer fields (`duration_ms`, `attempt`) serialize as numbers
- [x] Write JSON field tests: `combination` on matrix events serializes as an object
- [x] Write error tests: constructing a struct without `run_id` raises `ArgumentError`
- [x] Write error tests: constructing a struct without `timestamp` raises `ArgumentError`

### Implementation

- [x] Create `lib/tiny_ci/events.ex` with top-level `@moduledoc`
- [x] Define `TinyCI.Events.PipelineStarted` — fields: `run_id`, `timestamp`, `pipeline_name`
- [x] Define `TinyCI.Events.PipelineCompleted` — fields: `run_id`, `timestamp`, `status`, `duration_ms`
- [x] Define `TinyCI.Events.StageStarted` — fields: `run_id`, `timestamp`, `stage`
- [x] Define `TinyCI.Events.StageSkipped` — fields: `run_id`, `timestamp`, `stage`, `reason`
- [x] Define `TinyCI.Events.StageCompleted` — fields: `run_id`, `timestamp`, `stage`, `status`, `duration_ms`
- [x] Define `TinyCI.Events.StepStarted` — fields: `run_id`, `timestamp`, `stage`, `step`
- [x] Define `TinyCI.Events.StepSkipped` — fields: `run_id`, `timestamp`, `stage`, `step`, `reason`
- [x] Define `TinyCI.Events.StepOutputLine` — fields: `run_id`, `timestamp`, `stage`, `step`, `line`
- [x] Define `TinyCI.Events.StepRetrying` — fields: `run_id`, `timestamp`, `stage`, `step`, `attempt`
- [x] Define `TinyCI.Events.StepCompleted` — fields: `run_id`, `timestamp`, `stage`, `step`, `status`, `duration_ms`
- [x] Define `TinyCI.Events.MatrixRunStarted` — fields: `run_id`, `timestamp`, `stage`, `combination`
- [x] Define `TinyCI.Events.MatrixRunCompleted` — fields: `run_id`, `timestamp`, `stage`, `combination`, `status`, `duration_ms`
- [x] Define `TinyCI.Events.HookStarted` — fields: `run_id`, `timestamp`, `hook`
- [x] Define `TinyCI.Events.HookCompleted` — fields: `run_id`, `timestamp`, `hook`, `status`, `duration_ms`
- [x] Implement `Jason.Encoder` for each struct, serializing atoms as strings and `DateTime` as ISO 8601

### Quality

- [x] `mix format` — no formatting issues
- [x] `mix compile --warnings-as-errors` — zero warnings
- [x] `mix test` — all tests pass (525 tests, 0 failures)
- [x] `mix credo` — no issues
- [x] Document the event system in README.md
