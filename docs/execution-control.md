# Execution control (pause / resume / skip / retry / abort)

`tiny_ci` can pause a run at a named step or stage boundary, show you the live
context and store, and take a command: continue, skip, retry, abort — or edit a
store value and retry. It is the real breakpoint primitive, not a log filter.

```sh
mix tiny_ci.run --break before:deploy
mix tiny_ci.run --break after:test.unit --debug-serial
mix tiny_ci.run --break before:deploy --break-timeout 30000   # headless
```

Every step and every DAG stage already runs in its own process, so a pause is that
process waiting for a message. Nothing else in the run stops.

## Architecture

```
                          ┌───────────────────────────────┐
  step / stage process ──▶│ TinyCI.Control.checkpoint/2   │──▶ {command, ctx, edits}
   (blocks in receive)    └──────────────┬────────────────┘
                                         │ GenServer
                          ┌──────────────▼────────────────┐
                          │ TinyCI.Control.Server         │  one per run, registered
                          │  armed breakpoints            │  under run_id in
                          │  paused sessions              │  TinyCI.Control.Registry
                          │  divergent? / aborted?        │
                          └───┬───────────────────────┬───┘
                subscribers   │                       │  Events.emit
             ┌────────────────▼──────┐         ┌──────▼──────────────────┐
             │ Control.Console (REPL)│         │ Events.Dispatcher (T1)  │
             │ future: DAP, web, PTY │         │  breakpoint_hit …       │
             └───────────────────────┘         └─────────────────────────┘
```

- `TinyCI.Control` — the entire public surface: `checkpoint/2` for the executor,
  `subscribe/1` + `resume/3` for drivers.
- `TinyCI.Control.Breakpoint` — the `--break` grammar; parse, format, match, validate.
- `TinyCI.Control.Session` — the paused boundary and its inspectable payload.
- `TinyCI.Control.Server` — one process per run, addressed by `run_id`.
- `TinyCI.Control.Console` — the terminal REPL. An ordinary subscriber, no
  privileged access.

The server never blocks; the process that hit the breakpoint does. That is what
keeps independent branches alive, and it is why `abort` has to reach every paused
branch rather than just the one you typed it into.

### Cost when nothing is armed

`checkpoint/2` is one `Map.get(context, :control)` — the same shape as
`TinyCI.Events.emit/2`. `:control` is only put on the context when a caller passes
`control:`, so a run without `--break` takes no different path and pays no
measurable cost. There is no control process, and no control events appear in the
stream.

## Breakpoint grammar

```
SPEC   := ("before" | "after") ":" TARGET
TARGET := stage | stage "." step
```

| Spec | Pauses |
|---|---|
| `before:deploy` | before the `:deploy` stage runs any step |
| `after:deploy` | after `:deploy` finished, before its result is recorded |
| `before:test.unit` | before the `:unit` step of `:test` runs |
| `after:test.unit` | after `:unit` produced its result |

A stage breakpoint fires once, for the stage boundary. It does **not** implicitly
fire for every step inside the stage — arm a step breakpoint for that.

`--break` is repeatable, and both `before:deploy` and `before::deploy` parse (the
leading colon is optional, as with `--filter`).

Bad specs, unknown stages, and unknown steps are rejected **before the run starts**,
with the available names listed. A typo never costs you a pipeline.

## Commands

|  | `before:step` | `after:step` | `before:stage` | `after:stage` |
|---|---|---|---|---|
| `continue` | run it | keep the result | run the stage | keep the result |
| `skip` | body never runs; step is `skipped` | force the result to `skipped` | no step runs; stage is `skipped` | force the stage to `skipped` |
| `retry` | same as continue | re-run the body, cache bypassed | same as continue | re-run the whole stage |
| `abort` | stop the run | stop the run | stop the run | stop the run |
| `set k v` | edit the store, stay paused | edit the store, stay paused | edit the store, stay paused | edit the stage's store, stay paused |

Notes that matter in practice:

- **`retry` bypasses the cache.** A cache hit would make the retry a silent no-op,
  and you asked for the body to actually run again.
- **`retry` re-arms the breakpoint,** so you pause again on the next pass and can
  iterate: edit, retry, look, edit, retry.
- **`set` is not terminal.** It records the edit and keeps you at the prompt, so you
  can change several keys before resuming.
- **`abort` is cooperative.** It releases every paused branch, and every boundary
  reached afterwards short-circuits — but a step already executing is left to
  finish rather than being killed mid-write. Nothing is left half-written and no OS
  process is orphaned.
- An `:after` boundary shows the store the unit *produced*, not the one it started
  with, and an edit there lands on that produced store.

## What a breakpoint shows you

```
⏸  breakpoint before deploy.push
   stage:  deploy
   step:   push
   wd:     /repo
   git:    main @ 4f1c8a2b
   store:
     image_tag = "v1.4.2"
     build_sha = "4f1c8a2b"
   env:
     MIX_ENV = "prod"
     REGISTRY = "ghcr.io/acme"
(tiny_ci) set image_tag v1.4.3
   store.image_tag = "v1.4.3" — run marked divergent (not attestable)
(tiny_ci) continue
```

The resolved environment comes from `TinyCI.Executor.Env`, the same function the
step itself uses — a breakpoint that reported a different env than the step received
would be worse than reporting none.

Store values can be arbitrary Elixir terms. JSON-native scalars are shown as they
are; everything else is rendered with `inspect/1`, so a pid or a struct in the store
can never break the NDJSON stream. The whole payload passes through
`TinyCI.Sandbox.Redaction.redact/2` with the run's known secrets, so a secret cannot
leak into an event or the console through a breakpoint.

### Console commands

```
continue | c        resume and run/keep the boundary as normal
skip | s            do not run it (or force the result to skipped)
retry | r           re-run the body, bypassing any cache
abort | a           stop the whole run
set KEY VALUE       edit a store key, then keep inspecting
store               re-print the store snapshot
env                 re-print the resolved environment
info                re-print the full boundary
help | ?            list these commands
```

A bare newline continues. If stdin closes, the run aborts rather than hanging.

## Parallelism

Pausing one branch does **not** freeze the others. Independent DAG stages keep
running, and so do sibling steps in a `mode: :parallel` stage. Several boundaries
can therefore be paused at once; the REPL prompts for the oldest and reports the
rest as queued.

That is usually what you want in a real pipeline and occasionally maddening when you
are stepping. `--debug-serial` trades the parallelism for predictability while
breakpoints are armed:

- independent DAG stages in the same level run one at a time
- a `mode: :parallel` stage degrades to `:serial`
- matrix fan-out is capped at one combination

It is off by default. Serial-mode siblings within a single stage necessarily wait
behind a pause — that is the honest semantics of a serial stage, not a bug.

## Timeouts: a breakpoint can't hang CI

`--break-timeout MS` auto-resolves an unanswered breakpoint with
`--break-timeout-action` (`abort`, the default, or `continue`). The resolution is
recorded on the `breakpoint_resumed` event with `timed_out: true`, and a
timeout-abort aborts the whole run exactly as a typed `abort` would.

The guarantee is enforced at arm time, not by a magic default:

> `--break` is **refused** when no interactive terminal can answer the prompt
> (non-TTY, or `--output json`) unless `--break-timeout` is given.

So a `--break` left in a CI invocation fails fast with an explanation instead of
blocking a runner for an hour. Attach your own driver (below) if you want to answer
programmatically.

## Divergence: a steered run is not a CI result

`set_store`, a forced `skip`, and a forced `retry` each change what the run would
otherwise have done. Each emits a `run_diverged` event naming the reason and what
changed, and the run is marked **divergent**:

- `TinyCI.Provenance` flags it (`predicate.divergent`) and lists every change under
  `predicate.divergences`
- `mix tiny_ci.run --attest` **refuses to sign it**, with an explanation

`abort` is not divergence. Nothing was altered; the run was stopped, and it reports
`aborted` rather than `failed` so a JSON consumer can tell "somebody stopped this"
from "the code under test is broken".

## Events

Three additions to the stream (see [events.md](events.md)):

| `type` | Emitted when | Key fields |
|---|---|---|
| `breakpoint_hit` | a boundary pauses | `pause_id`, `phase`, `scope`, `stage`, `step`, `breakpoint`, `env`, `working_dir`, `store`, `branch`, `commit`, `matrix_combination`, `result` |
| `breakpoint_resumed` | a terminal command releases it | `pause_id`, `command`, `waited_ms`, `timed_out` |
| `run_diverged` | manual control altered the run | `reason`, `stage`, `step`, `detail` |

`status` on `run_finished`, `stage_finished`, and `step_finished` can now be
`"aborted"`, which is why the schema version is `2`.

## Writing your own driver

The control surface is deliberately transport-agnostic: this is exactly what the DAP
adapter (T18), a web UI (T12), and a PTY shell (T13) will do, and what the test
suite already does.

```elixir
# Start the driver first and pass it in, so it sees the *first* breakpoint — the
# control server does not exist until the run begins.
{:ok, driver} = MyDriver.start_link()

TinyCI.Executor.run_pipeline(stages, context,
  control: [
    breakpoints: ["before:deploy"],
    subscribers: [driver],
    timeout: 60_000,
    timeout_action: :abort,
    serial: false
  ]
)
```

A subscriber receives:

```elixir
{:tiny_ci_control, :breakpoint_hit, %TinyCI.Control.Session{} = session}
{:tiny_ci_control, :resumed, pause_id, command}
{:tiny_ci_control, :diverged, reason, session}
```

and answers with `resume/3`:

```elixir
TinyCI.Control.resume(session.run_id, session.pause_id, {:set_store, :tag, "v2"})
TinyCI.Control.resume(session.run_id, session.pause_id, :retry)
```

To attach to a run already in flight, address it by `run_id`:

```elixir
TinyCI.Control.armed?(run_id)        # does this run have a control plane?
TinyCI.Control.subscribe(run_id)     # notify me from here on
TinyCI.Control.paused(run_id)        # currently paused sessions, oldest first
TinyCI.Control.divergent?(run_id)    # has anything been altered?
```

`subscribe/1` only sees boundaries reached *after* it attaches. If you attach late,
read `paused/1` to pick up boundaries already waiting.

## Relationship to other features

- **T11 (conditional breakpoints)** will fill `Breakpoint`'s reserved `:condition`
  field with a `when:`-grammar AST evaluated through `TinyCI.DSL.ConditionEval` —
  the same language, never a second one.
- **T13 (shell on failure)** opens a PTY at a pause; it needs the boundary's env,
  cwd, and sandbox, all of which the session already carries.
- **T17 (re-run with edited inputs)** is `set_store` + `retry` with a DAG-downstream
  scope selector on top.
- **T18 (DAP)** maps gutter breakpoints to specs and `continue`/`next`/`pause` to
  these commands.
