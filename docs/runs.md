# Run history

Every `mix tiny_ci.run` leaves a record behind: the run's full [event stream](events.md)
plus a small summary. `mix tiny_ci.runs` reads it back, so yesterday's failure is still
there to look at.

There is no database. A run is a directory holding an NDJSON file, and every view of a
run (the console tree, `runs show`, a future web UI, replay) is a **fold over those
events**.

```sh
mix tiny_ci.run                      # recorded by default
mix tiny_ci.run --no-record          # skip recording this run
mix tiny_ci.runs                     # list this project's runs, newest first
mix tiny_ci.runs show RUN_ID         # one run: identity, the stage/step tree, why steps failed
mix tiny_ci.runs show RUN_ID --events    # the raw NDJSON recording
mix tiny_ci.runs prune --keep 50     # delete all but the newest 50
```

`--dry-run` and `--list` never record, because nothing runs.

## Layout

```
<base>/<project_id>/<run_id>/events.ndjson   # the recording, appended as the run happens
<base>/<project_id>/<run_id>/meta.json       # the summary, written once, atomically, at the end
```

| Part         | Value                                                                                   |
|--------------|-----------------------------------------------------------------------------------------|
| `<base>`     | `config :tiny_ci, :runs_base_dir`, else `$XDG_DATA_HOME/tiny_ci/runs`, else `~/.local/share/tiny_ci/runs` |
| `<project_id>` | the first 16 hex characters of the SHA-256 of the project's absolute root path        |
| `<run_id>`   | `<YYYYMMDD_HHMMSS>_<commit7>_<random>`; sorts chronologically (to the second) as a string |

`events.ndjson` is the authoritative record, in exactly the format `--events` writes. It
carries the `run_started` line, which records the run's git identity (`branch`, `commit`,
`base_ref`) and `root`, so a listing needs no separate write. `meta.json` is the folded
summary, kept so a listing does not have to fold every recording. If `meta.json` is
missing or unreadable, the recording is folded instead.

Runs are never deleted automatically. Use `mix tiny_ci.runs prune`.

## What gets recorded

- The recorder is one more sink on the run's event dispatcher, so it sees every event the
  console and `--events` see.
- Secret values are masked before any sink receives an event, so a recording never holds
  one. See [events.md](events.md#masking).
- Hook events are not part of the stream yet (hooks run after the dispatcher closes), so
  they are not recorded.
- Only runs with a project root are recorded. A bare `TinyCI.Executor.execute/4` call
  never writes to the data dir.
- **Recording never fails a run.** If the directory cannot be created, or a write fails
  part-way, the recorder prints one warning to stderr and stops recording. The run's
  result and exit code are unaffected, and `--output json` and `--events -` stay clean on
  stdout. A recording cut short that way has no `meta.json`, so it lists as `interrupted`.
- A run that emitted no events at all (it failed before it began) leaves nothing behind.

## Interrupted runs

A run whose process was killed has `events.ndjson` but no `meta.json`: it never reached
`run_finished`. It lists as **`interrupted`**, with every stage and step still running at
the cut marked `interrupted` too. A truncated last line is skipped when reading.

A run that is still in progress looks the same until it finishes, since it has no
`meta.json` yet. The listing cannot tell the two apart.

## The projection

`TinyCI.Runs.Projection` folds events into a run summary. Events are the **decoded NDJSON
maps** (string keys, with `type`, `seq`, `ts`), never structs.

```elixir
events = TinyCI.Runs.load(root, run_id) |> elem(1)
projection = TinyCI.Runs.Projection.fold(events)
TinyCI.Runs.Projection.to_json(projection)   # a superset of Results.to_json/3
```

| `type`                                  | effect                                              |
|-----------------------------------------|-----------------------------------------------------|
| `run_started`                           | identity, git fields, `schema_version`, `started_at` |
| `run_finished`                          | `status` (`passed`, `failed`, `aborted`), `finished_at`, `duration_ms` |
| `stage_started`                         | add the stage as `running` if absent                |
| `stage_skipped`                         | stage `skipped`, with its `reason`                  |
| `stage_finished`                        | stage status and `duration_ms`                      |
| `step_started`                          | add the step as `running` if absent                 |
| `step_skipped`                          | step `skipped`                                      |
| `step_output`                           | append the line to the step's `output`              |
| `step_retrying`                         | step `attempts` is the event's `attempt`            |
| `step_finished`                         | step status, `duration_ms`, `allowed_failure`, exact `output` |
| `cache_lookup`                          | step `cache` (`hit` or `miss`)                      |
| `matrix_run_started` / `_finished`      | add or update the stage's matrix run, keyed by `combination` |
| `breakpoint_hit` / `breakpoint_resumed` | one `breakpoints` entry per `pause_id`              |
| `run_diverged`                          | `divergent` is true                                 |
| anything else                           | ignored, for forward compatibility                  |

Details that matter when you consume it:

- A step event that carries `matrix_combination` belongs to that combination's matrix
  run; any other step event belongs to the stage. A matrix stage therefore has
  `matrix_runs` and no `steps`.
- Step updates are upserts. A step skipped by its `when:` condition emits `step_skipped`
  and never `step_started`, and still appears.
- Stages and steps appear in the order their first event arrived. In a parallel stage
  that is start order, which can differ from definition order.
- A step's `output` is one string, the same type `--output json` uses. While the step runs
  it is built from the `step_output` lines (blank lines are not events, so they are
  missing). Once the step finishes, `step_finished`'s `output` replaces it, so a finished
  step's output is exactly what `--output json` reports.
- Statuses decode through a fixed list. An unrecognised one becomes `unknown`.
- A matrix combination's variables are listed in key order by `runs show`, which can differ
  from the order they were declared in.
- `Projection.finalize/1` turns a run that never finished, and everything still running in
  it, into `interrupted`.

`to_json/1` is shaped like `mix tiny_ci.run --output json` (`status`, `duration_ms`,
`stages` with `steps` and `matrix_runs`), plus `run_id`, `pipeline`, git fields,
timestamps, `breakpoints`, `divergent`, and `last_seq`. A test holds the two in step.

## Reading from Elixir

```elixir
TinyCI.Runs.list(root, limit: 10)        # [%Projection{}], newest first
TinyCI.Runs.projection(root, run_id)     # {:ok, %Projection{}} | {:error, :not_found}
TinyCI.Runs.load(root, run_id)           # {:ok, stream of decoded event maps}
TinyCI.Runs.prune(root, keep: 50)        # %{removed: n}
```

`root` is expanded first, so `.` and the absolute path name the same project.

## Limits

- Step output is held in memory while the run is recorded, and `meta.json` includes it, so
  a listing reads it. A step that prints many megabytes makes both large.
- There is no retention policy beyond `prune`. A server will set its own default.
- Recording writes to disk synchronously, once per event, on the path every event takes. A
  data dir on a stalled network filesystem can slow or stall a run. Point `runs_base_dir`
  at a local disk, or use `--no-record`.
- A recording holds every step's full output, including anything a step prints that is not
  a declared secret. It is created with your default umask. If your builds print sensitive
  data, restrict the data dir's permissions or use `--no-record`.
