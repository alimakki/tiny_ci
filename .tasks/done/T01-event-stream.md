# T1 — Structured run event stream (NDJSON)

**Phase:** 0 — Foundations · **Complexity:** S–M · **Depends on:** none · **Status:** ✅ Done (additive/minimal scope) — deep reroute deferred

> Implemented additive/minimal per the approved plan. The event stream, dispatcher,
> seq, NDJSON sink, `--events` flag, console-as-sink (stage lifecycle), `cache_lookup`,
> and `docs/events.md` are done. Deferred (see "Deferred" below): full reroute of
> live streaming output, stderr split, live hook-event emission, secret masking content.

## Summary

Emit every meaningful run event as a structured, append-only stream so observers
(web UI, replay, provenance, orchestrator/runner) can reconstruct exactly what
happened without parsing human-formatted reporter output. The human reporter
becomes a *consumer* of this stream rather than a parallel code path.

## Current state (already in repo)

- ✅ Event **vocabulary** exists: `lib/tiny_ci/events.ex` defines 14 structs
  (`PipelineStarted/Completed`, `Stage*`, `Step*`, `MatrixRun*`, `Hook*`) with
  `Jason.Encoder` impls and a `run_id` + `timestamp` on every event.
- ✅ `test/tiny_ci/events_test.exs` covers construction + JSON encoding.
- ❌ No dispatcher, no sink behaviour, no `seq`, no `--events` flag.
- ❌ Executor still drives output through `TinyCI.Listener` (a parallel path).

## Implementation checklist

- [x] Add a `"type"` discriminator and a `seq` field to the NDJSON encoding of every
      event (envelope built encode→decode→merge→encode; `Events.type/1`).
- [x] `TinyCI.EventSink` behaviour (`init/1`, `handle_event/3`, `close/1`) documented.
- [x] `TinyCI.Events.Dispatcher` (per-run GenServer) — assigns monotonic `seq`,
      fans out to sinks, holds sink state, closes sinks on stop. **No global singleton.**
- [x] `TinyCI.Events.emit/2` thin API used by the executor at every boundary.
- [x] Thread the dispatcher reference through the run context (`:events`) so spawned
      Tasks (parallel stages/steps, matrix) emit to the right run.
- [x] NDJSON file sink (`TinyCI.Events.Sink.NDJSON`) — one JSON object per line;
      supports a file path and `-` (stdout).
- [x] Console sink (`TinyCI.Events.Sink.Console`) renders the stage lifecycle from
      events; `listener:` reinterpreted as console-sink selection (back-compat).
- [x] Executor emits: pipeline/stage/step/matrix started+finished, stage/step
      skipped, step output lines, step retrying, and `cache_lookup` (hit/miss + key).
- [x] `mix tiny_ci.run --events FILE|-` flag wired through the mix task.
- [~] Secret masking hook point — documented in `docs/events.md`; content masking
      deferred until a secrets directive exists.
- [x] `docs/events.md` — schema, `schema_version`, one example per event type.

## Acceptance criteria

- [x] `event_type` enum documented covering at least: `run_started`, `run_finished`,
      `stage_started`, `stage_finished`, `stage_skipped`, `step_started`,
      `step_output` (with `stream: :stdout|:stderr`), `step_finished` (status,
      attempt, duration), `step_skipped`, `cache_lookup` (hit/miss + key),
      `hook_started`, `hook_finished`. (exit code not tracked by the executor today.)
- [x] Each event includes `run_id`, monotonically increasing `seq`, ISO-8601 `ts`,
      and relevant correlation IDs (stage, step, matrix combination key).
- [x] `mix tiny_ci.run --events run.ndjson` writes valid NDJSON; `--events -` → stdout.
- [x] Human reporter output unchanged; stage lifecycle is now produced by consuming
      the event stream (no behavioural regression — full suite green at 607 tests).
- [~] Secret values masked in events — deferred until a secrets directive exists (seam documented).
- [x] `docs/events.md` describes the schema with one example per event type.

## Deferred (not in this session's additive/minimal scope)

- Full reroute of `output.ex` live streaming through events (console step output and
  matrix/retry-attempt renderings still go through `TinyCI.Listener`).
- Separating stderr from stdout (`stream` field exists; executor merges today).
- Live `hook_started`/`hook_finished` emission (hooks run after the run dispatcher
  closes in the current architecture; events are in the schema + docs).
- Secret masking content.

## Implementation notes

- `Dispatcher` serializes `seq` assignment through one process → monotonic across
  concurrent tasks; correlation IDs disambiguate interleaved parallel events.
- Do **not** rely on ordering across correlation IDs — only within one.
- Keep schema versioned (`schema_version` on `run_started`).
- Refactor `reporter.ex`/`output.ex` to emit/consume events; the executor calls
  `emit/2` and must not know who is listening.
- Gotcha: streaming step output currently prints directly from a `Port` in
  `output.ex` — route per-line output through `step_output` events while preserving
  live TTY printing via the console sink.
