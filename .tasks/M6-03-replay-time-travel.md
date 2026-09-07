# M6-03 — Run recording and replay / time-travel

**Milestone:** M6 · **Complexity:** M–L · **Depends on:** T1 · **Status:** ⬜ Not started

> **Carried over from the earlier plan (2026-07).** This task is scheduled in **M6** and must be
> re-specified against the M2 server (`TinyCI.Server.Run`, the event bus, the runs store) and the
> M3 UI before work starts: update *Depends on*, add a **Read first** list, a **TDD plan**, and
> the shared **Definition of done** from `CONVENTIONS.md`. The design intent below still holds.

## Summary

Record a run's full event stream and later replay it in the UI — scrub the
timeline, inspect store state at any point — to debug a past failure without re-running.

## Implementation checklist

- [ ] Persist the T1 event stream as a recording (the NDJSON stream *is* the recording).
- [ ] Replay mode re-feeds events into the UI at controllable speed.
- [ ] Timeline scrubber.
- [ ] Reconstruct store state at any event index (fold over events ≤ N).
- [ ] Replays are read-only and clearly marked.

## Acceptance criteria

- [ ] A run can be saved to a recording file and reopened later.
- [ ] Replay reconstructs the DAG, logs, and store state at any timeline point.
- [ ] Scrubbing back/forward shows store + step statuses as they were then.
- [ ] Replays are read-only and clearly marked.

## Implementation notes

- No new schema needed — store the NDJSON; replay is deterministic re-emission;
  store at index N is a fold over events ≤ N.
- Scope of *this* task is **viewing** a past run (read-only scrubbing), which is
  faithful because the recorded store-deltas are the actual values.
- Re-executing a step with modified inputs is **T17**. Faithful re-execution of a
  step's external reads (env/clock/git) needs **T19** (recorded reads).
- Honesty boundary: replay reconstructs the **data/store layer** only — it cannot
  reverse real-world side effects. See cross-cutting invariant 5.
