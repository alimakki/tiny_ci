# M4-03 — Artifacts between nodes

**Milestone:** M4 · **Size:** M · **Depends on:** M4-02 · **Status:** ⬜ Not started

> Detail level: design. Expand when M4 opens.

## Summary

A stage on runner A produces an artifact; a downstream stage on runner B (or the orchestrator)
needs it. Artifacts are uploaded to the orchestrator's artifacts store after the producing
step and materialised on the consuming node before the consuming stage starts.

## Design notes

- Orchestrator store stays `TinyCI.Artifacts` layout under the server data dir.
- Transfer: stream files in chunks over distribution (`File.stream!/2` + `:erpc`/message
  passing to a receiver process); checksum each artifact (sha256 of a tar of the paths) and
  record it in the `artifact_persisted` event (new event type; bump schema).
- Consumers: the executor already injects `artifact_<name>` store keys with a path; on a remote
  node the path must point to the local copy — the runner materialises before `execute/4` and
  rewrites the store entry.
- Size limits and retention: per-run cap (default 1 GiB), pruned with runs.

## Acceptance criteria

- [ ] An artifact produced on one node is available to a dependent stage on another node.
- [ ] Checksums are recorded and verified on receipt.
- [ ] Artifacts of pruned runs are removed.
