# M4-01 — `tiny_ci runner --join`: labels, registration, liveness

**Milestone:** M4 · **Size:** M–L · **Depends on:** M2-07 · **Status:** ⬜ Not started
**Written against:** the M2 design; re-read before starting

> Detail level: design. Expand the TDD plan against the real code when M4 opens.

## Summary

A second machine runs the same binary as `tiny_ci runner --join <orchestrator>` and becomes a
place where stages can execute. This task is registration and liveness only: the runner node
connects, announces its labels (`os`, `arch`, free-form tags), heartbeats via node monitoring,
and appears in the API/UI. No stage runs remotely yet (M4-02).

## Design notes

- Transport for M4: distributed Erlang with a cookie, over a trusted network (VPN/LAN). M4-04
  adds TLS distribution and documents the threat model. Runners connect **out** to the
  orchestrator (`Node.connect/1`), so only the orchestrator needs an open port.
- `TinyCI.Server.Runners` (orchestrator): registry of `%Runner{node, labels, capacity, status,
  last_seen}`; uses `:net_kernel.monitor_nodes(true)` and `Node.monitor/2`; a `nodedown` marks
  the runner `:lost` immediately and (M4-02) fails or requeues its stages.
- `TinyCI.Runner.Agent` (runner node): on start, `Node.connect`, then `:erpc.call` the
  orchestrator's `Runners.register/1` with labels; re-register on reconnect; responds to
  `ping/0`; exposes `capacity` (default: schedulers/2).
- Labels: `os` and `arch` from `:os.type/0` and `:erlang.system_info(:system_architecture)`
  automatically; `--label key=value` repeatable.
- CLI: `tiny_ci runner --join orchestrator@host --cookie-file PATH [--name NAME] [--label k=v]...`
  registered via the subcommand registry from a new `tiny_ci_runner` app **or** the server app
  (decide: the runner needs core + workspace/checkout code from the server app, so the server
  app is the pragmatic home; the binary is the same anyway).
- API/UI: `GET /api/runners`; a runners panel on the UI home.

## Acceptance criteria

- [ ] A runner started with `--join` appears in `/api/runners` with its labels within a second.
- [ ] Killing the runner process marks it `lost` on the orchestrator within the net tick
      (default 60 s; set `net_ticktime` to 15 s in the release `vm.args` and document).
- [ ] A restarted runner re-registers with the same name and replaces the lost entry.
- [ ] Tests use `:peer` (OTP 25+) to start a second node in the test suite; no manual steps.
