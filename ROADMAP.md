# tiny_ci Roadmap

**This is the only roadmap.** Per-task implementation plans live in [`.tasks/`](.tasks/INDEX.md).
Older planning documents are archived under [`docs/archive/`](docs/archive/) and are referenced
from tasks where their design still applies. The README's feature list describes what exists;
this file describes where the project is going and in what order.

Last rewritten: 2026-09-07.

---

## Positioning

> One binary that is your CI server, runner, and UI. The pipeline you run on your laptop is the
> same one the server runs. No YAML, no Kubernetes, no Redis, no Postgres.

tiny_ci is a replacement for a traditional CI stack, not a task runner and not a plugin for
someone else's CI. It is written in Elixir because the BEAM already provides the primitives a CI
system otherwise has to assemble from Redis, a job queue, a worker fleet, and a web tier:

| CI concern | Traditional stack | BEAM |
|---|---|---|
| A run in flight | a job row + a worker container | one supervised process tree |
| Cancel / timeout / crash isolation | orchestrator polls, kills containers | kill the process tree; supervisors report the outcome |
| Runner fleet and liveness | agent daemon + heartbeat table + broker | distributed nodes, `Node.monitor/1`, no broker |
| Live logs and UI updates | log shipper + websocket service | one event stream, PubSub, LiveView |
| Many concurrent runs per host | one container per job | thousands of cheap processes |

Where the BEAM does **not** help, we say so: hot code upgrades are irrelevant to CI, distributed
Erlang is not safe over untrusted networks (see M4), and the OS is still the security boundary
for third-party code.

## The pain points we are solving

Every milestone below is justified by at least one row of this table.

| Pain in existing CI stacks | tiny_ci answer | Milestone |
|---|---|---|
| YAML with no validation; the only way to test a pipeline is to push it | Interpreted, allowlisted DSL; LSP; `--dry-run`; an identical local run | done |
| Debugging a failure means re-pushing or a tmate hack | Breakpoints, shell-on-failure, replay | done / M6 |
| Secrets end up in logs | Masking at the event boundary; every sink inherits it | M0 |
| A crashing step takes the whole job down with an opaque error | A crashing step is a failed step with a message | M0 |
| Self-hosting means operating Jenkins or a Kubernetes runner fleet | A single release binary; add a node to scale | M1, M2, M4 |
| "It only runs in CI" — no local parity | The server runs the very same runner the laptop does | M2 |
| A new push wastes minutes finishing a superseded run | Per-branch auto-cancel; cancel is killing a process tree | M2 |
| No structured history; logs are the only record | Every run is a persisted event log; the UI is a fold over it | M0, M3 |
| Cold containers, queue wait | Long-lived warm runners with the cache already on disk | M4, M5 |
| A monorepo push rebuilds everything | Affected-stage execution from the git diff | M5 |
| Retries at whole-job granularity; flaky tests block merges | Per-test re-run and quarantine | M5 |
| Zombie jobs when a runner dies | Node monitoring surfaces a lost runner in seconds | M4 |
| Pinned third-party actions, provenance | Lockfile, attestation, registry | done / M7 |

## Principles

1. **Adoption gates, not feature lists.** Each milestone ends with something a team can now do.
   Nothing in a later milestone starts until the gate is met.
2. **The library stays lean; the binary is the product.** `tiny_ci` (the Mix project at the root)
   depends on `jason` and nothing else at runtime. The server and UI live in sibling Mix projects
   that depend on core, and the *release* bundles all of them. This revises the earlier rule that
   the web UI must never ship with core: it never ships *in* core, but it does ship in the binary.
3. **Everything observable flows through the event stream.** No feature reaches into executor
   internals to observe a run. The UI, replay, provenance, and the runner protocol all consume
   events. Run history is the persisted stream, and any view of a run is a fold over it.
4. **The DSL allowlist is the security boundary for pipeline files.** New directives are added to
   `TinyCI.DSL.Spec` and `TinyCI.DSL.Validator` together, and rejected when misused.
5. **Never run untrusted code unsandboxed.** Third-party actions go through the sandbox driver.
6. **Honesty about determinism.** Replay reconstructs the data layer; it cannot undo side effects.
   A hand-steered run is divergent and not attestable.
7. **Shell steps are first-class.** A Go or JavaScript team must be able to use tiny_ci without
   writing Elixir. Module steps are an Elixir-project bonus.

## Milestones

Status legend: ⬜ not started · 🟡 in progress · ✅ done

### M0 — Finish the fundamentals ⬜

The remaining correctness and safety gaps in the runner. All small, all blocking.

| Task | Item |
|---|---|
| [M0-01](.tasks/M0-01-crash-isolation.md) | A raising or exiting step is a *failed step*, never a crashed run |
| [M0-02](.tasks/M0-02-remove-legacy-dsl.md) | Delete the macro DSL, the old validator, and scaffold leftovers |
| [M0-03](.tasks/M0-03-secrets-declaration-and-masking.md) | `secret` directive; values masked in every sink and result |
| [M0-04](.tasks/M0-04-cache-atomicity-locking-eviction.md) | Atomic cache writes, cross-process locking, eviction |
| [M0-05](.tasks/M0-05-changed-files-semantics.md) | `file_changed?` against a base ref plus the dirty tree; git runs in `root` |
| [M0-06](.tasks/M0-06-run-persistence.md) | Every run's event stream persisted; `runs` list/show; a shared projection |

**Gate:** a secret value never appears in console, NDJSON, JSON output, or attestation; a raising
module step in a parallel stage yields one failed step and a completed run; two concurrent runs
sharing a cache key leave a valid entry; a past run can be listed and read back.

### M1 — Standalone binary ⬜

| Task | Item |
|---|---|
| [M1-01](.tasks/M1-01-cli-entrypoint.md) | `TinyCI.CLI` with `run`, `runs`, `cache` subcommands; the Mix task becomes a thin wrapper |
| [M1-02](.tasks/M1-02-run-outside-mix.md) | Runs in a directory with no `mix.exs`; every `Mix.*` call is guarded |
| [M1-03](.tasks/M1-03-release-binary.md) | Burrito-wrapped release per OS/arch; release workflow; install docs |

**Gate:** a downloaded binary runs a shell-only pipeline green in a Go repository on a machine
with no Erlang or Elixir installed, and `tiny_ci run --dry-run` matches `mix tiny_ci.run --dry-run`.

### M2 — The server ⬜

`tiny_ci serve`: one node, runs as supervised processes, triggered by webhooks, reporting back.

| Task | Item |
|---|---|
| [M2-01](.tasks/M2-01-run-process-model.md) | `TinyCI.Server.Run` GenServer per run under a DynamicSupervisor; cancel kills the OS subtree; in-process event bus |
| [M2-02](.tasks/M2-02-workspace-checkout.md) | Bare-mirror cache per repo, one worktree per run at the exact SHA |
| [M2-03](.tasks/M2-03-queue-and-scheduler.md) | FIFO queue, concurrency cap, per-branch auto-cancel of superseded runs |
| [M2-04](.tasks/M2-04-http-webhooks-and-polling.md) | Plug/Bandit HTTP; GitHub, GitLab, Gitea webhooks with signature checks; `git ls-remote` poller |
| [M2-05](.tasks/M2-05-commit-status-reporting.md) | Commit status posted back on queued/started/finished |
| [M2-06](.tasks/M2-06-secrets-store.md) | Encrypted-at-rest secrets store feeding the M0-03 `secret` directive |
| [M2-07](.tasks/M2-07-serve-cli-config-api.md) | `tiny_ci serve`, the config file, the HTTP API, token auth, dogfooding |

**Gate:** a team points a GitHub webhook at a fresh VM running one binary and sees a status check
on their pull request within a minute of pushing. This is the milestone at which tiny_ci is CI.

### M3 — Live UI ⬜

LiveView in the same binary. A pure consumer of events and a thin sender of control.

| Task | Item |
|---|---|
| [M3-01](.tasks/M3-01-web-app-shell.md) | `tiny_ci_web` Phoenix app in the release; run list, repo pages, live updates over PubSub |
| [M3-02](.tasks/M3-02-run-detail-view.md) | Run detail: DAG, streaming per-step logs, store panel, matrix rows; past and live runs share one projection |
| [M3-03](.tasks/M3-03-controls-and-auth.md) | Cancel, re-run, breakpoint controls; login |

**Gate:** no external database, one process, a fresh VM shows a live DAG updating as a run
executes and can open any run from history.

### M4 — Distributed runners ⬜

| Task | Item |
|---|---|
| [M4-01](.tasks/M4-01-runner-node.md) | `tiny_ci runner --join`; labels; registration; liveness via node monitoring |
| [M4-02](.tasks/M4-02-remote-stage-execution.md) | `runs_on:` stage option; scheduler assigns stages to runners; events and control cross nodes |
| [M4-03](.tasks/M4-03-artifact-transfer.md) | Artifacts move between nodes; downstream stages find them |
| [M4-04](.tasks/M4-04-secure-transport.md) | TLS distribution first; documented threat model; authenticated protocol later |

**Gate:** a macOS stage and a Linux stage in one pipeline run on two machines; killing a runner
mid-run is reported as a failure within seconds, not a hang.

### M5 — Speed ⬜

| Task | Item |
|---|---|
| [M5-01](.tasks/M5-01-affected-stages.md) | `paths:` on stages; the trigger supplies the base ref; unaffected stages are skipped |
| [M5-02](.tasks/M5-02-test-sharding.md) | `shards:` on stages fans a test suite across runners |
| [M5-03](.tasks/M5-03-flaky-test-quarantine.md) | Per-test failure records, targeted re-run, quarantine (design: `docs/archive/design-2026-05.md` §2) |

**Gate:** a monorepo push touching one package runs only that package's stages; a test suite
split across three runners finishes in roughly a third of the time.

### M6 — Debugging differentiators ⬜

These were designed earlier and are genuinely differentiating. They wait for a server and a UI
to live in. Re-specify each against M2/M3 before starting.

| Task | Item |
|---|---|
| [M6-01](.tasks/M6-01-shell-on-failure.md) | Drop into a shell in the failed step's environment (CLI first, then browser PTY) |
| [M6-02](.tasks/M6-02-conditional-breakpoints.md) | Breakpoints with `when:`-grammar conditions |
| [M6-03](.tasks/M6-03-replay-time-travel.md) | Scrub a recorded run's timeline in the UI |
| [M6-04](.tasks/M6-04-dap-editor-debugging.md) | Debug Adapter Protocol server for editor breakpoints |

### M7 — Ecosystem ⬜

| Task | Item |
|---|---|
| [M7-01](.tasks/M7-01-import-github-actions.md) | `tiny_ci import` converts simple GitHub Actions workflows |
| [M7-02](.tasks/M7-02-supply-chain-in-ui.md) | Lockfile, attestation, and registry surfaced in the UI; server runs attested |

## Explicitly not building

- Container orchestration or a Kubernetes operator. Runners are processes on machines you own.
- A hosted service before M4 is stable.
- Windows before M2 ships.
- Further module-step debugging (source-level pry, what-if re-runs, recorded external reads).
  Their old task files are kept under [`.tasks/deferred/`](.tasks/deferred/) until someone asks.
- A YAML compatibility layer. M7-01 is a one-time importer, not a runtime.

## Process

- One roadmap (this file), one task index (`.tasks/INDEX.md`), one task file per unit of work.
  Update the status in both when a task lands.
- Tasks are written for autonomous agents: see [`.tasks/CONVENTIONS.md`](.tasks/CONVENTIONS.md)
  for the test-first workflow and the definition of done every task shares.
- M2 is the first milestone dogfooded on a real machine: tiny_ci's own server builds tiny_ci.
