# M2-01 — Run GenServer + DynamicSupervisor; cancel kills the OS subtree; in-process event bus

**Milestone:** M2 · **Size:** M–L · **Depends on:** M0-01, M0-06, M1-01 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M0/M1 landed as specified

## Summary

This is the first server task. It introduces the `tiny_ci_server` Mix project and the process
model everything else in M2–M4 hangs off: **one supervised GenServer per run**, started under a
`DynamicSupervisor`, executing the existing `TinyCI.Executor` in an unlinked task, publishing
its event stream on an in-process bus, recording it through M0-06, and able to **cancel** a run
by killing every OS process it spawned.

Nothing here talks HTTP or git yet. A run is started by calling a function with a
`%RunRequest{}`; the request already carries a checked-out `root`. M2-02 adds checkout, M2-03
the queue, M2-04 the triggers.

## Project layout decision

`tiny_ci` (root) stays a library with `jason` as its only runtime dependency. The server is a
sibling Mix project, like `tiny_ci_lsp/`:

```
tiny_ci_server/
  mix.exs            # app :tiny_ci_server, deps: {:tiny_ci, path: ".."}, plug, bandit, req (later tasks)
  lib/tiny_ci/server/...
  test/...
tiny_ci_dist/        # created in M1-03: the release project; add {:tiny_ci_server, path: "../tiny_ci_server"} here
```

`TinyCI.CLI` (core) discovers server subcommands through the registry introduced in M1-01
(`config :tiny_ci, cli_subcommands: [...]`, set in `tiny_ci_dist/config/config.exs`).

## In scope

Core (`tiny_ci`):

- `TinyCI.Runner` — extract "run a loaded spec: executor + hooks" from `TinyCI.CLI.Run` so the
  CLI and the server call the same function and cannot drift.
- `TinyCI.OSProcesses` — an ETS registry of live `{run_id, os_pid}` pairs written by
  `TinyCI.Output`; `kill_all(run_id)`.
- `ctx.project_id` override honoured by `TinyCI.Artifacts` and `TinyCI.Runs` (server runs live
  in per-run workspaces, so `project_id` cannot be derived from `root`).
- `TinyCI.Runs.mark(root_or_project_id, run_id, status)` to finalise `meta.json` for runs that
  never emitted `run_finished` (cancelled, crashed).

Server (`tiny_ci_server`):

- `TinyCI.Server.Application` and supervision tree.
- `TinyCI.Server.RunRequest` struct.
- `TinyCI.Server.Run` GenServer; `TinyCI.Server.RunSupervisor`; `TinyCI.Server.RunRegistry`.
- `TinyCI.Server.EventBus` (+ `EventBus.Sink`).
- `TinyCI.Server.Runs` facade: `start/1`, `cancel/2`, `status/1`, `list_active/0`.
- Tests.

## Out of scope

- Checkout (M2-02), queueing (M2-03), HTTP (M2-04), status reporting (M2-05).
- Restarting runs after a server restart. A run that was in flight is `interrupted` in history.

## Read first

- `lib/tiny_ci/executor.ex` — `run_pipeline/3` options (`listener`, `output`, `extra_sinks`,
  `secrets`, `record`, `control`), and how `ctx.run_id`/`ctx.root` are set.
- `lib/tiny_ci/cli/run.ex` (after M1-01) — the sequence executor → hooks → reporter → attest;
  the part that must move into `TinyCI.Runner` is "executor → hooks".
- `lib/tiny_ci/hooks.ex` — `run/3` (or current arity) and what it needs from the context.
- `lib/tiny_ci/output.ex` — `run_port/5`, `port_os_pid/1`, `kill_subtree/1` (make the last
  `@doc false` public).
- `lib/tiny_ci/artifacts.ex` — `project_id/1`, `generate_run_id/1`, `run_artifacts_dir/2`.
- `lib/tiny_ci/runs.ex`, `lib/tiny_ci/runs/recorder.ex` (M0-06).
- `lib/tiny_ci/events/dispatcher.ex`, `lib/tiny_ci/event_sink.ex`.
- `lib/tiny_ci/application.ex` — where the ETS table for `OSProcesses` gets created.
- `tiny_ci_lsp/mix.exs` — sibling-project conventions (path dep, credo, prod env).
- `test/tiny_ci/executor_test.exs` — the pgrep pattern for "no orphaned OS processes".

## Design

### Core: `TinyCI.Runner`

```elixir
@spec run_spec(PipelineSpec.t(), keyword()) ::
        {:ok, [StageResult.t()]} | {:error, term(), [StageResult.t()]}
# opts: everything Executor.run_pipeline/3 accepts, plus context: map() (pre-built) and hooks?: boolean (default true)
```

Builds/uses the context, calls `Executor.run_pipeline/3`, runs `Hooks` for `:on_success` or
`:on_failure` unless the run was aborted, returns the executor result. `TinyCI.CLI.Run` calls
it and keeps the printing/attesting around it. No behaviour change for the CLI.

### Core: `TinyCI.OSProcesses`

- Named public ETS table `:tiny_ci_os_processes`, created in `TinyCI.Application.start/2`,
  `:bag` keyed by `run_id`, values `os_pid`.
- `register(run_id, os_pid)`, `unregister(run_id, os_pid)`, `list(run_id)`, `kill_all(run_id)`
  (snapshot the list, then `Output.kill_subtree/1` each, then delete the key).
- `TinyCI.Output.run_port/5` registers right after `port_os_pid/1` and unregisters in the
  `after` of the collection loop, **only when** `opts[:run_id]` is present. The executor and
  hooks pass `run_id: ctx.run_id` in the output options.

### Core: `project_id` override

`Artifacts.project_id(ctx_or_root)`: if given a map with `:project_id`, return it; else hash
the root as today. `Runs` uses the same. `Recorder.init/1` accepts `project_id:`.
`Runs.mark(project_id_or_root, run_id, status)` folds `events.ndjson`, sets `status`, writes
`meta.json` atomically. Allowed extra statuses: `:cancelled`, `:crashed`, `:interrupted`.

### Server: supervision tree

```
TinyCI.Server.Supervisor (one_for_one)
├── TinyCI.Server.RunRegistry     Registry, keys: :unique   (run_id -> Run pid)
├── TinyCI.Server.EventBus        Registry, keys: :duplicate (topic -> subscriber pids)
└── TinyCI.Server.RunSupervisor   DynamicSupervisor, restart: :temporary children
```

`TinyCI.Server.Application.start/2` starts **only** this tree in M2-01. M2-07 decides what
starts under `serve`. (The application must be startable in tests without config.)

### `TinyCI.Server.RunRequest`

```elixir
@enforce_keys [:root, :project_id]
defstruct root: nil, project_id: nil, pipeline: nil,        # pipeline: nil = discovery; String = name; {:file, path}
          branch: nil, commit: nil, base_ref: nil,          # context overrides
          secrets: %{}, filter: nil, cause: :manual,        # cause: :manual | :push | :pull_request | :poll
          meta: %{}                                         # free-form: repo name, pr number, sender...
```

### `TinyCI.Server.Run`

- `start_link(request)`; registered via `RunRegistry` under the `run_id` it generates in
  `init/1` with `TinyCI.Artifacts.generate_run_id/1` (build a minimal context first).
- State: `%{id, request, status, task_ref, task_pid, started_at, finished_at, result, reason}`.
  Statuses: `:starting | :running | :passed | :failed | :aborted | :cancelled | :crashed`.
- `init/1`: `Process.flag(:trap_exit, true)`; broadcast `{:run_status, id, :starting}`;
  `{:ok, state, {:continue, :start}}`.
- `handle_continue(:start)`: load spec (`Discovery`), build context
  `TinyCI.Context.build(root: root, base: base_ref, include_dirty: false)` then override
  `branch`/`commit` from the request and put `project_id`; start
  `Task.Supervisor.async_nolink(TinyCI.TaskSupervisor, fn -> TinyCI.Runner.run_spec(spec, opts) end)`
  with `listener: TinyCI.Listener.Silent, output: :buffered, secrets: request.secrets,
  extra_sinks: [{TinyCI.Server.EventBus.Sink, run_id: id}], context: ctx`. Status `:running`.
  A load failure → status `:failed`, reason recorded via `Runs.mark`, broadcast, stop.
- `handle_info({ref, result}, state)` when `ref == task_ref`: demonitor/flush; map result to
  status (`{:ok, _}` → `:passed`; `{:error, {:aborted, _}, _}` → `:aborted`; else `:failed`);
  broadcast; `{:stop, :normal, state}`.
- `handle_info({:DOWN, ref, :process, _, reason}, state)`: status `:crashed`; `Runs.mark/3`;
  broadcast with `reason`; stop.
- `handle_call({:cancel, reason}, ...)`: if running: `TinyCI.OSProcesses.kill_all(id)`,
  `Process.exit(task_pid, :kill)`, status `:cancelled`, `Runs.mark/3`, broadcast, stop with
  `:normal`. If already finished: `{:error, :not_running}`.
- `handle_call(:status, ...)`: the public status map.

Cancellation must be **complete**: the test kills a `sleep` marker and asserts `pgrep` finds
nothing after the cancel returns.

### `TinyCI.Server.EventBus`

- Topics: `{:run, run_id}` and `:runs` (everything). `subscribe(topic)`, `unsubscribe(topic)`.
- `broadcast(run_id, message)` dispatches to both topics via `Registry.dispatch/3`.
- Messages: `{:tiny_ci_event, run_id, seq, event_struct}` from the sink and
  `{:run_status, run_id, status, meta_map}` from `Run`.
- `EventBus.Sink` implements `TinyCI.EventSink`: `init(run_id:)`, `handle_event/3` broadcasts,
  `close/1` no-op. It runs inside the run's dispatcher process, so a slow subscriber must not
  block it: `Registry.dispatch` sends messages; it does not wait. Fine.

### `TinyCI.Server.Runs`

```elixir
start(%RunRequest{}) :: {:ok, run_id}
cancel(run_id, reason \\ "cancelled") :: :ok | {:error, :not_found | :not_running}
status(run_id) :: {:ok, map()} | {:error, :not_found}     # live only; history is TinyCI.Runs
list_active() :: [map()]
```

## TDD plan

Core first (all in the root project):

1. **`test/tiny_ci/runner_test.exs`** — `run_spec/2` on a passing spec returns the executor
   result and runs the `on_success` hook (observe via a temp file the hook writes); a failing
   spec runs `on_failure`; `hooks: false` runs neither. → extract `TinyCI.Runner`; `CLI.Run`
   uses it; all Mix task tests stay green.
2. **`test/tiny_ci/os_processes_test.exs`** — `Output.run_cmd("sleep 5 && echo <marker>", run_id: "r1", timeout: 10_000)`
   started in a task: while it runs, `list("r1")` has one pid; `kill_all("r1")` returns and
   `pgrep -f <marker>` is empty; after a normal completion the key is empty. → implement.
3. **`test/tiny_ci/runs_test.exs`** — `mark/3` writes `meta.json` with `status: "cancelled"`
   from an events file lacking `run_finished`; `project_id` override is honoured by
   `Runs.dir/2` and `Artifacts.run_artifacts_dir/2` (context map with `:project_id`). → implement.

Server (create `tiny_ci_server/` with `mix new tiny_ci_server --sup`, then reshape):

4. **`test/tiny_ci/server/event_bus_test.exs`** — subscribe to `{:run, "r"}` and `:runs`; a
   broadcast reaches both; unsubscribed pids get nothing. → implement.
5. **`test/tiny_ci/server/run_test.exs`** (`@tag :tmp_dir`; a fixture pipeline file written into
   `tmp_dir`; runs base dir redirected via `:tiny_ci, :runs_base_dir`; `async: false`):
   - passing pipeline: `Runs.start/1` → `{:ok, id}`; subscriber receives `{:run_status, id, :running, _}`,
     then `{:tiny_ci_event, id, _, %PipelineStarted{}}` … `%PipelineCompleted{}`, then
     `{:run_status, id, :passed, _}`; `TinyCI.Runs.projection(project_id, id)` is `:passed`;
     the Run process has exited normally (monitor it).
   - failing pipeline → `:failed`.
   - cancel: pipeline step `cmd: "sleep 30 && echo <unique marker>"`; wait for `:running` and
     for `OSProcesses.list(id)` to be non-empty (poll with deadline, no sleep); `Runs.cancel(id)`
     → `:ok`; `{:run_status, id, :cancelled, _}`; `pgrep -f marker` empty; `meta.json` status
     `"cancelled"`.
   - crash: obtain `task_pid` from `Runs.status(id)` (expose it for tests) and
     `Process.exit(task_pid, :kill)` → `{:run_status, id, :crashed, %{reason: :killed}}`;
     meta status `"crashed"`.
   - unloadable pipeline path → `:failed` with a load reason, no crash.
   → implement `Run`, `RunSupervisor`, `RunRegistry`, `Runs`.
6. `mix test` in both projects; `mix credo` in both; `mix tiny_ci.run` at root.

## Acceptance criteria

- [ ] `TinyCI.Runner.run_spec/2` is the single executor+hooks entrypoint used by CLI and server.
- [ ] A run is one GenServer under `RunSupervisor`, discoverable by id, exiting normally when done.
- [ ] Subscribers receive every event of a run in order plus status transitions.
- [ ] `cancel/2` leaves no OS process of the run alive and records `cancelled` in history.
- [ ] An executor task crash is recorded as `crashed`, not lost.
- [ ] `project_id` override works end to end (runs store and artifacts).
- [ ] `tiny_ci_server` has its own passing test suite, credo clean, and `tiny_ci_dist` includes it.

## Pitfalls

- `Task.Supervisor.async_nolink/2` replies arrive as `{ref, result}` **and** a `:DOWN` follows;
  `Process.demonitor(ref, [:flush])` after the reply or you will also see the DOWN.
- The executor's dispatcher is linked to the task; when the task is killed the dispatcher dies
  and the recorder's `close/1` never runs — that is why `Runs.mark/3` exists.
- Killing the task does not kill ports' OS processes (T21's lesson); hence `OSProcesses`.
- ETS `:bag` allows duplicate `{run_id, pid}` if a pid is reused; `unregister/2` with
  `:ets.delete_object/2` handles it.
- `Registry.dispatch/3` runs the callback in the caller; keep it to `send/2`.

## Docs

- `docs/server.md` (new, grows across M2): the process model section with the supervision
  tree diagram and the cancel semantics.
- `docs/runs.md`: the extra statuses.

## Follow-ups

_(none yet)_
