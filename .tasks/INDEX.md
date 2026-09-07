# tiny_ci — Task index

One file per unit of work, grouped by the milestones in [`ROADMAP.md`](../ROADMAP.md). Each task
is self-contained: an agent should be able to implement it from the file alone plus the code it
points at. Shared rules for *how* to work a task are in [`CONVENTIONS.md`](CONVENTIONS.md).

Legend: ⬜ not started · 🟡 in progress · ✅ done · ⏸️ blocked

Detail level: M0–M2 tasks are fully specified (design, TDD plan, acceptance). M3–M5 tasks are
specified to the design level and should be re-read against the code when their milestone
opens. M6–M7 tasks are carried over from the earlier plan and must be re-specified before
starting.

## M0 — Finish the fundamentals

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M0-01](M0-01-crash-isolation.md) | A crashing step is a failed step, not a crashed run | S | — | ⬜ |
| [M0-02](M0-02-remove-legacy-dsl.md) | Remove the macro DSL, old validator, scaffold files | S | — | ⬜ |
| [M0-03](M0-03-secrets-declaration-and-masking.md) | `secret` directive + masking in every sink and result | M | M0-01 | ⬜ |
| [M0-04](M0-04-cache-atomicity-locking-eviction.md) | Cache: atomic writes, cross-process lock, eviction | M | — | ⬜ |
| [M0-05](M0-05-changed-files-semantics.md) | `file_changed?` base ref + dirty tree; git runs in `root` | S–M | — | ⬜ |
| [M0-06](M0-06-run-persistence.md) | Persist every run; `runs` list/show; `Runs.Projection` | M | M0-03 | ⬜ |

## M1 — Standalone binary

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M1-01](M1-01-cli-entrypoint.md) | `TinyCI.CLI` entrypoint; Mix task becomes a wrapper | M | M0-06 | ⬜ |
| [M1-02](M1-02-run-outside-mix.md) | Run in a directory with no Mix project | S–M | M1-01 | ⬜ |
| [M1-03](M1-03-release-binary.md) | Burrito release, release workflow, install docs | M | M1-02 | ⬜ |

## M2 — The server

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M2-01](M2-01-run-process-model.md) | Run GenServer + DynamicSupervisor; cancel kills subtree; event bus | M–L | M0-01, M0-06 | ⬜ |
| [M2-02](M2-02-workspace-checkout.md) | Bare-mirror cache + worktree per run | M | — | ⬜ |
| [M2-03](M2-03-queue-and-scheduler.md) | Queue, concurrency cap, auto-cancel superseded runs | M | M2-01, M2-02 | ⬜ |
| [M2-04](M2-04-http-webhooks-and-polling.md) | HTTP layer, webhooks (GitHub/GitLab/Gitea), poller | M–L | M2-03 | ⬜ |
| [M2-05](M2-05-commit-status-reporting.md) | Commit status back to the forge | M | M2-04 | ⬜ |
| [M2-06](M2-06-secrets-store.md) | Encrypted secrets store | M | M0-03 | ⬜ |
| [M2-07](M2-07-serve-cli-config-api.md) | `tiny_ci serve`, config file, HTTP API, token auth, dogfood | M | M2-04, M2-05, M2-06, M1-01 | ⬜ |

## M3 — Live UI

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M3-01](M3-01-web-app-shell.md) | `tiny_ci_web` Phoenix app in the release; run list; PubSub bridge | L | M2-07 | ⬜ |
| [M3-02](M3-02-run-detail-view.md) | Run detail: DAG, streaming logs, store, matrix | L | M3-01 | ⬜ |
| [M3-03](M3-03-controls-and-auth.md) | Cancel / re-run / breakpoint controls; login | M | M3-02 | ⬜ |

## M4 — Distributed runners

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M4-01](M4-01-runner-node.md) | `tiny_ci runner --join`; labels; registration; liveness | M–L | M2-07 | ⬜ |
| [M4-02](M4-02-remote-stage-execution.md) | `runs_on:`; remote stage execution; events + control across nodes | L | M4-01 | ⬜ |
| [M4-03](M4-03-artifact-transfer.md) | Artifacts between nodes | M | M4-02 | ⬜ |
| [M4-04](M4-04-secure-transport.md) | TLS distribution; threat model; auth protocol (later) | M | M4-01 | ⬜ |

## M5 — Speed

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M5-01](M5-01-affected-stages.md) | `paths:` stage option; base ref from trigger | S–M | M0-05, M2-04 | ⬜ |
| [M5-02](M5-02-test-sharding.md) | `shards:` stage option | M | M4-02 | ⬜ |
| [M5-03](M5-03-flaky-test-quarantine.md) | Per-test records, targeted re-run, quarantine | L | M0-06, M3-02 | ⬜ |

## M6 — Debugging differentiators (re-specify before starting)

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M6-01](M6-01-shell-on-failure.md) | Shell on failure (CLI, then browser PTY) | L | M2-01 (CLI); M3-02 (web) | ⬜ |
| [M6-02](M6-02-conditional-breakpoints.md) | Conditional breakpoints | S–M | — | ⬜ |
| [M6-03](M6-03-replay-time-travel.md) | Replay / timeline scrubbing | M–L | M0-06, M3-02 | ⬜ |
| [M6-04](M6-04-dap-editor-debugging.md) | DAP server | L | M6-02 | ⬜ |

## M7 — Ecosystem

| ID | Task | Size | Depends on | Status |
|----|------|------|------------|--------|
| [M7-01](M7-01-import-github-actions.md) | `tiny_ci import` for GitHub Actions workflows | M | M1-01 | ⬜ |
| [M7-02](M7-02-supply-chain-in-ui.md) | Lockfile / attestation / registry in the UI | M | M3-02 | ⬜ |

## Done

Completed tasks from the earlier plan, kept for their design notes: [`done/`](done/).

| ID | Feature |
|----|---------|
| T01 | Structured run event stream (NDJSON) |
| T02 | Action contract |
| T03–T05 | LSP: diagnostics, completion/hover, navigation/flow |
| T06 | Hex action resolution + lockfile |
| T07 | Provenance / attestation |
| T08 | Sandboxed execution driver |
| T09 | Curated action registry |
| T10 | Execution control protocol (breakpoints) |
| T21 | Timeout kills the OS process subtree |

## Deferred

Kept under [`deferred/`](deferred/) and not scheduled. T12 is superseded by M3, T16 by M4;
T15, T17, and T19 are module-step debugging features nobody has asked for yet.
