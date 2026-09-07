# M2-03 — Queue, concurrency cap, per-branch auto-cancel of superseded runs

**Milestone:** M2 · **Size:** M · **Depends on:** M2-01, M2-02 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M2-01/02 landed

## Summary

Triggers arrive faster than a machine can run pipelines, and a second push to a branch makes
the first push's run worthless. This task adds a `Scheduler` GenServer that queues
`RunRequest`s, starts them through `TinyCI.Server.Runs` up to a concurrency cap, and cancels
queued **and running** runs that a newer trigger for the same branch or pull request
supersedes — except on protected branches, where every commit is built.

## In scope

- `TinyCI.Server.Scheduler` GenServer with `enqueue/1`, `cancel/2`, `queue/0`, `active/0`.
- Supersede semantics and protected branches.
- Bus notifications for queue state changes.
- Config surface (consumed by M2-07): `max_concurrent`, `protected_branches`, `auto_cancel`.

## Out of scope

- Persistence of the queue across restarts (queued runs are lost on restart; document).
- Priorities and per-repo limits (follow-up when someone needs them).

## Read first

- `lib/tiny_ci/server/runs.ex`, `run.ex`, `event_bus.ex` (M2-01), `run_request.ex` (M2-02).
- Erlang `:queue` docs.

## Design

### State

```elixir
%{queue: :queue.queue(entry), running: %{run_id => %{pid, ref, entry}}, config: %Config{}}
entry = %{run_id, request, enqueued_at}
```

The scheduler assigns the `run_id` at enqueue (`TinyCI.Artifacts.generate_run_id/1` on a
minimal context built from the request's branch/commit) and passes it to `Runs.start/1` (add
`run_id:` to `RunRequest` so `Run.init/1` uses it when present). This lets the API and status
reporter refer to a run before it starts.

### Supersede key

```elixir
def supersede_key(%RunRequest{cause: :pull_request, meta: %{pr_number: n}, repo: r, pipeline: p}), do: {r.id, :pr, n, p}
def supersede_key(%RunRequest{cause: c, repo: r, branch: b, pipeline: p}) when c in [:push, :poll], do: {r.id, :branch, b, p}
def supersede_key(_manual), do: nil
```

On `enqueue/1` with `auto_cancel: true` and a non-nil key whose branch is **not** protected:

1. Remove queued entries with the same key; broadcast `{:run_status, id, :cancelled, %{reason: "superseded by <sha7>"}}`
   for each, and `TinyCI.Runs.mark/3`? — no: a queued run has no events on disk, so there is
   nothing to mark; just broadcast.
2. `Runs.cancel(id, "superseded by <sha7>")` for running entries with the same key.

Protected branches: `config.protected_branches` (default `["main", "master"]`) plus the repo's
`default_branch`. A run on a protected branch is never superseded and never cancelled by the
scheduler.

### Dispatch

`dispatch/1` is called after every enqueue and every `:DOWN`: while `map_size(running) < max_concurrent`
and the queue is non-empty, pop, `Runs.start/1`, monitor the pid, put in `running`, broadcast
`{:scheduler, :started, run_id}`. `max_concurrent` default: `max(div(System.schedulers_online(), 2), 1)`.

`:DOWN` for a running pid removes it and dispatches. The Run process itself broadcasts the
final status; the scheduler does not duplicate it.

### API

```elixir
enqueue(%RunRequest{}) :: {:ok, run_id}
cancel(run_id, reason) :: :ok | {:error, :not_found}     # queued → drop + broadcast; running → Runs.cancel
queue() :: [entry]      # FIFO order
active() :: [%{run_id, started_at, request}]
```

## TDD plan

Use a fixture pipeline with `cmd: "sleep 5"` for "slow" runs and `echo` for fast ones; a test
`Config` with `max_concurrent: 1`. `async: false` (named scheduler). Never sleep in tests; wait
on bus messages.

1. **`test/tiny_ci/server/scheduler_test.exs`**:
   - "respects max_concurrent": enqueue three slow runs → exactly one `{:scheduler, :started, _}`;
     cancel it → the next starts.
   - "FIFO": three fast runs start in enqueue order.
   - "a newer push supersedes a queued run on the same branch": cap 1; enqueue slow A (starts),
     enqueue B and C for `feature/x` → B is cancelled with reason containing C's sha7; C is
     queued.
   - "a newer push cancels a running run on the same branch": A running on `feature/x`; enqueue
     B same branch → A gets `:cancelled`, B starts.
   - "protected branches are never superseded": same as above on `main` → both run in order.
   - "pull requests supersede by number, not branch".
   - "manual runs are never superseded".
   - "auto_cancel: false disables all of it".
   - "cancel/2 on a queued id drops it".
   → implement.
2. Suites, credo, dogfood.

## Acceptance criteria

- [ ] Concurrency never exceeds `max_concurrent`.
- [ ] Superseded queued and running runs are cancelled with a reason naming the newer commit.
- [ ] Protected and default branches build every commit.
- [ ] Queue and active listings are available for the API (M2-07).
- [ ] Queue loss on restart is documented.

## Pitfalls

- Monitor the Run pid returned by `Runs.start/1`; do not rely on the bus for slot accounting
  (a subscriber can miss messages; a monitor cannot).
- Generating `run_id` twice (scheduler and Run) must not happen; `Run.init/1` uses the request's id.

## Docs

- `docs/server.md`: "Scheduling" section: cap, supersede rules, protected branches.

## Follow-ups

- Persistent queue; per-repo concurrency limits; priorities.
