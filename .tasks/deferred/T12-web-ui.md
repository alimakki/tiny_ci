# T12 — Web UI — live run inspector (Phoenix LiveView)

**Phase:** 3 — Debugging & observability · **Complexity:** L · **Depends on:** T1, T10 · **Status:** ⬜ Not started

## Summary

A web interface showing the live DAG, streaming per-step logs, and the current
pipeline store, with controls to drive breakpoints. Ships as `tiny_ci_web`
(separate package; **never** a core dependency).

## Implementation checklist

- [ ] New package `tiny_ci_web/` (Phoenix LiveView) depending on core.
- [ ] Subscribe to a run's event stream via `Phoenix.PubSub` fed by a T1 event sink
      (do not poll executor internals).
- [ ] Render DAG with live per-stage/step status.
- [ ] Stream per-step logs (stdout/stderr), attributable via correlation IDs.
- [ ] Live store panel updating as module steps write.
- [ ] Matrix sub-rows.
- [ ] Controls wired to T10: continue / skip / retry / abort / set-store.
- [ ] Verify core's `mix.exs` does not depend on Phoenix.

## Acceptance criteria

- [ ] Launching a run with web UI serves a page showing the DAG updating live.
- [ ] Per-step logs stream in real time, attributable to the correct step.
- [ ] Store panel updates as module steps write.
- [ ] Breakpoint hits surface with inspectable state + working controls.
- [ ] Core CLI package does not depend on Phoenix (verified by core `mix.exs`).

## Implementation notes

- Keep the UI a pure consumer + thin control sender → works unchanged local or remote (T16).
