# M4-02 — `runs_on:` stage option; remote stage execution; events and control across nodes

**Milestone:** M4 · **Size:** L · **Depends on:** M4-01 · **Status:** ⬜ Not started
**Written against:** the M2/M4-01 design; re-read before starting

> Detail level: design. Expand the TDD plan against the real code when M4 opens.

## Summary

Stages declare where they may run; the scheduler assigns them to a runner whose labels match;
the runner checks out the workspace, executes the stage with the existing `Executor.execute/4`,
and streams events back into the orchestrator's dispatcher so the recorder, the UI, and status
reporting see one unified run. Breakpoints work across the wire because the control server
is addressed by `run_id` through a `Registry` that is reachable by name from any node
(`GenServer.call({:via, Registry, ...})` only works locally — so give the control server a
global name or route through the orchestrator's `Run` process; decide and document).

## Design notes

- DSL: `stage :test, runs_on: [os: "linux", tags: ["gpu"]]` — add to `TinyCI.DSL.Spec` and the
  validator (keyword list of strings/lists of strings). Absent means "orchestrator or any".
- Placement: `TinyCI.Server.Placement.select(runners, requirements) :: {:ok, runner} | :no_match`;
  a stage with no matching runner fails with a clear reason (never hangs).
- Execution boundary: reuse `TinyCI.Sandbox.Protocol`'s serialisation discipline — the stage
  struct, the context (minus pids), and the store go over; `StageResult` + store delta come
  back. Events: a `TinyCI.Events.Sink.Remote` on the runner forwards each event to the
  orchestrator's dispatcher pid (`GenServer.call` across nodes is fine; the dispatcher stamps
  `seq`, preserving global ordering).
- The runner needs the workspace: it performs `Workspace.checkout/3` locally (M2-02 code), so
  it needs repository access; document.
- Failure: `nodedown` while a stage runs → the stage is marked failed with reason
  "runner lost", the run continues its failure path; a `requeue_on_lost: true` option is a
  follow-up.
- The same pipeline must run identically inline (`mix tiny_ci.run`), on the server alone, and
  with runners: extend the integration suite with one fixture pipeline executed all three ways
  and compare projections (ignoring durations and node names).

## Acceptance criteria

- [ ] A stage with `runs_on:` executes on a matching runner; its events appear in the run's
      recording in order with the rest.
- [ ] A `runs_on:` with no matching runner fails fast with a clear reason.
- [ ] Breakpoints placed on a remote stage pause and resume from the UI/CLI.
- [ ] Losing the runner mid-stage is reported within the net tick, not hung.
- [ ] The three-way parity test passes.
