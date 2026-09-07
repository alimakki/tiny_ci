# M6-02 — Conditional breakpoints via the condition DSL

**Milestone:** M6 · **Complexity:** S–M · **Depends on:** T10 · **Status:** ⬜ Not started

> **Carried over from the earlier plan (2026-07).** This task is scheduled in **M6** and must be
> re-specified against the M2 server (`TinyCI.Server.Run`, the event bus, the runs store) and the
> M3 UI before work starts: update *Depends on*, add a **Read first** list, a **TDD plan**, and
> the shared **Definition of done** from `CONVENTIONS.md`. The design intent below still holds.

## Summary

Breakpoints that only fire when a condition holds, expressed in the same language
as `when:` — break only on the branch/env/state you care about.

## Implementation checklist

- [ ] Attach a condition expression to a breakpoint.
- [ ] Evaluate with the existing `dsl/condition_eval.ex` against live context (no second evaluator).
- [ ] Optionally allow conditions to reference the store snapshot at the breakpoint.
- [ ] Reject a malformed break condition up front with a clear message.

## Acceptance criteria

- [ ] `--break before:deploy when 'branch() == "main"'` only pauses on `main`.
- [ ] Conditions reuse `dsl/condition_eval.ex`.
- [ ] (Optional) conditions can reference the store snapshot.
- [ ] Malformed break condition rejected up front with a clear message.

## Implementation notes

- The break-condition language being identical to `when:` is the elegant property —
  do not introduce a parallel mini-language.
