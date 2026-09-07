# T17 — Step re-execution with modified inputs (what-if re-runs)

**Phase:** 3 — Debugging & observability · **Complexity:** M–L · **Depends on:** T10, T14 · **Status:** ⬜ Not started

## Summary

Re-run a single step — optionally everything downstream of it in the DAG —
against a chosen store snapshot with hand-edited inputs. This is the "tweak the
data and re-run" loop that turns CI from submit-and-pray into interactive
iteration, and it is the piece T14 explicitly defers. The step contract
(`config in → result + store-delta out`) is what makes a single step
independently re-runnable.

## Implementation checklist

- [ ] Re-execute one step from a captured store snapshot — sourced from a T14
      recording or a live T10 breakpoint.
- [ ] Edit the step's resolved inputs before the re-run: the store keys it reads
      (`store(:k)`), its `env:`, and its `set/2` config.
- [ ] Re-run scope selector: this step only, or this step **+ DAG-downstream
      dependents** (reuse `dag.ex` to compute the downstream set).
- [ ] Diff the resulting store-delta (and outcome) against the original run.
- [ ] Mark any run/step containing a re-execution as **divergent** in the event
      stream and in provenance (T7) — it is not a real CI result.
- [ ] Side-effect policy: a step declaring side-effecting capabilities
      (`network`, `filesystem_write`, `process_spawn`) is never silently
      re-executed — require explicit confirmation, or mock/skip it.

## Acceptance criteria

- [ ] A failed step can be re-run with an edited store value and produces a new
      result without re-running the whole pipeline.
- [ ] Re-run can target step-only or step + downstream dependents.
- [ ] The store diff (before → after) is shown.
- [ ] A divergent run is flagged everywhere it surfaces; attestation (T7) refuses it.
- [ ] Side-effecting steps are not silently re-executed.

## Implementation notes

- Builds directly on T10's `set_store` + `retry` and T14's snapshots.
- Faithful re-execution of a step's *reads* depends on T19 (recorded external
  reads). Without T19, re-runs are best-effort and must say so.
- Honesty boundary: this replays the **data layer**; it cannot un-perform
  real-world side effects (a push, a deploy). See cross-cutting invariant 5.
