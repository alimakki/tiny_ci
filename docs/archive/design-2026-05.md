# TinyCI — Design Specification
## Event-Sourced Execution, Adaptive Test Isolation, and Fault-Tolerant Stages

---

## 0. Purpose and Scope

This document specifies three interrelated capabilities for TinyCI, each derived from ideas in the "BEAM-native CI" conversation, filtered through a quality engineering lens. Each section covers motivation, detailed design, integration with the existing codebase, tradeoffs, and DX considerations.

The three capabilities are:

1. **Event-Sourced Execution Engine** — an append-only event log that becomes the authoritative record of every pipeline run, enabling run history, live streaming to UI consumers, and step-level replay
2. **Adaptive Flaky Test Isolation** — per-test retry and quarantine, surfacing individual test failures rather than retrying entire step commands
3. **Fault-Tolerant Stage Execution** — a `continue_on_failure:` mode for serial stages that collects all failures instead of halting on the first one, and a hardened parallel mode that prevents one crashing Task from corrupting sibling execution

These three are listed in implementation priority order. Each can be shipped independently. They share a common dependency: **the event log** (Capability 1) is the substrate that makes Capabilities 2 and 3 observable without coupling them to any specific UI or persistence backend.

---

## 1. Event-Sourced Execution Engine

### 1.1 Motivation

Today, TinyCI's executor is a pure function: it takes stages + context and returns `{:ok, [StageResult]}` or `{:error, ...}`. Results are printed to stdout via `Reporter` and then discarded. Nothing persists across runs. There is no way for an external consumer (a web UI, a TUI, a webhook) to observe execution as it happens.

To support the planned web frontend and TUI, and to make run history possible without a heavyweight persistence layer, every meaningful state transition during execution should emit a typed, serializable event to an append-only log. Pipeline state at any moment is a pure projection of that log.

This is the BEAM GPT conversation's "event-sourced execution model" applied concretely and incrementally — without rewriting the executor.

### 1.2 Architecture Overview

```
Executor (unchanged contract)
    │
    │  emits events as a side effect
    ▼
TinyCI.EventLog  ←── ETS table (fast, per-run, in-memory)
    │
    ├── Projector  →  current pipeline state (for live queries)
    ├── Disk sink  →  ~/.tiny_ci/runs/<run_id>.jsonl (persistence)
    └── PubSub     →  broadcast to web/TUI subscribers
```

The executor's return value and calling convention are **unchanged**. Events are emitted via calls to `TinyCI.EventLog.emit/1` at natural boundaries in the executor code. The log is ETS-backed so emission is non-blocking. Disk writes and PubSub broadcasts happen in a separate GenServer so they cannot slow down execution.

### 1.3 Event Schema

All events share a common header and are tagged structs:

```elixir
# Common header embedded in every event
%{run_id: String.t(), timestamp: DateTime.t()}

# ── Pipeline ──────────────────────────────────────────────────────────────
%TinyCI.Events.PipelineStarted{
  run_id: String.t(),          # "20260423_143201_main_a1b2c3d"
  pipeline_name: atom(),
  branch: String.t(),
  commit: String.t(),
  timestamp: DateTime.t()
}

%TinyCI.Events.PipelineCompleted{
  run_id: String.t(),
  status: :passed | :failed,
  duration_ms: non_neg_integer(),
  timestamp: DateTime.t()
}

# ── Stage ─────────────────────────────────────────────────────────────────
%TinyCI.Events.StageStarted{
  run_id: String.t(),
  stage_name: atom(),
  mode: :serial | :parallel,
  needs: [atom()],
  timestamp: DateTime.t()
}

%TinyCI.Events.StageSkipped{
  run_id: String.t(),
  stage_name: atom(),
  reason: :condition_not_met | :dependency_failed,
  timestamp: DateTime.t()
}

%TinyCI.Events.StageCompleted{
  run_id: String.t(),
  stage_name: atom(),
  status: :passed | :failed | :skipped,
  duration_ms: non_neg_integer(),
  timestamp: DateTime.t()
}

# ── Step ──────────────────────────────────────────────────────────────────
%TinyCI.Events.StepStarted{
  run_id: String.t(),
  stage_name: atom(),
  step_name: atom(),
  type: :cmd | :module,
  cmd: String.t() | nil,
  working_dir: String.t() | nil,
  env: map(),
  timestamp: DateTime.t()
}

%TinyCI.Events.StepSkipped{
  run_id: String.t(),
  stage_name: atom(),
  step_name: atom(),
  timestamp: DateTime.t()
}

%TinyCI.Events.StepOutputLine{
  run_id: String.t(),
  stage_name: atom(),
  step_name: atom(),
  line: String.t(),
  timestamp: DateTime.t()
}

%TinyCI.Events.StepRetrying{
  run_id: String.t(),
  stage_name: atom(),
  step_name: atom(),
  attempt: pos_integer(),
  max_attempts: pos_integer(),
  timestamp: DateTime.t()
}

%TinyCI.Events.StepCompleted{
  run_id: String.t(),
  stage_name: atom(),
  step_name: atom(),
  status: :passed | :failed | :skipped,
  duration_ms: non_neg_integer(),
  exit_code: integer() | nil,      # nil for module steps
  attempts: pos_integer(),
  store_updates: map(),
  timestamp: DateTime.t()
}

# ── Matrix ────────────────────────────────────────────────────────────────
%TinyCI.Events.MatrixRunStarted{
  run_id: String.t(),
  stage_name: atom(),
  combination: keyword(String.t()),
  combination_label: String.t(),
  timestamp: DateTime.t()
}

%TinyCI.Events.MatrixRunCompleted{
  run_id: String.t(),
  stage_name: atom(),
  combination_label: String.t(),
  status: :passed | :failed,
  duration_ms: non_neg_integer(),
  timestamp: DateTime.t()
}

# ── Hook ──────────────────────────────────────────────────────────────────
%TinyCI.Events.HookStarted{
  run_id: String.t(),
  hook_name: atom(),
  hook_type: :on_success | :on_failure,
  timestamp: DateTime.t()
}

%TinyCI.Events.HookCompleted{
  run_id: String.t(),
  hook_name: atom(),
  status: :passed | :failed,
  duration_ms: non_neg_integer(),
  timestamp: DateTime.t()
}
```

**Design decisions:**

- `run_id` is generated at `run_pipeline/3` entry: `"#{date}_#{time}_#{branch_slug}_#{commit_short}"`. It is stored in the pipeline context so all executor functions can access it without threading a separate parameter.
- `StepOutputLine` captures every line emitted from `Output.collect_port/4`. This is the highest-volume event. For large test suites this could be thousands of events per run. The ETS table uses a bag (not a set) to preserve order. See §1.7 for volume considerations.
- Events are not sent to `StepOutputLine` in buffered mode (non-TTY, matrix runs). This is a deliberate tradeoff: buffered mode already captures full output in `StepResult.output`, so there is no need to also emit line-by-line events.

### 1.4 TinyCI.EventLog Module

```elixir
defmodule TinyCI.EventLog do
  # Public API
  def start_run(run_id)      :: :ok
  def emit(event)             :: :ok          # fire-and-forget, never blocks
  def get_events(run_id)      :: [event]       # all events for a run
  def stream_events(run_id)   :: Enumerable.t  # lazy stream from ETS
  def subscribe(run_id, pid)  :: :ok           # send each new event to pid
  def unsubscribe(run_id, pid) :: :ok
end
```

**Internals:**

- One ETS table per run: `:"tiny_ci_run_#{run_id}"`. The table is a `:bag` (allows duplicate keys) owned by a GenServer (`TinyCI.RunRegistry`) that is started when the OTP application starts.
- `emit/1` is a simple `ETS.insert/2`. O(1), never blocks the caller.
- The `RunRegistry` GenServer also handles: disk sink (writes JSON lines to `~/.tiny_ci/runs/<run_id>.jsonl`), subscriber notifications (sends events to all `subscribe/2` callers).
- ETS tables for completed runs are garbage-collected after 1 hour by the RunRegistry via `Process.send_after/3`. Long-lived installations need this cleanup or memory grows unboundedly.

**Addition to `TinyCI.Application`:**

```elixir
children = [
  {Task.Supervisor, name: TinyCI.TaskSupervisor},
  TinyCI.RunRegistry  # new
]
```

### 1.5 Integration Points in the Executor

The executor already has clear natural boundaries. Event emission slots in without restructuring:

| Boundary | Event emitted |
|----------|---------------|
| `run_pipeline/3` entry | `PipelineStarted` |
| `run_pipeline/3` return | `PipelineCompleted` |
| `execute/3` entry — stage skipped | `StageSkipped` |
| `execute/3` entry — stage runs | `StageStarted` |
| `execute_regular_stage/3` return | `StageCompleted` |
| `execute_matrix_stage/3` per-combination start | `MatrixRunStarted` |
| `execute_matrix_stage/3` per-combination end | `MatrixRunCompleted` |
| Step execution — before command | `StepStarted` |
| Step execution — step skipped | `StepSkipped` |
| Step retry loop — before each retry | `StepRetrying` |
| Step execution — after command | `StepCompleted` |
| `Output.collect_port/4` — each line | `StepOutputLine` |
| `Hooks` — before hook | `HookStarted` |
| `Hooks` — after hook | `HookCompleted` |

The `run_id` is added to the pipeline context at `run_pipeline/3`:

```elixir
ctx = Map.put_new(ctx, :run_id, generate_run_id(ctx))
```

Every executor function already receives `ctx`, so `ctx.run_id` is available at all emission points with no signature changes.

For `Output.collect_port/4`, the `run_id`, `stage_name`, and `step_name` need to be passed in. `Output.run_cmd/2` already accepts opts — extend with `opts[:event_context]` containing these three fields. If `event_context` is nil, no events are emitted (backward-compatible).

### 1.6 State Projector

The projector rebuilds the current logical state of a run from its event log. It is a pure function used for queries (web UI, `mix tiny_ci.runs show`):

```elixir
defmodule TinyCI.RunProjector do
  @spec project([event]) :: run_state()

  @type run_state :: %{
    run_id: String.t(),
    status: :running | :passed | :failed,
    started_at: DateTime.t(),
    finished_at: DateTime.t() | nil,
    duration_ms: non_neg_integer() | nil,
    stages: %{atom() => stage_state()},
    store: map()
  }
end
```

The projector is called:
- By the web frontend when loading a completed run detail page (projects from disk log)
- By `TinyCI.RunRegistry` to maintain live in-memory state for the active run (projects from ETS as events arrive)

### 1.7 Replay Mechanics

"Replay this step" means: re-run a step with the exact same inputs as a previous run.

The `StepStarted` event captures: `cmd`, `working_dir`, `env`. This is the full input required to re-execute a shell step. For module steps, capturing the config keyword list is also required — add `config: keyword()` to `StepStarted`.

A replay operation:
1. Load the event log for run `<run_id>` from disk
2. Find the `StepStarted` event for the target step
3. Find the last `PipelineStarted` event (for run context)
4. Reconstruct a minimal `%TinyCI.Stage{}` containing only the target step
5. Call `Executor.execute/3` with the reconstructed stage and context
6. Emit events under a new `run_id` with `parent_run_id` set to the original

This gives "replay this step with the same inputs" without message-level determinism. It is practical replay, not mathematical replay.

**What replay cannot guarantee:** if the step's behavior depends on external state (a flaky network, a filesystem that changed), the outcome may differ. That is acceptable and expected — the point is to re-run with the same *declared* inputs, not the same universe.

### 1.8 Run History CLI

```
mix tiny_ci.runs list           # last 20 runs, status + duration
mix tiny_ci.runs show <run_id>  # full stage/step tree (same format as Reporter)
mix tiny_ci.runs logs <run_id> <step>  # full output for a single step
mix tiny_ci.runs replay <run_id> --stage :test --step :unit  # replay a step
```

### 1.9 Pros and Cons

**Pros:**

- **Single source of truth.** The disk log is the authoritative record. The reporter, web UI, and TUI all read from the same source — there is no divergence between what was printed to the terminal and what the UI shows.
- **Run history is free.** No separate database query layer needed. The log files are the history. They can be `grep`-ed, parsed by scripts, archived, or deleted individually.
- **Decouples consumers.** The web frontend, TUI, and future integrations subscribe to the event stream. The executor knows nothing about them. New consumers are added without touching the executor.
- **Incremental.** The executor's contract doesn't change. `emit/1` is a side effect that can be added to one function at a time and tested in isolation.
- **Searchable output.** `StepOutputLine` events make step output searchable across runs without loading full output blobs. "Find all runs where step :unit emitted 'ConnectionError'" becomes a log scan.
- **Debuggability.** "What happened in this run?" is answered by reading the event log, not by re-running the pipeline. The timeline of events is the ground truth.

**Cons:**

- **Volume.** `StepOutputLine` can be high-frequency for large test suites. A test run emitting 10,000 lines creates 10,000 ETS entries and 10,000 JSON lines on disk. This is manageable (ETS is fast; JSON lines at ~200 bytes each is ~2MB per run) but needs monitoring for extreme cases. Mitigation: a `max_output_lines: N` config to cap captured lines, or only emit output events when the step has `capture_output: true`.
- **Schema evolution.** Event structs are serialized to disk. If a field is added or removed, old log files become incompatible. Mitigation: version the event schema. Each JSON line includes `"schema_version": 1`. The projector handles version-specific deserialization.
- **ETS lifetime.** The in-memory ETS table for a completed run holds all events until garbage-collected by the RunRegistry. For long pipelines with verbose output, this is non-trivial memory. Mitigation: stream events from disk when projecting a completed run rather than loading into ETS.
- **`StepOutputLine` in buffered mode.** We chose to skip per-line events in buffered mode (matrix runs, non-TTY). This means the web UI cannot stream output line-by-line for matrix runs — it only sees the full output after the run completes. This is a known limitation and a reasonable tradeoff for now.

### 1.10 Developer Experience

**Pipeline authors** see nothing. Events are infrastructure, not DSL. Adding `event_log: false` to the mix task config disables disk persistence for users who don't want it.

**Operators** get a new `mix tiny_ci.runs` sub-task with list, show, logs, and replay commands. These are additive — the existing `mix tiny_ci.run` behavior is unchanged.

**Web/TUI consumers** subscribe to `EventLog.subscribe(run_id, self())` and receive events as they arrive. The web frontend's LiveView process subscribes on page load and renders updates without polling.

**Testing** the event log: `ExecutorTest` cases can assert that specific events were emitted by subscribing to the EventLog before running a pipeline:

```elixir
test "emits StepCompleted event" do
  EventLog.subscribe(run_id, self())
  Executor.run_pipeline([stage], context)
  assert_receive %Events.StepCompleted{step_name: :unit, status: :passed}
end
```

---

## 2. Adaptive Flaky Test Isolation

### 2.1 Motivation

TinyCI currently retries at the *step* level. If `mix test` fails, the entire `mix test` command reruns. For a 500-test suite with 2 flaky tests, you re-run 500 tests to recover 2. This wastes time and obscures signal — developers don't know whether a failure is a real regression or a known flake until they rerun manually.

The BEAM's lightweight processes make per-test retry natural: each re-run of an isolated failing test is a Task with no shared state with the other tests. The design below surfaces this capability through the pipeline DSL without requiring pipeline authors to understand processes.

### 2.2 Scope Boundary

This feature is intentionally scoped to **ExUnit** for the initial implementation. Other test frameworks (pytest, Jest, Vitest, etc.) are architecturally supported via a pluggable parser interface but are not shipped until there is demand. This keeps the implementation focused and avoids building parsers for frameworks that may never be used by TinyCI's audience.

### 2.3 Design

#### 2.3.1 DSL

```elixir
step :unit,
  cmd: "mix test",
  test_runner: :ex_unit,        # enables adaptive behavior
  flaky_retries: 2,             # retry failing tests up to 2 times individually
  quarantine_threshold: 3,      # quarantine after 3 failures across recent runs
  quarantine_path: ".tiny_ci/quarantine.json"  # optional, default shown
```

When `test_runner:` is absent, the step behaves exactly as today. No behavior change for existing pipelines.

#### 2.3.2 Execution Flow

```
1. Run cmd normally
       │
       ▼
2. If exit 0 → StepCompleted(:passed)  [same as today]
       │
       ▼ (exit non-zero)
3. Parse stdout for failing test identifiers
       │
       ▼
4. Check quarantine list: is this test already quarantined?
   ├── YES → mark this specific test as quarantined_failure, continue
   └── NO  → proceed to per-test retry
       │
       ▼
5. Re-run only failing tests (one Task per test)
       │
       ▼
6. If all retries pass → StepCompleted(:passed) + emit TestFlakyRecovered events
   If any test still fails after flaky_retries:
     ├── Not yet at quarantine_threshold → StepCompleted(:failed)
     └── At quarantine_threshold → update quarantine list, StepCompleted(:passed with quarantine warning)
```

#### 2.3.3 ExUnit Test Parser

ExUnit prints failing tests in a deterministic format:

```
  1) test user login with valid credentials (MyApp.AuthTest)
     test/my_app/auth_test.exs:42
     ...
```

`TinyCI.TestParsers.ExUnit` extracts `{file, line}` pairs from stdout using a regex over the numbered failure list. This is brittle only if ExUnit changes its output format — which it has not done meaningfully since ExUnit 1.0.

The re-run command is constructed as:
```
mix test test/my_app/auth_test.exs:42 test/other_test.exs:88
```
This is a documented, stable ExUnit feature.

#### 2.3.4 Parser Interface

```elixir
defmodule TinyCI.TestParser do
  @type test_id :: %{file: String.t(), line: pos_integer(), name: String.t()}

  @callback parse_failures(output :: String.t()) :: [test_id()]
  @callback build_rerun_cmd(base_cmd :: String.t(), test_ids :: [test_id()]) :: String.t()
end
```

`TinyCI.TestParsers.ExUnit` implements this behaviour. Future parsers for pytest, Jest, etc. implement the same interface and are registered in a lookup map keyed by the `test_runner:` atom.

#### 2.3.5 Flakiness Tracking

Flakiness history is persisted to a JSON file at `quarantine_path` (default: `.tiny_ci/quarantine.json`, committed to the repo so the team shares the quarantine list).

Structure:

```json
{
  "test/my_app/auth_test.exs:42": {
    "name": "test user login with valid credentials",
    "failures": 5,
    "passes": 12,
    "last_failed": "2026-04-23T14:32:01Z",
    "quarantined": false
  }
}
```

`quarantine_threshold: 3` means: if `failures >= 3` in the tracking file, mark the test as quarantined on the next failure. Quarantined tests still run (their quarantine status is not a skip — teams should fix flaky tests, not ignore them). They are reported distinctly in the pipeline summary and in the web UI.

#### 2.3.6 Event Integration

Three new events feed into the EventLog:

```elixir
%Events.TestFlakyRetried{run_id, stage_name, step_name, test_id, attempt}
%Events.TestFlakyRecovered{run_id, stage_name, step_name, test_id, attempt}
%Events.TestQuarantined{run_id, stage_name, step_name, test_id, failure_count}
```

The web UI can show a "Flaky Tests" tab summarizing tests that needed retries or are quarantined, across runs.

### 2.4 Pros and Cons

**Pros:**

- **Dramatic reduction in re-run cost.** Re-running 2 tests out of 500 is 250x cheaper than re-running all 500.
- **Surfaces real signal.** Teams know which tests are flaky (the quarantine list) vs which are genuine regressions (new failures on tests not in the quarantine list).
- **Zero configuration for the common case.** `test_runner: :ex_unit` auto-detects `mix test` and the standard ExUnit output format. No additional setup.
- **The quarantine list is tracked in version control.** The team owns the quarantine list. It's not a hidden CI setting — it's auditable.
- **BEAM concurrency is a natural fit.** Each per-test re-run is a `Task` with no shared mutable state. The BEAM's scheduler handles concurrency for free.

**Cons:**

- **Brittle parsing.** The ExUnit output parser depends on ExUnit's output format. Changes to ExUnit's failure summary would break it. Mitigation: pin to tested ExUnit versions; add an integration test against real ExUnit output.
- **ExUnit-only at launch.** Teams using pytest or Jest get no benefit. Mitigation: the parser interface is open; contributors can add parsers.
- **Quarantine abuse.** A team can quarantine a genuinely broken test by reaching the threshold. Mitigation: emit warnings in the reporter when a test has been quarantined for more than N days.
- **Does not handle test-order-dependent failures.** Some flaky tests only fail when run after a specific other test. Per-test re-run in isolation won't detect this. Mitigation: document the limitation; it's a separate problem.
- **`mix test path:line` doesn't support all test selectors.** Some ExUnit tests are generated dynamically or use `:only` tags. Mitigation: fall back to the full step retry if the re-run command is unparseable.

### 2.5 Developer Experience

**Happy path** — a developer adds `test_runner: :ex_unit` to their test step. On the next flaky run, the reporter shows:

```
  ✓ test — passed (12.3s)
    ○ unit — flaky recovery (2 tests retried, passed on attempt 2)
      ⚠ test/auth_test.exs:42 recovered (attempt 2)
      ⚠ test/user_test.exs:88 recovered (attempt 2)
```

**Quarantine notification** — when a test is quarantined:

```
  ✓ test — passed with warnings (12.3s)
    ⚠ unit — 1 test quarantined (see .tiny_ci/quarantine.json)
      ○ test/auth_test.exs:42 [QUARANTINED] failed 3 times, not blocking pipeline
```

**Dry run** — shows the quarantine list:

```
  ▶ :test (parallel)
    • :unit — cmd: "mix test" [test_runner: ex_unit, flaky_retries: 2]
      Quarantined tests (1): test/auth_test.exs:42
```

---

## 3. Fault-Tolerant Stage Execution

### 3.1 Motivation

TinyCI's serial stages halt on the first failing step (`Enum.reduce_while` with `:halt`). For a lint stage running format check + credo + dialyzer in series, a format failure stops credo from running. The developer fixes the format issue, reruns, and discovers a credo failure. They fix that. They rerun again and find a dialyzer failure.

This is the classic "onion peeling" CI failure experience. Teams want all failures at once. The fix is a `continue_on_failure: true` option for serial stages that runs all steps and reports all failures together.

For parallel stages, a secondary issue exists: an uncaught exception in a Task process (not a non-zero exit code, but an actual Elixir exception thrown by a module step) currently propagates to `Task.await_many/2` and raises in the executor, potentially corrupting partial results. The executor needs to handle task crashes gracefully.

### 3.2 Design

#### 3.2.1 `continue_on_failure:` for Serial Stages

```elixir
stage :lint, mode: :serial, continue_on_failure: true do
  step :format, cmd: "mix format --check-formatted"
  step :credo,  cmd: "mix credo"
  step :dialyzer, cmd: "mix dialyzer"
end
```

When `continue_on_failure: true`, the serial execution loop uses `Enum.reduce` instead of `Enum.reduce_while` — it runs all steps and accumulates results. The stage is marked `:failed` if any step failed, but all steps ran.

**Store semantics with `continue_on_failure:`**: In normal serial mode, a failed step's store updates propagate to later steps in the same stage (because later steps might depend on earlier store values). With `continue_on_failure:`, later steps still receive the store from prior steps — the behavior is the same as if each prior step had succeeded, using whatever store data was produced up to the failure.

**Field addition to `TinyCI.Stage`:**

```elixir
continue_on_failure: boolean()  # default: false
```

#### 3.2.2 Hardened Parallel Execution (Task Crash Recovery)

Currently, `execute_by_mode/3` for parallel stages spawns tasks and calls `Task.await_many/2`. If a module step raises an uncaught exception, the Task exits abnormally and `Task.await_many/2` raises in the executor process.

The fix: replace `Task.await_many/2` with a manual `Task.yield_many/2` loop that handles both normal returns and exits:

```elixir
tasks = Enum.map(steps, &spawn_step_task/3)
results = Task.yield_many(tasks, :infinity)
step_results = Enum.map(results, fn
  {_task, {:ok, result}}   -> result
  {task,  {:exit, reason}} -> crashed_step_result(task, reason)
  {task,  nil}             -> timed_out_step_result(task)
end)
```

`crashed_step_result/2` produces a `%StepResult{status: :failed, output: "Step crashed: #{inspect(reason)}"}`. The stage continues collecting all step results rather than raising. This brings parallel stages to parity with shell steps — they fail gracefully rather than crashing the executor.

#### 3.2.3 Step-Level Supervision (Future, Not Now)

The GPT conversation describes mapping OTP supervision strategies (`:one_for_one`, `:rest_for_one`) onto CI stages. This is architecturally sound for the distributed, multi-node case — where a worker node dying should restart affected steps on another node. **This is explicitly deferred** until TinyCI has a distributed agent model, because it requires:

- Persistent step state (to know where to resume after restart)
- Multiple execution nodes
- A scheduler that understands topology

For the single-node (local) case, the retry mechanism combined with `continue_on_failure:` covers the practical need. Structural OTP supervision is over-engineering for that scope.

### 3.3 Pros and Cons

**`continue_on_failure:` pros:**

- **Eliminates onion-peeling CI failures.** All failures visible on first run.
- **Extremely simple to implement.** Change `Enum.reduce_while` to `Enum.reduce` in the serial execution path when the flag is set.
- **Familiar semantics.** GitHub Actions has `continue-on-error: true` per step; this is the stage-level equivalent.
- **Additive.** Default is `false`, existing pipelines unchanged.

**`continue_on_failure:` cons:**

- **Semantically tricky with dependent steps.** If step A writes something to the store and step B reads it, and A fails, B may behave unexpectedly. Mitigation: document that `continue_on_failure:` is intended for independent steps (linters, checkers); not for steps with data dependencies.
- **Longer failure feedback when not wanted.** A deployment stage with `continue_on_failure:` would attempt all deploy steps even after one fails, potentially causing partial deploy state. Mitigation: the default is `false`; the flag is opt-in.

**Hardened parallel execution pros:**

- **Prevents executor corruption.** A crashing module step cannot take down the executor process.
- **Consistent failure semantics.** All parallel steps run to completion (or crash), same as serial with `continue_on_failure:`.
- **Zero API change.** Transparent to pipeline authors.

**Hardened parallel execution cons:**

- Slightly more complex parallel step collection code (`yield_many` vs `await_many`).
- A crashed step's output is a generic error message, not the actual exception traceback. Mitigation: capture the exception and its stacktrace in the `StepResult.output` field.

### 3.4 Developer Experience

**Serial stage with `continue_on_failure:`:**

```
  ✗ lint — failed (3.4s)
    ✗ format (0.2s)     ← all three ran
    ✗ credo (1.1s)      ← visible in one run
    ✓ dialyzer (2.1s)
```

vs current behavior:
```
  ✗ lint — failed (0.2s)
    ✗ format (0.2s)     ← halted here, credo never ran
```

**Dry run** shows the `continue_on_failure:` flag:

```
  ▶ :lint (serial, continue_on_failure)
    • :format — cmd: "mix format --check-formatted"
    • :credo  — cmd: "mix credo"
    • :dialyzer — cmd: "mix dialyzer"
```

---

## 4. How the Three Capabilities Fit Together

```
Pipeline runs
    │
    ├── EventLog (Capability 1)
    │     ├── ETS: live state for active run
    │     ├── Disk: ~/.tiny_ci/runs/<run_id>.jsonl
    │     ├── PubSub: web frontend, TUI
    │     └── Events include: TestFlakyRetried, TestQuarantined (Cap 2)
    │                         StepCompleted with all-steps data (Cap 3)
    │
    ├── Adaptive Test Isolation (Capability 2)
    │     ├── Uses EventLog to record per-test events
    │     └── Uses RunRegistry to look up flakiness history across runs
    │
    └── Fault-Tolerant Execution (Capability 3)
          └── Uses EventLog to record all step completions in continue_on_failure stages
```

Capability 1 is the infrastructure both Capabilities 2 and 3 rely on for observability. Capability 2 and 3 are independently useful and can be shipped before the web frontend is built — their events are emitted regardless of whether any subscriber is listening.

---

## 5. What We Are Explicitly Not Building

The GPT conversation contains several ideas this document intentionally excludes. These are recorded here so the decision is explicit:

### Deterministic Scheduling / Message-Level Replay

> *"Introduce a logical scheduler layer above BEAM that intercepts all messages and controls delivery order"*

This requires instrumenting BEAM's process scheduler at a level that tools like [Concuerror](https://github.com/parapluu/Concuerror) and [Mocking](https://github.com/Qqwy/elixir-mocking) have spent years on. It is research-grade work, not a product feature. The "replay" capability in §1.7 provides the useful form of replay (re-run with same declared inputs) without the VM-level complexity.

### Long-Lived Persistent Environments

> *"Maintain a long-lived environment across runs; apply migrations incrementally; track drift"*

This is an infrastructure management product (closer to Terraform + a deployment system). It is not CI. Building it would require TinyCI to own the lifecycle of external systems (databases, containers, services), which is a fundamentally different scope and responsibility.

### Distributed System Simulation / Chaos Testing Primitives

> *"`inject_failure :network_partition`, `explore concurrency: 100 do run_distributed_test() end`"*

This is a specialized testing tool for teams building distributed systems — a niche within a niche. [Jepsen](https://jepsen.io/) exists for this. If TinyCI's user base grows to include distributed-systems teams, these primitives could be a `TinyCI.Steps.Chaos` library. They should not be in the core runtime.

### Full OTP Supervision Strategies on Stages

Deferred until a distributed multi-node execution model exists, as described in §3.2.3.

---

## 6. Implementation Sequencing

```
Phase 1: EventLog infrastructure
├── TinyCI.Events (event structs)
├── TinyCI.RunRegistry (GenServer, ETS, disk sink)
├── TinyCI.EventLog (public API)
├── Emission points in Executor (run_pipeline, execute, step execution)
├── Emission in Output.collect_port (StepOutputLine)
├── mix tiny_ci.runs list/show/logs
└── Tests: assert events emitted, disk log written, subscriber receives events

Phase 2: Fault-Tolerant Execution
├── Add continue_on_failure: to Stage struct and DSL validator/interpreter
├── Modify serial execution path in Executor
├── Harden parallel Task collection (yield_many)
└── Tests: all steps run on failure, parallel crash handled gracefully

Phase 3: Adaptive Flaky Test Isolation
├── TinyCI.TestParser behaviour
├── TinyCI.TestParsers.ExUnit
├── Add test_runner:, flaky_retries:, quarantine_threshold: to Step struct
├── Modify step execution to invoke adaptive flow when test_runner: is set
├── Quarantine file read/write
├── New events: TestFlakyRetried, TestFlakyRecovered, TestQuarantined
└── Tests: parse ExUnit output, re-run failing tests, quarantine threshold behavior

Phase 4: Web/TUI (separate project)
└── Subscribe to EventLog PubSub; project run state; render
```

Each phase is independently releasable and independently useful. Phase 1 is the only blocking dependency.

---

## 7. Files Changed Per Phase

| Phase | New files | Modified files |
|-------|-----------|----------------|
| 1: EventLog | `lib/tiny_ci/events.ex`, `lib/tiny_ci/run_registry.ex`, `lib/tiny_ci/event_log.ex`, `lib/tiny_ci/run_projector.ex`, `lib/mix/tasks/tiny_ci.runs.ex` | `lib/tiny_ci/application.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/output.ex` |
| 2: Fault-Tolerant | — | `lib/tiny_ci/tiny_ci.ex` (Stage struct), `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/dry_run.ex` |
| 3: Adaptive Tests | `lib/tiny_ci/test_parser.ex`, `lib/tiny_ci/test_parsers/ex_unit.ex`, `lib/tiny_ci/flakiness_store.ex` | `lib/tiny_ci/tiny_ci.ex` (Step struct), `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/reporter.ex`, `lib/tiny_ci/dry_run.ex` |

---

## 8. Verification

| Capability | How to verify |
|------------|---------------|
| EventLog — events emitted | `mix test` with event subscriber assertions |
| EventLog — disk persistence | Assert `~/.tiny_ci/runs/<run_id>.jsonl` exists and parses after a run |
| EventLog — subscriber | Assert subscriber PID receives events during execution |
| `continue_on_failure:` | Lint stage with 3 failing steps all appear in results |
| Parallel crash hardening | Module step that raises still produces a StepResult, not an executor crash |
| Adaptive test isolation — parsing | Unit test ExUnit parser against fixture output strings |
| Adaptive test isolation — re-run | Integration test: inject a flaky ExUnit test, assert retry occurs |
| Adaptive test isolation — quarantine | After N failures, assert quarantine.json updated and step passes |
| All capabilities | `mix credo`, `mix format --check-formatted`, `mix compile --warnings-as-errors` |
