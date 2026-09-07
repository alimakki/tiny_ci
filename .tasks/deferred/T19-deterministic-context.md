# T19 — Deterministic context: record/replay external reads

**Phase:** 3 — Debugging & observability (foundational) · **Complexity:** M · **Depends on:** T1 (informs T2) · **Status:** ⬜ Not started

## Summary

Route every external read a step makes — env vars, the clock, the git
branch/changed-files, and (eventually) network — through the pipeline `Context`,
and record those reads alongside the event stream. A run can then be replayed or
re-executed against the exact inputs it originally saw. This is the discipline
that makes faithful replay (T14) and re-run (T17) possible rather than
best-effort, and it extends the Action contract's "no smuggling external handles
across `execute/2`" rule from handles to **reads**.

## Implementation checklist

- [ ] Audit external reads made directly today (e.g. `when_env` calls
      `System.get_env/1`; `branch()`/`file_changed?` read context; timestamps) and
      funnel them through `ctx`-mediated accessors.
- [ ] Record each external read (key → value) into the run recording (T1/T14).
- [ ] Replay/re-run mode resolves external reads from the recording instead of the
      live environment.
- [ ] Document the determinism boundary: what is captured (env / clock / git) vs.
      what stays non-deterministic (arbitrary network/disk inside shell steps).
- [ ] Keep the live (non-replay) path behaviour-identical and zero-overhead.

## Acceptance criteria

- [ ] A recorded run replays/re-executes resolving env/clock/git from the
      recording, not the live machine.
- [ ] Mutating the live environment does not change a replayed run's external reads.
- [ ] The live path is unchanged in behaviour and performance.
- [ ] The determinism boundary is documented.

## Implementation notes

- Sequence **before** T14/T17 *faithfulness* — they function without it, but only
  best-effort, and must say so until this lands.
- Shell steps (`cmd:`) remain opaque: their internal reads can't be captured, so
  honesty about the boundary matters more than completeness.
- This nudges the Context toward being the single, recordable seam for all
  outside-world inputs — worth reflecting back into the T2 contract docs.
