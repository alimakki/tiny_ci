# Run event stream (NDJSON)

`tiny_ci` emits a structured, append-only stream of events during a run. It is the
single source of truth for "what happened" — consumed today by the human console
renderer and the NDJSON writer, and designed to back the future web UI, replay,
provenance, and orchestrator/runner features.

Write the stream with the `--events` flag:

```sh
mix tiny_ci.run --events run.ndjson   # one JSON object per line
mix tiny_ci.run --events -            # write to stdout instead
```

## Architecture

```
executor ──emit──▶ TinyCI.Events.Dispatcher ──┬─▶ TinyCI.Events.Sink.Console  (human output)
                   (assigns monotonic seq)     └─▶ TinyCI.Events.Sink.NDJSON   (--events)
```

- `TinyCI.Events` — the event vocabulary (one struct per event type) plus
  `emit/2`, `type/1`, and `schema_version/0`.
- `TinyCI.Events.Dispatcher` — one process per run. It stamps each event with a
  monotonic `seq` and fans it out to every registered `TinyCI.EventSink`. Because
  every emit is serialized through this one process, `seq` is strictly increasing
  even when parallel stages, steps, and matrix combinations emit concurrently. A
  sink that raises is isolated and never affects the run.
- `TinyCI.EventSink` — behaviour implemented by consumers: `init/1`,
  `handle_event/3` (`seq`, event, state), `close/1`.

Execution control (T10) both writes to and reads from this stream: a paused
boundary emits `breakpoint_hit` before blocking, and the control plane emits
`breakpoint_resumed` and `run_diverged`. See
[execution-control.md](execution-control.md).

The dispatcher is per-run (its pid lives on the run context), so concurrent runs
never interleave and `async: true` tests stay isolated.

## NDJSON line format

Each line is a single JSON object: the event's own fields plus three envelope
fields the dispatcher/sink add.

| Field            | Always | Description                                              |
|------------------|--------|----------------------------------------------------------|
| `seq`            | yes    | Monotonically increasing integer, starting at 1          |
| `type`           | yes    | Event type discriminator (see table below)               |
| `run_id`         | yes    | Identifier shared by every event in a run                |
| `ts`             | yes    | ISO-8601 timestamp                                        |
| `schema_version` | `run_started` only | Bumped on backwards-incompatible schema changes |

Correlation IDs (`run_id`, `stage`, `step`, matrix `combination`) tie related
events together. **Order is only guaranteed within a single correlation** — across
correlations, rely on `seq`, not arrival order.

The current `schema_version` is `2`.

**Changed in 2:** the `status` field on `run_started`'s counterparts —
`run_finished`, `stage_finished`, and `step_finished` — can now also be `"aborted"`
(execution control stopped the run) in addition to `"passed"`, `"failed"`, and
`"skipped"`. A consumer that matched only `passed`/`failed` needs updating. The
three `breakpoint_*` / `run_diverged` types below are additive.

## Event types

| `type`                | Emitted when…                          | Key fields beyond the envelope                 |
|-----------------------|----------------------------------------|------------------------------------------------|
| `run_started`         | a pipeline run begins                  | `pipeline_name`, `schema_version`              |
| `run_finished`        | a pipeline run ends                    | `status`, `duration_ms`                        |
| `stage_started`       | a stage begins                         | `stage`                                        |
| `stage_skipped`       | a stage is skipped                     | `stage`, `reason`                              |
| `stage_finished`      | a stage finishes                       | `stage`, `status`, `duration_ms`               |
| `step_started`        | a step begins                          | `stage`, `step`                                |
| `step_skipped`        | a step is skipped                      | `stage`, `step`, `reason`                      |
| `step_output`         | a line of step output                  | `stage`, `step`, `line`, `stream`              |
| `step_retrying`       | a step is retried after a failure      | `stage`, `step`, `attempt`                     |
| `step_finished`       | a step finishes                        | `stage`, `step`, `status`, `duration_ms`, `output` |
| `cache_lookup`        | a cached step resolves its key         | `stage`, `step`, `key`, `result` (`hit`/`miss`)|
| `matrix_run_started`  | one matrix combination begins          | `stage`, `combination`                         |
| `matrix_run_finished` | one matrix combination finishes        | `stage`, `combination`, `status`, `duration_ms`|
| `hook_started`        | a pipeline hook begins                 | `hook`                                         |
| `hook_finished`       | a pipeline hook finishes               | `hook`, `status`, `duration_ms`                |
| `breakpoint_hit`      | execution pauses at an armed boundary  | `pause_id`, `phase`, `scope`, `stage`, `step`, `breakpoint`, `env`, `working_dir`, `store`, `branch`, `commit`, `matrix_combination`, `result` |
| `breakpoint_resumed`  | a paused boundary is released          | `pause_id`, `command`, `waited_ms`, `timed_out`, `stage`, `step` |
| `run_diverged`        | manual control altered the run         | `reason`, `stage`, `step`, `detail`            |

### Notes

- `step_output.stream` is `"stdout"` or `"stderr"`. The executor currently merges
  stderr into stdout when running commands, so in practice every line is
  `"stdout"` today; the field exists so consumers can rely on it once the streams
  are separated.
- `step_finished.output` carries the step's captured output so buffered/offline
  consumers can render it without reaching into executor internals; it may be
  empty when output was streamed live.
- `hook_started` / `hook_finished` are part of the schema. Hooks currently run
  after the run's dispatcher has closed, so they are not yet emitted live into the
  stream — wiring them depends on the hook lifecycle and is tracked separately.
- Secret masking happens at the event/output boundary; once a secrets directive
  lands, secret values will be masked in events exactly as in console output. The
  `breakpoint_hit` payload is already routed through
  `TinyCI.Sandbox.Redaction.redact/2`, so it will mask as soon as the run carries
  a secrets list.
- `breakpoint_hit.store` and `.env` values are coerced to JSON-safe terms first:
  scalars pass through, anything else (a tuple, a pid, a struct) is rendered with
  `inspect/1`. A term in the store can never break the stream.
- `breakpoint_hit.scope` is `"stage"` or `"step"`; `step` is `null` on a stage
  boundary. `result` is `null` on a `"before"` boundary and carries `status` /
  `duration_ms` / `output` on an `"after"` one.
- `breakpoint_resumed.command` is one of `continue`, `skip`, `retry`, `abort`.
  `set_store` produces no `breakpoint_resumed` — it leaves the boundary paused —
  so `run_diverged` is its only trace.
- `run_diverged` is emitted once per divergent command, not once per run, so the
  stream records *what* changed. `TinyCI.Provenance` carries them into the
  attestation predicate and refuses to sign a divergent run.

## Example lines

```json
{"seq":1,"type":"run_started","run_id":"abc123","ts":"2024-01-15T10:30:00.000000Z","pipeline_name":"app","schema_version":1}
{"seq":2,"type":"stage_started","run_id":"abc123","ts":"2024-01-15T10:30:00.010000Z","stage":"test"}
{"seq":3,"type":"step_started","run_id":"abc123","ts":"2024-01-15T10:30:00.011000Z","stage":"test","step":"unit"}
{"seq":4,"type":"cache_lookup","run_id":"abc123","ts":"2024-01-15T10:30:00.012000Z","stage":"test","step":"unit","key":"deps-9f1c","result":"miss"}
{"seq":5,"type":"step_output","run_id":"abc123","ts":"2024-01-15T10:30:00.230000Z","stage":"test","step":"unit","line":"1 test, 0 failures","stream":"stdout"}
{"seq":6,"type":"step_retrying","run_id":"abc123","ts":"2024-01-15T10:30:00.240000Z","stage":"test","step":"unit","attempt":2}
{"seq":7,"type":"step_finished","run_id":"abc123","ts":"2024-01-15T10:30:00.250000Z","stage":"test","step":"unit","status":"passed","duration_ms":239,"output":"1 test, 0 failures"}
{"seq":8,"type":"matrix_run_started","run_id":"abc123","ts":"2024-01-15T10:30:00.260000Z","stage":"compat","combination":{"elixir":"1.18","otp":"27"}}
{"seq":9,"type":"matrix_run_finished","run_id":"abc123","ts":"2024-01-15T10:30:01.100000Z","stage":"compat","combination":{"elixir":"1.18","otp":"27"},"status":"passed","duration_ms":840}
{"seq":10,"type":"stage_skipped","run_id":"abc123","ts":"2024-01-15T10:30:01.110000Z","stage":"deploy","reason":"condition not met"}
{"seq":11,"type":"stage_finished","run_id":"abc123","ts":"2024-01-15T10:30:01.120000Z","stage":"test","status":"passed","duration_ms":1110}
{"seq":12,"type":"hook_started","run_id":"abc123","ts":"2024-01-15T10:30:01.130000Z","hook":"on_success"}
{"seq":13,"type":"hook_finished","run_id":"abc123","ts":"2024-01-15T10:30:01.140000Z","hook":"on_success","status":"passed","duration_ms":10}
{"seq":14,"type":"run_finished","run_id":"abc123","ts":"2024-01-15T10:30:01.150000Z","status":"passed","duration_ms":1150}
```

With a breakpoint armed (`--break before:deploy.push`):

```json
{"seq":9,"type":"breakpoint_hit","run_id":"abc123","ts":"2024-01-15T10:30:01.000000Z","pause_id":"pause_7","phase":"before","scope":"step","stage":"deploy","step":"push","breakpoint":"before:deploy.push","working_dir":"/repo","branch":"main","commit":"4f1c8a2b","matrix_combination":null,"result":null,"env":{"MIX_ENV":"prod"},"store":{"image_tag":"v1.4.2"}}
{"seq":10,"type":"run_diverged","run_id":"abc123","ts":"2024-01-15T10:30:12.000000Z","reason":"set_store","stage":"deploy","step":"push","detail":"image_tag = \"v1.4.3\""}
{"seq":11,"type":"breakpoint_resumed","run_id":"abc123","ts":"2024-01-15T10:30:14.000000Z","pause_id":"pause_7","command":"continue","waited_ms":14000,"stage":"deploy","step":"push","timed_out":false}
```

## Writing your own sink

Implement `TinyCI.EventSink` and register it with a dispatcher:

```elixir
defmodule MyCounter do
  @behaviour TinyCI.EventSink

  @impl true
  def init(_opts), do: {:ok, %{count: 0}}

  @impl true
  def handle_event(_seq, _event, state), do: {:ok, %{state | count: state.count + 1}}

  @impl true
  def close(state) do
    IO.puts("saw #{state.count} events")
    :ok
  end
end
```
