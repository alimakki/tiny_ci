# M6-01 — Drop-into-shell on failure (PTY over the web)

**Milestone:** M6 · **Complexity:** L · **Depends on:** T10 (T12 for the browser variant) · **Status:** ⬜ Not started

> **Carried over from the earlier plan (2026-07).** This task is scheduled in **M6** and must be
> re-specified against the M2 server (`TinyCI.Server.Run`, the event bus, the runs store) and the
> M3 UI before work starts: update *Depends on*, add a **Read first** list, a **TDD plan**, and
> the shared **Definition of done** from `CONVENTIONS.md`. The design intent below still holds.

## Summary

On step failure (or at a breakpoint), open an interactive shell in that step's exact
environment — debug in situ instead of guessing and re-pushing. The feature people
switch CI for, and the **cheapest first win** in the whole debugging cluster: the
terminal variant needs only a PTY + T10's pause, not the web UI.

## Implementation checklist

- [ ] **First increment (CLI):** on failure/breakpoint, drop into the *local*
      terminal shell in the step's env, cwd, and working tree — no web UI required
      (depends only on T10). This alone collapses the most common debug loop.
- [ ] Browser variant: spawn an interactive PTY in the step's env, cwd,
      working tree; stream to the browser over WebSocket/LiveView (adds T12).
- [ ] Freeze the surrounding run while the shell is open.
- [ ] Bidirectional I/O with acceptable latency; terminal resize works.
- [ ] When T8 exists, open the shell **inside** the same sandbox/container as the step.
- [ ] Secret handling per policy (documented; redact from scrollback capture).
- [ ] Opt-in only (`--debug-shell-on-failure`), never default in unattended CI.

## Acceptance criteria

- [ ] Failed step opens a shell with the same env, cwd, and (where applicable) sandbox.
- [ ] I/O streams bidirectionally with acceptable latency; resize works.
- [ ] Closing the shell resumes/finalizes the run deterministically.
- [ ] Secrets handled per documented policy (redacted from scrollback capture).
- [ ] Opt-in only; impossible to enable accidentally in headless runs.

## Implementation notes

- Use a PTY port (Erlang port to a shell, or a maintained PTY lib).
- Most security-sensitive UI feature — gate behind auth in any hosted context.
