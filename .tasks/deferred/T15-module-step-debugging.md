# T15 — Source-level debugging inside module steps

**Phase:** 3 — Debugging & observability · **Complexity:** L–XL · **Depends on:** T10, T12 (or T18 for the editor surface) · **Status:** ⬜ Not started

## Summary

Real breakpoints inside a module step's Elixir code — step through the one place
where actual code runs (vs. declarative config). Surfaced either through the web
UI (T12) or, more naturally, the editor via DAP `stepIn` (T18): a module step is
the deep tier of debuggability, whereas shell steps stay boundary-level (T13).

## Implementation checklist

- [ ] Enable BEAM-level debugging (`IEx.pry` / `IEx.break!` / `:int`) for first-party
      module steps.
- [ ] Surface the session via the web UI: inspect bindings, step, continue, resume.
- [ ] Available only for first-party/local module steps; clearly unavailable (with
      reason) for sandboxed third-party actions.

## Acceptance criteria

- [ ] A module step compiled in debug mode can hit a breakpoint that pauses execution
      and exposes local bindings through the UI.
- [ ] The author can step/continue and resume the pipeline afterward.
- [ ] Available only for first-party/local module steps; clearly unavailable for
      sandboxed third-party actions.

## Implementation notes

- Lean on existing BEAM tooling; the work is *surfacing* a pry/break session
  through `tiny_ci_web` (T12) and/or the editor over DAP (T18).
- Sandboxed code (T8) generally can't be pry-debugged from the orchestrator — scope out.
