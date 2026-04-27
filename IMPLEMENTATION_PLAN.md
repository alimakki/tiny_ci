# TinyCI — Implementation Plan

## Context

This plan breaks the capabilities described in DESIGN.md, the existing ROADMAP, and the strategic analysis into concrete, sequenced phases. Each phase is independently shippable and delivers standalone value. Phases 0–3 and 6 form the **open-source free tier**. Phases 4–5 are the **Pro tier** (web dashboard and flakiness analytics — first monetizable surface). Phases 7–8 are the **Enterprise tier** (self-hosted server, integrations, distributed execution).

The sequencing is driven by three rules:
1. Earlier phases unlock later ones (the event log in Phase 1 enables the web dashboard in Phase 4)
2. Trust-building comes first (correctness fixes before new features)
3. The monetization layer is added only once the free tier has demonstrated adoption

**File this plan creates:** `IMPLEMENTATION_PLAN.md` in the project root.

---

## Monetization Model

| Tier | Price | What's included |
|------|-------|----------------|
| **Open Source** | Free | CLI, event log, run history, fault-tolerant stages, caching, artifacts, watch mode, TUI |
| **Pro** | $29–49/mo per team | Web dashboard, live run view, flakiness analytics, search across history, team sharing |
| **Enterprise** | Custom | Self-hosted server, webhook triggers, GitHub/GitLab PR status checks, RBAC, SSO, S3 artifacts, distributed execution |

**Core principle:** the CLI and event log are always free. The web dashboard and collaboration features are the upsell. This mirrors the success of tools like Grafana (open core), Buildkite (hosted), and Nx Cloud (free local, paid cloud).

---

## Phase 0 — Core Quality

**Goal:** Establish the baseline correctness and scriptability that makes TinyCI trustworthy before any new capabilities are added. These are the "table stakes" that determine whether developers are willing to adopt it.

**Timeframe:** ~2 weeks

---

### T0.1 — Stage Filter (`--filter`)

**Goal:** Run a single named stage (or multiple) without editing the pipeline file. Essential for debugging individual stages locally.

**Acceptance criteria:**
- `mix tiny_ci.run --filter :test` runs only the `:test` stage
- `mix tiny_ci.run --filter :build,:test` runs both `:build` and `:test`
- Stages not in the filter list are silently skipped (not shown as skipped in output)
- Filter respects `needs:` — if `:test` needs `:build` and `:build` is filtered out, a warning is printed: `":test" needs ":build" which was filtered — running :test without it`
- `--dry-run --filter :deploy` shows only the filtered stages
- Invalid stage names in `--filter` print a clear error listing available stages

**Files:** `lib/mix/tasks/tiny_ci.run.ex`, `lib/tiny_ci/executor.ex`

---

### T0.2 — Structured Output (`--output json`)

**Goal:** Return machine-readable results on stdout, enabling shell scripts, git hooks, and CI integrations to consume TinyCI output programmatically. This is also the foundation the web dashboard uses to render completed runs.

**Acceptance criteria:**
- `mix tiny_ci.run --output json` prints a single JSON object to stdout on completion
- JSON structure mirrors `StageResult` tree: `{status, duration_ms, stages: [{name, status, duration_ms, steps: [...]}]}`
- Matrix stages include a `matrix_runs` array in their JSON representation
- `--output json` suppresses all ANSI/human-readable output (no mixing)
- `mix tiny_ci.run --output json | jq '.status'` returns `"passed"` or `"failed"`
- Exit code is still `0`/`1` regardless of `--output json`
- A new `TinyCI.Results` module handles serialization; no Jason dependency added to production deps until this task (add it in `mix.exs`)

**Files:** `lib/mix/tasks/tiny_ci.run.ex`, new `lib/tiny_ci/results.ex`, `mix.exs`

---

### T0.3 — Parallel Store Merge Determinism

**Goal:** Eliminate silent data races where two parallel steps writing the same store key produce an arbitrary winner, which can cause non-deterministic downstream behavior.

**Acceptance criteria:**
- When two parallel steps both return `{:ok, %{key: value}}` with the same key, the pipeline fails with: `"Parallel steps :step_a and :step_b both wrote store key :image_tag — use serial mode or distinct keys"`
- A `store_merge: :last_wins` option on a stage suppresses the error and uses the last-completed write (with a logged warning)
- Existing pipelines with no store conflicts are unaffected
- Tests cover: no conflict (pass), single conflict (fail), `store_merge: :last_wins` (pass with warning)

**Files:** `lib/tiny_ci/executor.ex`

---

### T0.4 — Secrets Management

**Goal:** Allow pipelines to declare named secrets sourced from environment variables or a local `.tiny_ci/secrets` file, with automatic value masking in all output. Without secrets, TinyCI cannot be used for real deployment pipelines.

**Acceptance criteria:**
- `secret "DATABASE_URL"` is valid DSL; value is read from `System.get_env/1` at pipeline start
- Missing secret at startup fails before any stage runs, listing all missing names: `"Pipeline requires secrets not found in environment: DATABASE_URL, AWS_KEY"`
- Secret values appearing in step stdout/stderr are replaced with `[MASKED]` in all output modes (streaming and buffered)
- `.tiny_ci/secrets` file (format: `KEY=value` per line, `#` comments ignored) is loaded automatically if present
- Secrets are never written to the pipeline store
- `--dry-run` lists declared secret names without values: `  secret DATABASE_URL (set)`/`(missing)`
- `secret` is added to the DSL allowlist validator
- `.tiny_ci/secrets` is added to `.gitignore` if not already present (logged, not automatic)

**Files:** `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`, `lib/tiny_ci/pipeline_spec.ex`, new `lib/tiny_ci/secrets.ex`, `lib/mix/tasks/tiny_ci.run.ex`, `lib/tiny_ci/dry_run.ex`, `lib/tiny_ci/output.ex`

---

## Phase 1 — Event-Sourced Execution Engine

**Goal:** Instrument the executor with an append-only event log that is the single source of truth for every pipeline run. All downstream consumers — the CLI run history, the web dashboard, the TUI — read from this log. No consumer touches the executor directly.

**Timeframe:** ~3–4 weeks  
**Tier:** Open Source (event log and CLI history are free)

---

### T1.1 — Event Structs

**Goal:** Define the complete typed event vocabulary as Elixir structs with `@enforce_keys` and `@type` specs. All other Phase 1 tasks depend on this.

**Acceptance criteria:**
- `lib/tiny_ci/events.ex` defines all event structs: `PipelineStarted`, `PipelineCompleted`, `StageStarted`, `StageSkipped`, `StageCompleted`, `StepStarted`, `StepSkipped`, `StepOutputLine`, `StepRetrying`, `StepCompleted`, `MatrixRunStarted`, `MatrixRunCompleted`, `HookStarted`, `HookCompleted`
- All structs include `run_id: String.t()` and `timestamp: DateTime.t()` fields
- All structs implement Jason.Encoder (or a custom `to_json/1` function) so they serialize to JSON cleanly
- `mix credo` and `mix compile --warnings-as-errors` pass

**Files:** new `lib/tiny_ci/events.ex`

---

### T1.2 — RunRegistry GenServer

**Goal:** A supervised GenServer that owns one ETS table per active run, handles disk persistence (`.jsonl` file per run), notifies subscribers, and garbage-collects completed run tables after a configurable TTL.

**Acceptance criteria:**
- `TinyCI.RunRegistry` starts under `TinyCI.Application` as a named GenServer
- `RunRegistry.start_run(run_id)` creates a new `:bag` ETS table named `:"tiny_ci_#{run_id}"`
- `RunRegistry.record(event)` inserts the event into the correct ETS table and appends a JSON line to `~/.tiny_ci/runs/<run_id>.jsonl` (creating the directory if it doesn't exist)
- `RunRegistry.subscribe(run_id, pid)` registers `pid` to receive `{:tiny_ci_event, event}` for each new event on that run
- ETS tables are scheduled for deletion 1 hour after `PipelineCompleted` is recorded
- On RunRegistry crash and restart, in-progress ETS tables are gone (acceptable — disk log is the durable record); a `RunRegistry.completed?(run_id)` check reads the disk log if ETS is absent
- Disk writes are async (the `record/1` call returns immediately; a cast handles the write)
- Tests cover: start_run, record, subscribe receives event, ETS cleanup after TTL

**Files:** `lib/tiny_ci/application.ex`, new `lib/tiny_ci/run_registry.ex`

---

### T1.3 — EventLog Public API

**Goal:** A clean, stable public API module that the executor (and all other TinyCI modules) calls. The API never exposes ETS or GenServer internals.

**Acceptance criteria:**
- `TinyCI.EventLog.emit(event)` — records the event; no-op if `run_id` is nil (backward compat for callers without a run context)
- `TinyCI.EventLog.get_events(run_id)` — returns all events for a run (ETS if active, disk if completed)
- `TinyCI.EventLog.stream_events(run_id)` — returns a lazy `Stream` of events from the disk log (for large runs)
- `TinyCI.EventLog.subscribe(run_id, pid)` / `unsubscribe(run_id, pid)` — live subscription
- `TinyCI.EventLog.list_runs()` — returns `[%{run_id, status, started_at, duration_ms}]` by scanning `~/.tiny_ci/runs/`
- All functions handle the "RunRegistry not running" case gracefully (return `[]` or `:ok` without crashing)

**Files:** new `lib/tiny_ci/event_log.ex`

---

### T1.4 — Executor Instrumentation

**Goal:** Add `EventLog.emit/1` calls at all natural boundaries in the executor. The executor's public API and return values are unchanged.

**Acceptance criteria:**
- `run_id` is generated at `run_pipeline/3` entry and stored in context: `ctx = Map.put_new(ctx, :run_id, generate_run_id(ctx))`; format: `"#{date}_#{time}_#{branch_slug}_#{commit_short}"`
- `PipelineStarted` emitted at `run_pipeline/3` entry
- `PipelineCompleted` emitted at `run_pipeline/3` return (both success and error paths)
- `StageStarted` emitted in `execute/3` before stage runs
- `StageSkipped` emitted in `execute/3` when `skip_stage?` is true (with correct `reason:`)
- `StageCompleted` emitted in `execute_regular_stage/3` after result is computed
- `MatrixRunStarted` / `MatrixRunCompleted` emitted around each combination in `execute_matrix_stage/3`
- `StepStarted` / `StepSkipped` / `StepRetrying` / `StepCompleted` emitted in step execution (wherever `run_step` or equivalent is called)
- `HookStarted` / `HookCompleted` emitted in `TinyCI.Hooks`
- All existing tests continue to pass (emission is a side effect; return values unchanged)
- New tests assert specific events are emitted for standard pipeline scenarios

**Files:** `lib/tiny_ci/executor.ex`, `lib/tiny_ci/hooks.ex`

---

### T1.5 — Output Instrumentation (`StepOutputLine`)

**Goal:** Emit one `StepOutputLine` event per line of step output in streaming mode. This makes step output searchable across runs and enables line-by-line streaming in the web dashboard.

**Acceptance criteria:**
- `Output.run_cmd/2` accepts a new `event_context: %{run_id, stage_name, step_name}` opt
- When `event_context` is present and output mode is `:streaming`, each line printed by `collect_port/4` also emits a `StepOutputLine` event
- When `event_context` is nil (or output mode is `:buffered`), no events are emitted (backward compatible)
- The executor passes `event_context` to `Output.run_cmd/2` for shell steps
- Tests: with event_context set, subscriber receives one `StepOutputLine` per output line; without event_context, no events emitted

**Files:** `lib/tiny_ci/output.ex`, `lib/tiny_ci/executor.ex`

---

### T1.6 — Run Projector

**Goal:** A pure function that rebuilds the logical state of a run from its event sequence. Used by the CLI history commands and by the web dashboard to render completed runs.

**Acceptance criteria:**
- `TinyCI.RunProjector.project(events)` takes a list of events and returns `%{run_id, status, started_at, finished_at, duration_ms, stages: %{atom => stage_state}}`
- Projecting the same event list always returns the same state (pure function, no side effects)
- Handles partial sequences (pipeline still running — `status: :running`, `finished_at: nil`)
- Handles all event types; unknown event types are ignored (forward compatibility)
- Round-trip test: run a pipeline, read its disk log, project it, assert it matches the `StageResult` list returned by the executor

**Files:** new `lib/tiny_ci/run_projector.ex`

---

### T1.7 — Run History CLI (`mix tiny_ci.runs`)

**Goal:** A new Mix task that exposes run history from the event log to the terminal. Operators can list, inspect, search, and replay past runs without a web UI.

**Acceptance criteria:**
- `mix tiny_ci.runs list` — prints last 20 runs: `run_id | branch | status | duration | timestamp`
- `mix tiny_ci.runs list --limit 50` — configurable limit
- `mix tiny_ci.runs show <run_id>` — prints the full stage/step summary (same format as `Reporter.print_summary/1`)
- `mix tiny_ci.runs logs <run_id> <stage> <step>` — prints captured output for a specific step
- `mix tiny_ci.runs replay <run_id> --stage :test --step :unit` — re-runs the named step using inputs captured in `StepStarted` event; emits events under a new `run_id` with `parent_run_id` metadata
- `mix tiny_ci.runs clean --older-than 30d` — deletes run log files older than N days
- All subcommands print `"No runs found"` gracefully if history directory is empty

**Files:** new `lib/mix/tasks/tiny_ci.runs.ex`

---

## Phase 2 — Fault-Tolerant Stage Execution

**Goal:** Add two targeted robustness improvements: a `continue_on_failure:` flag for serial stages (so all failures are visible on the first run rather than one-at-a-time), and hardened parallel execution that handles crashing Tasks gracefully.

**Timeframe:** ~1 week  
**Tier:** Open Source

---

### T2.1 — `continue_on_failure:` on Serial Stages

**Goal:** Eliminate the "onion-peel" CI failure experience where a serial lint stage stops on the first failure, requiring multiple reruns to see all failures.

**Acceptance criteria:**
- `stage :lint, mode: :serial, continue_on_failure: true do ... end` is valid DSL
- With `continue_on_failure: true`, all steps in the stage run regardless of prior failures
- Stage `status` is `:failed` if any step failed; all step results are present in `StageResult.step_results`
- Later steps in a `continue_on_failure:` stage receive the accumulated store from prior steps (including failed steps' partial store updates)
- Default is `false`; existing pipelines are unaffected
- `--dry-run` shows `(serial, continue_on_failure)` annotation on eligible stages
- Reporter shows all step results, not just those before the first failure
- `continue_on_failure:` on a `:parallel` stage is a validation error (it's meaningless — parallel stages already run all steps)

**Files:** `lib/tiny_ci/tiny_ci.ex`, `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/dry_run.ex`

---

### T2.2 — Hardened Parallel Task Execution

**Goal:** Prevent an uncaught exception in a module step Task from propagating to `Task.await_many/2` and crashing the executor. All parallel steps should produce a `StepResult` — even if they crash.

**Acceptance criteria:**
- Replace `Task.await_many/2` in the parallel step execution path with `Task.yield_many/2`
- A Task that exits abnormally (raises an exception) produces `%StepResult{status: :failed, output: "Step crashed: #{inspect(reason)}\n#{format_stacktrace(reason)}"}` 
- A Task that times out (if a timeout is set) produces `%StepResult{status: :failed, output: "Step timed out after #{timeout}ms"}`
- The stage continues collecting all step results after a crash — it does not re-raise
- Existing behavior for steps that return normally is unchanged
- Test: a module step that raises `RuntimeError` produces a failed StepResult without crashing the executor

**Files:** `lib/tiny_ci/executor.ex`

---

## Phase 3 — Platform Completeness

**Goal:** Implement the remaining ROADMAP capabilities (dependency caching, artifact persistence, watch mode) and two new features (pipeline includes, richer conditions) that bring TinyCI to parity with the features developers expect from a CI tool before recommending it to others.

**Timeframe:** ~4–5 weeks  
**Tier:** Open Source

---

### T3.1 — Dependency Caching

**Goal:** Skip expensive dependency-install steps when nothing has changed, using a file hash as the cache key.

**Acceptance criteria:**
- `cache paths: ["deps", "_build"], key: "mix.lock"` is valid DSL on a step
- Cache key is the SHA256 of the named file's contents at pipeline start
- Cache hit: target directories are restored from `~/.cache/tiny_ci/<project>/<key>/`; step is skipped; reporter shows `[cache hit]`
- Cache miss: step runs normally; output directories are archived to the cache afterward; reporter shows `[cache miss]`
- `mix tiny_ci.run --no-cache` bypasses all cache lookups for the run
- `mix tiny_ci.cache clean` deletes all cache entries for the current project
- `mix tiny_ci.cache clean --all` deletes the entire `~/.cache/tiny_ci/` directory
- `--dry-run` shows cache directive with resolved key hash and hit/miss status
- Validator allowlists `cache` as a DSL construct

**Files:** `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`, new `lib/tiny_ci/cache.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/dry_run.ex`, `lib/tiny_ci/reporter.ex`, new `lib/mix/tasks/tiny_ci.cache.ex`

---

### T3.2 — Artifact Persistence

**Goal:** Allow stages to declare build outputs that are stored per-run and can be referenced by downstream stages, enabling multi-stage pipelines that produce and consume binaries.

**Acceptance criteria:**
- `artifact "build", paths: ["_build/prod/rel"]` is valid DSL on a step or stage
- Artifacts are copied to `~/.tiny_ci/artifacts/<run_id>/<name>/` after the declaring step/stage completes
- Downstream steps access artifact path via `store(:artifact_build_path)` (injected automatically)
- Missing path with `required: true` fails the step; without `required:` emits a warning and continues
- `mix tiny_ci.run --artifacts-dir /tmp/my-artifacts` overrides the default storage location
- `mix tiny_ci.run --list-artifacts` prints artifacts from the most recent run
- `--dry-run` shows artifact declarations and their resolved storage paths
- Validator allowlists `artifact` as a DSL construct

**Files:** `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`, new `lib/tiny_ci/artifacts.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/dry_run.ex`, `lib/mix/tasks/tiny_ci.run.ex`

---

### T3.3 — Watch Mode

**Goal:** Re-run the pipeline automatically when project files change, providing continuous feedback during development without manual re-triggers.

**Acceptance criteria:**
- `mix tiny_ci.run --watch` runs the pipeline once, then watches for file changes and re-runs
- On file change, any in-progress run is terminated cleanly before the new run starts
- `--watch-paths "lib/**/*.ex,test/**/*.exs"` restricts which paths trigger a re-run (glob patterns, same syntax as `file_changed?/1`)
- `--watch-debounce 500` sets the debounce window in milliseconds (default: 500ms)
- `--watch-clear` clears the terminal between runs
- `Ctrl+C` exits watch mode cleanly with exit code 0
- Compatible with `--filter` (watch + filter runs only the specified stages on change)
- Uses `FileSystem` hex package (or `:fs` BEAM library) for cross-platform file watching

**Files:** `lib/mix/tasks/tiny_ci.run.ex`, new `lib/tiny_ci/watcher.ex`, `mix.exs`

---

### T3.4 — Pipeline Includes / Composition

**Goal:** Allow pipeline files to include shared stage definitions from other files, eliminating duplication across pipelines in a multi-pipeline project.

**Acceptance criteria:**
- `include ".tiny_ci/shared/common.exs"` is valid DSL at the top level of a pipeline file
- Included files are parsed and validated with the same allowlist as the parent file
- Stages and env directives from the included file are merged into the parent pipeline (included stages appear first)
- Circular includes produce a parse error: `"Circular include detected: a.exs → b.exs → a.exs"`
- Relative paths in `include` are resolved relative to the including file's directory
- `--dry-run` shows which stages came from included files with a `[from: shared/common.exs]` annotation
- Validator allowlists `include` as a DSL construct
- The allowlist validator runs on included files as well (no escaping the sandbox via includes)

**Files:** `lib/tiny_ci/dsl/interpreter.ex`, `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dry_run.ex`

---

### T3.5 — Richer Conditions

**Goal:** Expand the condition expression language to support the most common CI conditional patterns that `branch()`, `env()`, and `file_changed?()` cannot express.

**New primitives:**

| Expression | Description |
|------------|-------------|
| `tag()` | Current git tag, or `nil` if HEAD is not tagged |
| `tag() =~ "v*"` | Matches tags by glob pattern |
| `commit_message()` | Full commit message string |
| `commit_message() =~ "skip ci"` | String match on commit message |
| `changed_in?("lib/")` | `true` if any file under the given directory changed |
| `pipeline_name()` | Atom name of the current pipeline |

**Acceptance criteria:**
- All six new primitives are valid in `:when` expressions on stages and steps
- Each is evaluated at runtime from the pipeline context (not at parse time)
- `tag()` returns `nil` when HEAD is not tagged (does not raise)
- `commit_message() =~ "skip ci"` uses `String.contains?/2` semantics (substring match)
- `changed_in?("lib/")` is equivalent to `file_changed?("lib/**")` but with directory shorthand
- All new primitives are allowlisted in the DSL validator
- `--dry-run` evaluates new primitives against the current context and shows expected skip/run decisions
- Conditions referencing `tag()` on a commit with no tag evaluate to `nil` (falsy — stage skips)

**Files:** `lib/tiny_ci/dsl/condition_eval.ex`, `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/context.ex`

---

## Phase 4 — Web Dashboard (Pro Tier)

**Goal:** A Phoenix LiveView web application that subscribes to the event log and renders pipeline runs in real time — the first monetizable surface. This ships as a **separate application** that depends on `tiny_ci` as a library, keeping the CLI lean and Phoenix out of the core dependency tree.

**Timeframe:** ~6–8 weeks  
**Tier:** Pro ($29–49/month per team)

---

### T4.1 — Phoenix App Scaffold + EventLog Integration

**Goal:** Bootstrap the web application with routing, layout, and a working EventLog subscription — the plumbing everything else builds on.

**Acceptance criteria:**
- New umbrella project `tiny_ci_web` or standalone `tiny_ci_dashboard` Phoenix app in a sibling repository
- `tiny_ci` is a path dependency in `mix.exs`: `{:tiny_ci, path: "../tiny_ci"}`
- `TinyCI.EventLog.subscribe(run_id, self())` works from within a LiveView process
- A `TinyCI.Dashboard.EventHandler` module handles incoming `{:tiny_ci_event, event}` messages and updates LiveView assigns
- `mix phx.server` starts the dashboard; navigating to `http://localhost:4000` renders a page (even if empty)
- Health check endpoint at `GET /healthz` returns `200 OK`

**Files:** new `tiny_ci_dashboard/` Phoenix project

---

### T4.2 — Run List View

**Goal:** A landing page showing the history of all pipeline runs, sortable and filterable.

**Acceptance criteria:**
- `GET /` renders a table: run_id, pipeline name, branch, status (colored), duration, timestamp
- Runs are sorted by timestamp descending (most recent first)
- Status filter: All / Passed / Failed
- Branch filter: free-text input, filters by branch name prefix
- Pagination: 20 runs per page with next/previous
- Each row links to the run detail page
- Actively running pipelines appear at the top with a live-updating elapsed time and a spinner
- Empty state: "No runs yet. Run `mix tiny_ci.run` in your project to see results here."

---

### T4.3 — Run Detail View

**Goal:** A structured, tree-format view of a single completed or running pipeline.

**Acceptance criteria:**
- `GET /runs/:run_id` renders the stage/step tree for that run
- Layout mirrors `Reporter.print_summary/1` but in HTML: stage rows with step sub-rows
- Status icons use colored SVGs (✓ green / ✗ red / ○ yellow) matching the CLI
- Duration displayed for each stage and step
- Matrix stages show combinations as sub-rows
- A "View Logs" button per step links to the step output view (T4.5)
- "Re-run" button triggers `EventLog`-based replay for the selected stage/step (requires T1.7)
- If the run is still active, the page transitions to live mode automatically (T4.4)

---

### T4.4 — Live Run View

**Goal:** Real-time updating of a run in progress, without polling. This is the "CI as a live system" differentiator from the GPT conversation.

**Acceptance criteria:**
- When viewing a run that is not yet `PipelineCompleted`, the page subscribes to `EventLog.subscribe(run_id, self())`
- Each new event updates the relevant assign and triggers a targeted LiveView patch (not a full re-render)
- `StageStarted` — stage row appears with `:running` status and elapsed timer
- `StepStarted` — step row appears under its stage with `:running` indicator
- `StepOutputLine` — a collapsible log section under the step shows lines appending in real time
- `StepCompleted` — step row updates to final status and duration
- `PipelineCompleted` — page transitions to static state; subscription is cleaned up
- No polling; no page refreshes; all updates via WebSocket push
- Works across browser tabs (multiple subscribers to the same run_id)

---

### T4.5 — Step Output Viewer

**Goal:** Full output log for any step in any run, with search.

**Acceptance criteria:**
- `GET /runs/:run_id/stages/:stage/steps/:step/logs` renders the full captured output
- For streaming-mode steps (with `StepOutputLine` events): renders line-by-line with timestamps
- For buffered-mode steps (output stored in `StepResult.output`): renders full output block
- Text search: a filter input highlights matching lines (client-side, no server round-trip for small outputs)
- "Jump to first error" button scrolls to the first line matching common error patterns
- Output is monospace, dark background, line numbers
- Long outputs (>10,000 lines) render in a virtual scroll container (no DOM overload)

---

### T4.6 — Authentication and Team Accounts

**Goal:** Basic multi-user access control so teams can share a dashboard instance without exposing it to the open internet. This is the minimum viable paywall for the Pro tier.

**Acceptance criteria:**
- Email/password authentication via `phx_gen_auth` or equivalent
- Invite-based team creation: owner creates a team, invites members by email
- All runs visible to all team members (no per-pipeline RBAC at this tier — that's Enterprise)
- Magic link (passwordless) login as an option
- Session tokens expire after 30 days of inactivity
- `GET /` redirects to login if unauthenticated
- A `FREE_MODE=true` environment variable disables auth entirely (for local/personal use)

---

## Phase 5 — Adaptive Flaky Test Isolation

**Goal:** Implement per-test retry and quarantine for ExUnit, exposing individual test failure data rather than failing the whole step. The quarantine analytics become a Pro-tier feature in the web dashboard.

**Timeframe:** ~2–3 weeks  
**Tier:** Core feature is Open Source; flakiness analytics dashboard is Pro

---

### T5.1 — TestParser Behaviour and ExUnit Implementation

**Goal:** Define the pluggable parser interface and implement it for ExUnit.

**Acceptance criteria:**
- `TinyCI.TestParser` behaviour defines: `parse_failures(output :: String.t()) :: [test_id()]` and `build_rerun_cmd(base_cmd :: String.t(), test_ids :: [test_id()]) :: String.t()`
- `test_id()` type: `%{file: String.t(), line: pos_integer(), name: String.t()}`
- `TinyCI.TestParsers.ExUnit` implements the behaviour
- `parse_failures/1` correctly extracts `{file, line}` pairs from standard ExUnit failure output
- `build_rerun_cmd/2` returns `"mix test test/foo_test.exs:42 test/bar_test.exs:88"` format
- Unit tests cover: no failures (empty list), single failure, multiple failures, ExUnit format variations
- Parsers are registered in `TinyCI.TestParsers` module as `%{ex_unit: TinyCI.TestParsers.ExUnit}`

**Files:** new `lib/tiny_ci/test_parser.ex`, new `lib/tiny_ci/test_parsers/ex_unit.ex`

---

### T5.2 — Flakiness Tracking Store

**Goal:** Persist per-test pass/fail history to a JSON file so quarantine decisions are based on actual history, not single-run outcomes.

**Acceptance criteria:**
- `TinyCI.FlakinessStore` reads/writes `.tiny_ci/quarantine.json` (path configurable)
- File format: `{test_id_string => {name, failures, passes, last_failed, quarantined}}`
- `FlakinessStore.record_failure(test_id)` increments failure count and updates `last_failed`
- `FlakinessStore.record_pass(test_id)` increments pass count
- `FlakinessStore.quarantine?(test_id, threshold)` returns true if `failures >= threshold`
- `FlakinessStore.quarantine!(test_id)` sets `quarantined: true`
- File is created on first write; missing file is treated as empty (not an error)
- JSON reads/writes are atomic (write to temp file, rename)
- Tests cover: first failure, repeated failures reaching threshold, quarantine flag set

**Files:** new `lib/tiny_ci/flakiness_store.ex`

---

### T5.3 — Adaptive Step Execution Flow

**Goal:** Wire up the parser and flakiness store into the step execution path so that failing steps with `test_runner:` set trigger per-test retry instead of failing immediately.

**Acceptance criteria:**
- `step :unit, cmd: "mix test", test_runner: :ex_unit, flaky_retries: 2` is valid DSL
- When the step exits non-zero and `test_runner:` is set: parse failures, retry each individually
- If all per-test retries pass: step result is `:passed`; `TestFlakyRecovered` events emitted per test
- If any test still fails after `flaky_retries` attempts: step result is `:failed`
- Each individual test retry runs in its own Task (parallel by default, bounded by `max_parallel:` if set on the stage)
- `flaky_retries:` defaults to 1 if `test_runner:` is set but `flaky_retries:` is not
- If no failing tests can be parsed from output (unexpected output format), falls back to normal step retry behavior

**Files:** `lib/tiny_ci/executor.ex`, `lib/tiny_ci/tiny_ci.ex`, `lib/tiny_ci/dsl/validator.ex`, `lib/tiny_ci/dsl/interpreter.ex`

---

### T5.4 — Quarantine Mechanics

**Goal:** Automatically quarantine persistently flaky tests so the pipeline passes while clearly flagging the technical debt.

**Acceptance criteria:**
- `quarantine_threshold: 3` on a step: after 3 failures recorded in FlakinessStore, test is quarantined
- Quarantined test: step passes, but `TestQuarantined` event is emitted and reporter shows warning
- `quarantine_path: ".tiny_ci/quarantine.json"` overrides the default path (opt-in to custom location)
- Quarantine entries older than 30 days without a failure emit a reporter warning: `":auth_test.exs:42 has been quarantined for 31 days — consider removing or fixing"`
- `mix tiny_ci.runs quarantine list` shows all quarantined tests across all tracked pipelines
- `mix tiny_ci.runs quarantine clear test/foo_test.exs:42` removes a specific entry

**Files:** `lib/tiny_ci/flakiness_store.ex`, `lib/tiny_ci/executor.ex`, `lib/tiny_ci/reporter.ex`, `lib/mix/tasks/tiny_ci.runs.ex`

---

### T5.5 — Reporter and Dry-Run Integration

**Goal:** Make flaky test outcomes visible in the terminal reporter and dry-run output without cluttering normal runs.

**Acceptance criteria:**
- Reporter shows flaky recovery inline:
  ```
    ✓ test — passed (12.3s)
      ○ unit — flaky recovery: 2 tests retried, all passed on attempt 2
  ```
- Reporter shows quarantined tests:
  ```
    ✓ test — passed with warnings (12.3s)
      ⚠ unit — 1 test quarantined (not blocking pipeline)
        ○ test/auth_test.exs:42 [QUARANTINED] — failed 3 times
  ```
- Step fails normally (no quarantine warning) when retries are exhausted and threshold not yet reached
- `--dry-run` shows quarantine status per step:
  ```
    • :unit — cmd: "mix test" [test_runner: ex_unit, flaky_retries: 2]
      Quarantined tests (1): test/auth_test.exs:42 (quarantined 5 days ago)
  ```

**Files:** `lib/tiny_ci/reporter.ex`, `lib/tiny_ci/dry_run.ex`

---

## Phase 6 — TUI (Terminal UI)

**Goal:** A rich terminal interface built on [Ratatouille](https://github.com/ndreynolds/ratatouille) that provides live updating pipeline visualization, run history browsing, and an interactive dry-run navigator — entirely in the terminal for developers who prefer not to open a browser.

**Timeframe:** ~2–3 weeks  
**Tier:** Open Source (TUI is free; web dashboard is Pro)

---

### T6.1 — TUI Scaffold

**Goal:** Bootstrap the Ratatouille application with a working event loop that subscribes to EventLog.

**Acceptance criteria:**
- `mix tiny_ci.run --tui` launches the TUI instead of the plain reporter
- TUI starts, renders a header with pipeline name and run_id, and exits cleanly on `q` or `Ctrl+C`
- EventLog subscription established at startup; incoming events trigger re-renders
- `ratatouille` added to `mix.exs` deps (dev/optional, not required for headless/CI use)
- Graceful degradation: if terminal is not a TTY or doesn't support required escape codes, falls back to plain reporter with a warning

**Files:** new `lib/tiny_ci/tui/app.ex`, new `lib/tiny_ci/tui/renderer.ex`, `mix.exs`

---

### T6.2 — Live Run View

**Goal:** A live-updating stage/step tree that mirrors the web dashboard's run detail view, entirely in the terminal.

**Acceptance criteria:**
- Stages appear as rows when `StageStarted` is received; steps appear as indented sub-rows
- Running stages/steps show an elapsed timer that ticks every second
- Completed stages/steps show final status icon and duration
- Matrix stages show combination sub-rows
- Step output is shown in a collapsible panel below each step (toggle with `Enter` or `o`)
- The view auto-scrolls to the currently running stage; `↑/↓` arrows let the user scroll manually
- On `PipelineCompleted`, the view freezes and shows the final summary; press `q` to exit

---

### T6.3 — Run History Browser

**Goal:** An interactive run history browser that lets developers navigate past runs without leaving the terminal.

**Acceptance criteria:**
- `mix tiny_ci.tui` (no `--run` flag) opens the history browser instead of waiting for a run
- Displays the same run list as `mix tiny_ci.runs list` but navigable with arrow keys
- `Enter` on a run opens the detail view for that run (rendered from disk log via RunProjector)
- `r` on a run opens the replay prompt: "Replay stage? (all / :test / :deploy)"
- `d` deletes the selected run log after a confirmation prompt
- `?` shows keybinding help overlay

---

### T6.4 — Interactive Dry-Run Navigator

**Goal:** Replace the static `--dry-run` text output with an interactive preview that lets developers explore the execution plan.

**Acceptance criteria:**
- `mix tiny_ci.run --dry-run --tui` opens the interactive dry-run navigator
- Renders the DAG level structure as a collapsible tree
- Conditions evaluated against current context shown inline: `when: branch() == "main" → false (current: feature/x)`
- `Enter` on a stage expands/collapses its step list
- `e` on a stage or step opens a read-only view of its definition
- `m` on a matrix stage shows the full combinations table
- Exit with `q`; pressing `r` closes the TUI and starts the actual run

---

## Phase 7 — Enterprise Server Mode

**Goal:** Transform TinyCI from a local CLI tool into a self-hosted CI server that responds to git push events, posts PR status checks, manages users, and integrates with enterprise identity systems.

**Timeframe:** ~8–10 weeks  
**Tier:** Enterprise (custom pricing)

---

### T7.1 — Server Mode (`mix tiny_ci.server`)

**Goal:** A long-running HTTP + WebSocket server that accepts pipeline runs via API and serves the web dashboard.

**Acceptance criteria:**
- `mix tiny_ci.server` starts the Phoenix endpoint on a configurable port (default 4000)
- Server mode integrates the web dashboard (Phase 4) as its UI
- `POST /api/runs` with a JSON body `{pipeline, branch, commit}` triggers a pipeline run and returns `{run_id}`
- `GET /api/runs/:run_id` returns the projected run state as JSON
- `GET /api/runs/:run_id/events` returns a Server-Sent Events stream for live consumption
- Server-mode runs are queued (configurable concurrency: `--max-concurrent-runs 4`)
- `GET /api/health` returns `{status: "ok", version: "x.y.z", queued_runs: N, active_runs: N}`

---

### T7.2 — Webhook Receiver (Git Push Triggers)

**Goal:** Automatically trigger pipeline runs when code is pushed to a connected repository.

**Acceptance criteria:**
- `POST /webhooks/github` handles GitHub push event payloads (validates `X-Hub-Signature-256`)
- `POST /webhooks/gitlab` handles GitLab push event payloads (validates `X-Gitlab-Token`)
- Webhook payload is parsed to extract branch, commit SHA, and changed files
- These values populate the pipeline context so `branch()`, `commit_message()`, and `file_changed?()` work as in local runs
- Webhook secrets are configured via environment variables (`GITHUB_WEBHOOK_SECRET`, `GITLAB_WEBHOOK_TOKEN`)
- Failed signature validation returns `403` without triggering a run
- Each push event is idempotent: if a run for the same commit already exists, return it without creating a duplicate

---

### T7.3 — GitHub / GitLab PR Status Checks

**Goal:** Post build status back to GitHub/GitLab PRs so CI results appear inline in the pull request UI.

**Acceptance criteria:**
- Configurable GitHub App installation or personal access token (`GITHUB_TOKEN`)
- On `PipelineCompleted`, post a commit status check to GitHub: `{state: "success"|"failure", context: "tiny_ci", description: "Pipeline passed in 42s", target_url: "https://my-ci.example.com/runs/<run_id>"}`
- GitLab equivalent via GitLab commit status API
- Status is posted for: all runs triggered by webhook; optionally for manually triggered runs (`--post-status` flag)
- If the API call fails, log the error but do not fail the pipeline
- `--dry-run` with `--post-status` shows what would be posted without making the API call

---

### T7.4 — Role-Based Access Control (RBAC)

**Goal:** Fine-grained permissions for team environments where different users should have different levels of access.

**Acceptance criteria:**
- Roles: `owner`, `admin`, `member`, `viewer`
- `viewer`: read-only access to run history and logs
- `member`: can trigger runs; cannot manage team settings
- `admin`: can invite/remove members; can manage pipeline configuration
- `owner`: full access including billing
- Pipeline-level access control: pipelines can be restricted to specific roles
- API tokens support role scoping: `POST /api/tokens` with `{role: "member"}` creates a scoped token
- Role changes take effect immediately (no re-login required)

---

### T7.5 — Audit Logs

**Goal:** A tamper-evident record of all security-relevant actions for compliance requirements.

**Acceptance criteria:**
- All authentication events (login, logout, token creation/revocation) are logged
- All pipeline trigger events (who triggered, from where, which pipeline) are logged
- All admin actions (invite, role change, config change) are logged
- Audit log is append-only (no delete API, not exposed in the UI for modification)
- `GET /api/audit_log` returns paginated log entries (admin/owner only)
- Log entries are signed with an HMAC to detect tampering
- Log can be streamed to an external SIEM via a configurable webhook

---

### T7.6 — SSO Integration (SAML / OIDC)

**Goal:** Allow enterprise customers to authenticate with their existing identity provider (Okta, Azure AD, Google Workspace).

**Acceptance criteria:**
- OIDC provider configuration via environment variables: `OIDC_ISSUER`, `OIDC_CLIENT_ID`, `OIDC_CLIENT_SECRET`
- SAML 2.0 SP-initiated SSO with configurable IdP metadata URL
- JIT (Just-in-Time) user provisioning: users are created on first SSO login with the `member` role
- SCIM 2.0 user provisioning endpoint for automatic deprovisioning when employees leave
- SSO can coexist with email/password auth; `REQUIRE_SSO=true` env var disables email/password entirely
- Login page shows "Sign in with [Provider]" button when SSO is configured

---

### T7.7 — Cloud Artifact Storage

**Goal:** Store artifacts in S3 or GCS instead of local disk, enabling artifact sharing across machines and long-term artifact retention.

**Acceptance criteria:**
- `ARTIFACT_BACKEND=s3` with `AWS_BUCKET`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` configures S3
- `ARTIFACT_BACKEND=gcs` with `GCS_BUCKET`, `GCS_CREDENTIALS_JSON` configures GCS
- Artifact upload/download is transparent to pipeline authors; same DSL as local artifacts (T3.2)
- Pre-signed download URLs are generated for artifact references in the web dashboard
- Artifact retention policy: `ARTIFACT_TTL_DAYS=90` auto-deletes old artifacts
- Falls back to local disk if no backend is configured (backward compatible)

---

## Phase 8 — Distributed Execution

**Goal:** Enable TinyCI to distribute pipeline stages across multiple worker agents, allowing large pipelines to parallelize across machines.

**Timeframe:** ~3 months  
**Tier:** Enterprise

---

### T8.1 — Worker Agent

**Goal:** A lightweight TinyCI agent that registers with the server, receives stage assignments, and executes them locally.

**Acceptance criteria:**
- `mix tiny_ci.agent --server https://my-ci.example.com --token <agent_token>` starts an agent
- Agent registers with the server via `POST /api/agents`
- Agent sends heartbeats every 30 seconds; server marks agent as offline after 3 missed heartbeats
- Agent receives stage assignments via long-polling or WebSocket
- Agent streams `StepOutputLine` events back to the server in real time
- Agent can be tagged: `--tags "os=ubuntu,arch=arm64"` — pipeline stages can specify required tags
- Agent gracefully completes in-flight stages before shutdown on `SIGTERM`

---

### T8.2 — Distributed Stage Scheduling

**Goal:** The server scheduler assigns DAG stages to available agents based on tags and availability, rather than running everything on the server itself.

**Acceptance criteria:**
- Stages with no `agent_tags:` run on any available agent
- `stage :deploy, agent_tags: [os: "ubuntu"]` is routed only to agents with matching tags
- If no matching agent is available, the stage queues until one becomes available (configurable timeout)
- Stage-level parallelism (from DAG levels) is preserved: independent stages at the same level run on different agents simultaneously
- The web dashboard shows which agent each stage ran on
- Agent failure mid-stage: stage is marked as failed; manual retry is available

---

## Summary: Tier Boundaries

```
Open Source (Phases 0–3, 6)
├── Core CLI execution engine
├── Event log + run history CLI
├── Fault-tolerant stages (continue_on_failure)
├── Secrets, caching, artifacts
├── Watch mode, includes, richer conditions
├── Adaptive flaky test isolation (ExUnit)
└── TUI

Pro — $29–49/month per team (Phases 4–5)
├── Web dashboard (run list, detail, live view)
├── Step output viewer with search
├── Flakiness analytics dashboard
└── Team accounts + basic auth

Enterprise — Custom pricing (Phases 7–8)
├── Self-hosted server mode
├── Webhook triggers (GitHub, GitLab)
├── PR status checks
├── RBAC + audit logs + SSO
├── Cloud artifact storage (S3/GCS)
└── Distributed execution across agents
```
