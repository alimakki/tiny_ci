# T16 — Orchestrator / runner split (control plane + bring-your-own runners)

**Phase:** 4 — Distribution · **Complexity:** XL · **Depends on:** T1, T10 (conceptually T8's driver protocol) · **Status:** ⬜ Not started

## Summary

A hosted control plane that schedules and observes runs while steps execute on
runners the customer owns — so code and secrets never leave their infra and they
control compute cost, while keeping live observability/debugging. The
commercially-validated (Buildkite-style) model; the BEAM makes the split natural.

## Implementation checklist

- [ ] Split the engine into an **orchestrator** (scheduling, DAG, event aggregation,
      UI, control channel) and a **runner agent** (executes steps/actions, streams events back).
- [ ] Transport between them: distributed Erlang (trusted network) or a thin
      authenticated TLS/WebSocket protocol (customer networks).
- [ ] Runner registration, heartbeat, and assignment.
- [ ] T1 event stream + T10 control protocol flow across the wire.
- [ ] Reuse the T8 serialization boundary (config+context in, result+store-delta+events out).
- [ ] Lean on OTP supervision/distribution for runner liveness.

## Acceptance criteria

- [ ] A runner registers, heartbeats, and receives step/stage assignments.
- [ ] Steps execute on the runner; T1 events stream back into the UI in real time.
- [ ] T10 control commands work across the network boundary.
- [ ] Transport authenticated + encrypted; runner needs only outbound connectivity.
- [ ] The same pipeline runs identically inline / sandboxed-local (T8) / remote —
      verified by a shared test matrix.
- [ ] Loss of a runner mid-run is detected (heartbeat) and surfaced, not hung.

## Implementation notes

- Sequence last — it generalizes T1/T10/T8 across machines.
