# T10 — Execution control protocol (pause / resume / skip / retry / abort)

**Phase:** 3 — Debugging & observability · **Complexity:** L · **Depends on:** T1 · **Status:** ✅ Done

## Summary

The real "breakpoint" primitive: pause execution of the resolved plan at step/stage
boundaries, inspect live context + store, then continue / skip / retry / abort.
Each step already runs in its own process, so a pause is that process awaiting a
control message.

## Implementation checklist

- [x] Control channel into a running pipeline (control `Registry` held by the run's supervisor).
- [x] Register breakpoints at named step/stage boundaries (before/after) via CLI
      (`--break before:deploy`, `--break after:test.unit`) and/or a control API.
- [x] On hit: block the relevant step/stage process; emit a `breakpoint_hit` event
      exposing resolved env, working dir, store snapshot, git context, matrix combo.
- [x] Control commands: `continue`, `skip`, `retry`, `abort`, `set_store k v`.
      (`set_store` + `retry` are the primitives T17's "re-run with edited inputs" builds on.)
- [x] Independent parallel branches keep running unless they hit their own breakpoints.
- [x] Mark any run touched by manual control (`set_store`, skip, edited retry) as
      **divergent** in the event stream, carried through to provenance (T7).
- [x] `--break-timeout` auto-resume/abort so a forgotten breakpoint can't hang CI.

## Acceptance criteria

- [x] Breakpoints declarable via CLI and/or control API.
- [x] Hitting one blocks the process and emits `breakpoint_hit` with inspectable state.
- [x] `continue`/`skip`/`retry`/`abort`/`set_store` behave as specified.
- [x] Pausing one parallel branch doesn't freeze independent branches.
- [x] A run with no breakpoints behaves exactly as today (perf + behaviour).

## Implementation notes

- Pause = step process `receive` on a control mailbox after emitting `breakpoint_hit`.
- Reuse T1 events for state exposure — the breakpoint payload is a richer event.
- Interactive pausing and parallelism are in tension. Default behaviour keeps
  independent branches running; also offer an opt-in `--debug-serial` that forces
  serial scheduling while any breakpoint is armed, for predictable stepping.
- This protocol is the substrate the editor debugger (T18, DAP) drives — keep the
  control surface transport-agnostic so it works local, sandboxed (T8), or remote (T16).

## Implementation record

**Modules** (`lib/tiny_ci/control/` + facade):

- `TinyCI.Control` — the whole public surface: `checkpoint/2` (executor),
  `subscribe/1` + `resume/3` + `paused/1` + `armed?/1` + `divergent?/1` (drivers).
- `TinyCI.Control.Breakpoint` — `before|after : STAGE[.STEP]` grammar; `parse/1`,
  `format/1`, `scope/1`, `match?/2`, `validate/2`. `:condition` reserved for T11.
- `TinyCI.Control.Session` — the paused boundary + `breakpoint_hit` payload; owns
  JSON-safe coercion and secret redaction.
- `TinyCI.Control.Server` — one GenServer per run, registered under `run_id` in
  `TinyCI.Control.Registry` (an Elixir `Registry` in the app supervisor; unrelated
  to `TinyCI.Registry`, the T9 action index).
- `TinyCI.Control.Console` — the terminal REPL. A plain subscriber.
- `TinyCI.Executor.Env` — extracted from `run_step/5` so the breakpoint payload and
  the step resolve env through one function.

**Key design points**

- The server never blocks; the process that hit the breakpoint does. Pausing is
  therefore scoped to one step task / one DAG stage task by construction.
- `checkpoint/2` returns `{command, ctx, store_overrides}`. Step-path overrides ride
  out on the `%StepResult{}`'s `store_data`, so a hand-edited value propagates out of
  a parallel branch through the existing merge rather than around it.
- The server owns the `--break-timeout` timer, which makes resume-vs-timeout races
  impossible. A timeout-abort goes through the same `abort_run/4` path as a typed
  abort, so it aborts the whole run.
- `retry` bypasses the cache (a hit would make it a silent no-op) and re-arms the
  breakpoint, giving an edit → retry → look loop.
- `:aborted` is a first-class status on `StepResult`/`StageResult` and in the event
  stream, mapped to exit 1 but distinguishable from a real failure. Schema version
  bumped 1 → 2 because that widens an existing field's domain.
- `--break` is refused at arm time when nothing can answer the prompt (non-TTY or
  `--output json`) and no `--break-timeout` was given — that, not a magic default, is
  how "a forgotten breakpoint can't hang CI" is enforced.

**Tests** — `test/tiny_ci/control/{breakpoint,session,server,console}_test.exs`,
`test/tiny_ci/control_integration_test.exs`, `test/tiny_ci/executor/env_test.exs`,
plus additions to the run-task, attest, events, reporter, and provenance suites.
Integration tests drive runs through the subscribe/resume protocol — the same seam
T18 will use — so no stdin is involved.

**Docs** — new `docs/execution-control.md`; `docs/events.md` (3 new types,
schema 2, widened `status`), `docs/provenance.md` (divergent runs), `README.md`.

**Deliberately deferred** — T11 leaves `Breakpoint.:condition` unevaluated; no
out-of-VM transport (T16/T18); no PTY (T13); no DAG-downstream re-run scope (T17).
