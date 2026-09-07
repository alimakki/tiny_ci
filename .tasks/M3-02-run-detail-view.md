# M3-02 — Run detail: DAG, streaming per-step logs, store panel, matrix rows

**Milestone:** M3 · **Size:** L · **Depends on:** M3-01 · **Status:** ⬜ Not started
**Written against:** the M2/M3-01 design; re-read before starting

> Detail level: design. Expand the TDD plan against the real code when M3 opens.

## Summary

`/runs/:id` — the page a status check links to. Shows the pipeline's stage graph with live
status, each step's output streaming as it happens, the pipeline store as module steps write
it, matrix combinations as sub-rows, retries and cache hits, and breakpoints when the run is
paused. Past runs render from the recorded stream through the **same** projection and the
same components, so history and live differ only in whether new events keep arriving.

## In scope

- `TinyCI.Runs.Projection` extensions as needed (store snapshot per step from
  `step_finished`/breakpoint payloads; DAG levels — reuse `TinyCI.DAG.build_levels/1` on the
  spec if the spec is recorded, otherwise infer from `stage_started` ordering; recording the
  resolved `PipelineSpec` shape in `run_started` is the better fix — bump the schema).
- Components: stage graph (levels left→right, stages as nodes, `needs:` as edges), step log
  panel with follow-tail and pause, store panel (diff highlighting on change), matrix table,
  breakpoint banner.
- Log volume: keep the last N lines per step in the LiveView assigns (N = 2000) and offer
  "download full log" via the API's NDJSON endpoint.

## Out of scope

- Controls (M3-03); replay scrubbing (M6-03).

## Acceptance criteria

- [ ] A live run shows stages moving through running → passed/failed with per-step log lines
      appearing in order and attributable to the right step.
- [ ] A finished run from history renders identically from `events.ndjson`.
- [ ] Matrix stages show one row per combination with its own status and duration.
- [ ] The store panel updates as module steps write; secrets are `***` (inherited from M0-03).
- [ ] A paused run shows the breakpoint payload (env, cwd, store, matrix combination).
- [ ] LiveView tests cover: live update, history render, matrix, breakpoint banner.
