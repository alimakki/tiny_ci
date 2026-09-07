# M0-01 — A crashing step is a failed step, not a crashed run

**Milestone:** M0 · **Size:** S · **Depends on:** — · **Status:** ✅ Done (2026-09-07)
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

Today an exception, `exit/1`, or `throw/1` inside a module step's `execute/2` propagates out
of the executor and takes the whole run down. Verified on 2026-09-07: a parallel stage with
one shell step and one module step that raises produced an `EXIT` from the run process and
no `StepCompleted` event for either step. The same is true for a module hook that raises.

After this task, any crash inside a step or hook is caught at a single, well-defined boundary
and reported as a **failed step/hook** with the formatted exception in its output. The run
completes, sibling steps and stages finish, `allow_failure:` still applies, and the event
stream carries a `step_finished` with `status: "failed"` for the crashed step.

This is the fault-tolerance story the project tells; right now the code says the opposite.

## Why now

Every later milestone (server, UI, runners) executes user code in long-lived processes. A
crash that today kills one `mix tiny_ci.run` invocation would tomorrow kill a `Run` GenServer
and lose its history. Fix it at the runner level once so nothing above has to.

## In scope

1. `TinyCI.Executor.Driver.Inline.invoke/3` catches `rescue`/`catch` and returns
   `{:error, {:crashed, formatted}}`.
2. A single rescue boundary around one step's execution in `TinyCI.Executor` so shell-step
   plumbing crashes (cache restore, artifact copy, port errors) are also contained.
3. A rescue boundary around one stage's body so a crash outside any step (e.g. in a
   `when:` evaluation) yields a failed `StageResult` and a `stage_finished` event.
4. The three fan-out points stop *linking* worker tasks to the caller, so a crash that
   somehow escapes the boundaries above still cannot kill the run:
   `execute_parallel/5`, `spawn_dag_stage/6`, `execute_matrix_stage/4`.
5. `TinyCI.Hooks` catches crashes in module hooks the same way.
6. Tests for every path listed under **TDD plan**.

## Out of scope

- Changing the `StepResult` or event schema. A crash is `status: :failed`; the exception text
  goes in `output`. (A dedicated `crashed` status is a later decision, not this task.)
- The sandbox driver (`TinyCI.Sandbox.Runner` already rescues).
- Timeouts (T21 handled those).

## Read first

- `lib/tiny_ci/executor/driver/inline.ex` — `invoke/3` is the only place first-party actions run.
- `lib/tiny_ci/executor.ex` — `execute_step_or_skip/6`, `run_step/5`, `execute_parallel/5`,
  `spawn_dag_stage/6`, `run_dag_stages/5`, `execute_matrix_stage/4`, `do_execute/4`,
  `interpret_outcome/1`, `driver_error_message/1`.
- `lib/tiny_ci/hooks.ex` — `apply(module, :run, [config, context])` near line 90.
- `lib/tiny_ci/step_result.ex`, `lib/tiny_ci/stage_result.ex`, `lib/tiny_ci/matrix_run_result.ex`.
- `test/tiny_ci/executor_test.exs` — the style used for executor tests, and the
  "leaves no orphaned OS processes" test for the pgrep pattern.
- `test/tiny_ci/executor/driver_test.exs` — driver test style and the `LocalBackend` trick.
- `test/support/sandbox_fixtures.ex` — `Boom` already raises `"kaboom"`; reuse it.
- `test/tiny_ci/events/dispatcher_test.exs` — `ForwardSink` forwards events to a pid; copy it
  into `test/support/` as `TinyCI.TestSink` if you need it from more than one test file.

## Design

### Formatting a crash

Add a private helper (module `TinyCI.Executor.Crash`, `lib/tiny_ci/executor/crash.ex`) with:

```elixir
@spec format(kind :: :error | :exit | :throw, reason :: term(), Exception.stacktrace()) :: String.t()
```

returning `"Step crashed: " <> Exception.format(kind, reason, stacktrace)`. For `:error` kinds
pass `Exception.normalize(:error, reason, stacktrace)` so the message reads
`** (RuntimeError) kaboom`. Keep the stack trace: it is the only clue the author gets.

### Inline driver

```elixir
defp invoke(module, config, context) do
  case apply(module, :execute, [config, context]) do
    ...existing clauses...
  end
rescue
  e -> {:error, {:crashed, Crash.format(:error, e, __STACKTRACE__)}}
catch
  kind, reason -> {:error, {:crashed, Crash.format(kind, reason, __STACKTRACE__)}}
end
```

`driver_error_message/1` in the executor gets a clause
`defp driver_error_message({:crashed, text}) when is_binary(text), do: text`.

### Step boundary

Rename the body of `execute_step_or_skip/6`'s non-skipped branch into
`run_step_guarded/6`:

```elixir
defp run_step_guarded(step, ctx, output_mode, prefix, working_dir, listener) do
  run_step_with_control(step, ctx, output_mode, prefix, working_dir, listener)
rescue
  e -> crashed_step(ctx, step, Crash.format(:error, e, __STACKTRACE__))
catch
  kind, reason -> crashed_step(ctx, step, Crash.format(kind, reason, __STACKTRACE__))
end

defp crashed_step(ctx, step, text) do
  finish_step(ctx, step, %StepResult{
    name: step.name, status: :failed, output: text, duration_ms: 0,
    allowed_failure: step.allow_failure
  })
end
```

`finish_step/3` already emits `StepOutputLine`s and `StepCompleted`. Note that `allowed_failure`
on `StepResult` means "failed *and* allowed", so set it from `step.allow_failure` only in this
failed path (mirror what `run_step/5` does: `allow_failure and status == :failed`).

**Do not** put the `rescue` around `Control.checkpoint/2`'s blocking wait in a way that
changes its semantics: the checkpoint is inside `run_step_with_control`, which is fine — a
crash while paused is not a real scenario, and a `:retry` from control re-enters
`review_step/7` inside the guarded region.

### Stage boundary

In `do_execute/4`, wrap `run_stage_with_control/4` so a crash yields
`%StageResult{name: stage.name, status: :failed, step_results: [], duration_ms: 0, store: context.store}`
and still emits `StageCompleted{status: :failed}`. Log the formatted crash with
`Logger.error/1` (the stage has no output field to carry it). This path should be nearly
unreachable once the step boundary exists; it is defense in depth.

### Unlinked fan-out

- `execute_parallel/5`: `Task.Supervisor.async_nolink/2` + `Task.yield_many(tasks, timeout: :infinity)`.
  Map each `{task, {:ok, result}}` to `result`; `{task, {:exit, reason}}` to a failed
  `StepResult` built with `Crash.format(:exit, reason, [])` for the step at that index
  (zip `steps` with `tasks`). `yield_many` with `:infinity` never returns `nil` entries.
- `run_dag_stages/5`: same pattern; an exit maps to a failed `StageResult` for that stage.
- `execute_matrix_stage/4`: `Task.Supervisor.async_stream_nolink/4` with
  `zip_input_on_exit: true`; `{:exit, {combination, reason}}` maps to a failed
  `MatrixRunResult{combination: combination, status: :failed, step_results: [], store: %{}}`.

Keep `Process.group_leader/2` assignments exactly as they are; streaming output depends on them.

### Hooks

Wrap the `apply(module, :run, ...)` in `TinyCI.Hooks` with the same rescue/catch and route
the result through the existing "hook failed" stderr path. Hooks already do not affect exit
codes; the point is that a raising hook no longer aborts the remaining hooks or the process.

## TDD plan

Write each test first, run it, watch it fail, then implement the smallest change.

1. **`test/tiny_ci/executor/crash_test.exs`** — `describe "format/3"`:
   `format(:error, %RuntimeError{message: "kaboom"}, [])` starts with
   `"Step crashed: ** (RuntimeError) kaboom"`; `format(:exit, :shutdown, [])` contains
   `"(exit) shutdown"`; `format(:throw, :ball, [])` contains `"(throw) :ball"`.
   → create `TinyCI.Executor.Crash`.
2. **`test/tiny_ci/executor/driver_test.exs`** — new `describe "Inline.run/4 crash handling"`:
   - `Inline.run(Boom, %{}, ctx(root_app: :tiny_ci), [])` returns
     `{:error, {:crashed, text}}` with `text =~ "kaboom"` and `text =~ "Boom.execute/2"`.
   - Add fixtures `Exits` (`exit(:kaboom)`) and `Throws` (`throw(:ball)`) to
     `test/support/sandbox_fixtures.ex`; assert both return `{:error, {:crashed, _}}`.
   → implement the driver rescue.
3. **`test/tiny_ci/executor_test.exs`** — new `describe "crash isolation"`:
   - *parallel*: stage `mode: :parallel` with `%Step{name: :ok, cmd: "echo fine"}` and
     `%Step{name: :boom, module: TinyCI.SandboxFixtures.Boom}`; `run_pipeline/3` with
     `listener: TinyCI.Listener.Silent, output: :buffered` returns
     `{:error, {:stage_failed, :s, :failed}, [%StageResult{step_results: results}]}`;
     the `:ok` result is `:passed`, the `:boom` result is `:failed` with `output =~ "kaboom"`.
   - *serial*: same steps with `mode: :serial`, `boom` first: `boom` failed, `ok` **not run**
     (fail-fast preserved), stage failed.
   - *allow_failure*: `boom` with `allow_failure: true` → stage `:passed`,
     `allowed_failure: true` on the step result.
   - *matrix*: `matrix: [v: ["a", "b"]]`, step is `Boom` only when `v == "a"` — use a fixture
     `BoomIf` that raises when `ctx.store.v == "a"`; assert one `MatrixRunResult` failed with
     the message and one passed.
   - *dag*: two independent stages, one containing `Boom`; the other stage's result is
     `:passed`; pipeline is `{:error, {:stage_failed, ...}, results}` with both results present.
   - *events*: run the parallel case with `extra_sinks: [{TinyCI.TestSink, pid: self()}]` and
     `assert_receive {:event, %StepCompleted{step: :boom, status: :failed}}` and a
     `%PipelineCompleted{status: :failed}`.
   - *no error log*: wrap the parallel case in `ExUnit.CaptureLog.capture_log/1` and assert the
     log does **not** contain `"Task #PID"` — proves the crash was caught, not just survived.
   → implement the step boundary, then the unlinked fan-out.
4. **`test/tiny_ci/executor_test.exs`** — "a crash outside any step fails the stage":
   construct a stage whose `when_condition` is `fn _ -> raise "cond boom" end`; assert the
   `StageResult` is `:failed` and a `StageCompleted{status: :failed}` event is received.
   → implement the stage boundary.
5. **`test/tiny_ci/hooks_test.exs`** — "a raising module hook is reported and the next hook
   still runs": two hooks, first with a module whose `run/2` raises, second a `cmd: "echo ok"`
   hook; capture stderr contains the exception message; the second hook's output appears.
   → implement the hooks rescue.
6. Run the full suite. Then run `mix tiny_ci.run` at the repo root to confirm the dogfood
   pipeline is unchanged.

## Acceptance criteria

- [x] A module step that raises, exits, or throws produces a `StepResult{status: :failed}` whose
      `output` starts with `"Step crashed: "` and includes the exception and stack trace.
      — `driver_test.exs` "Inline.run/4 crash handling" (raise/exit/throw);
      `executor_test.exs` "a raising module step fails only itself in a parallel stage".
- [x] In a parallel stage, sibling steps complete and report their own results.
      — `executor_test.exs` "a raising module step fails only itself in a parallel stage".
- [x] In a serial stage, fail-fast behaviour is unchanged (later steps are not run).
      — `executor_test.exs` "a raising module step keeps fail-fast in a serial stage".
- [x] `allow_failure: true` on a crashing step lets the stage pass.
      — `executor_test.exs` "allow_failure: true lets the stage pass a crashing step".
- [x] A crashing matrix combination fails only that combination.
      — `executor_test.exs` "a crashing matrix combination fails only that combination".
- [x] A crashing stage in a DAG level does not prevent independent stages from finishing.
      — `executor_test.exs` "a crashing stage in a DAG level does not stop independent stages".
- [x] `step_finished` and `run_finished` events are emitted for a run containing a crash.
      — `executor_test.exs` "step_finished and run_finished events are emitted for a crashed step".
- [x] No `Task ... terminating` error is logged for a caught crash.
      — `executor_test.exs` "a caught crash logs no task termination" and
      "a crash in step plumbing outside the driver is a failed step".
- [x] A raising module hook does not stop subsequent hooks and does not change the exit code.
      — `hooks_test.exs` "a raising module hook is reported and the next hook still runs".
- [x] `docs/actions.md` gains a short "What happens when an action crashes" paragraph.

## Pitfalls

- `Task.yield_many/2` takes `timeout: :infinity` as a keyword (Elixir ≥ 1.15). Do not pass a
  bare `:infinity` as the second argument; that form is deprecated.
- `async_stream_nolink` results for exits are `{:exit, {input, reason}}` **only** with
  `zip_input_on_exit: true`; without it you cannot tell which combination died.
- `Exception.format/3` on a `:error` kind expects a normalized exception; for an `:exit` with a
  tuple reason it produces a readable multi-line string. Test the three kinds separately.
- The console sink prints buffered step output after the stage; a long stack trace will
  appear there. That is intended.

## Docs

- `docs/actions.md`: add the crash paragraph.
- No README change required.

## Deviations

- **Stage boundary covers the `when:` check.** The design said to wrap
  `run_stage_with_control/4`, but `skip_stage?/2` (where a `when_condition` is evaluated)
  runs *before* it in `do_execute/4`, so the TDD-plan test for a raising condition could not
  pass with that placement. `run_stage_guarded/4` wraps both the skip check and the body,
  after `StageStarted` is emitted. A crash there emits `StageCompleted{status: :failed}` and
  logs the formatted crash with `Logger.error/1`.
- **`TinyCI.TestSink` lives in `test/support/test_sink.ex`** even though only
  `executor_test.exs` uses it today; the events test in the TDD plan names it by that module,
  and M0-03/M0-06 will want the same sink.
- **Extra test:** "a crash in step plumbing outside the driver is a failed step" raises from a
  step's `config_block`, which runs in `run_step/5` before the driver. It is the test that
  fails without the step boundary (the driver rescue alone makes every module-step case pass).
- **DAG test shape:** a DAG with every stage at `needs: []` runs sequentially
  (`DAG.dag_mode?/1`), which halts at the first failure by design; the test adds a third stage
  that `needs: [:fine]` so the crashing and independent stages share a DAG level.
- **Escaped exits also emit events.** The fan-out `{:exit, reason}` paths (defense in depth)
  route through the same `crashed_step/3` / `crashed_stage/3` helpers as the boundaries, so a
  `StepCompleted` / `StageCompleted` is still emitted; matrix exits log and return a failed
  `MatrixRunResult` without a `MatrixRunCompleted` (the combination's own task emits that).

## Follow-ups (record here, do not fix in this task)

_(none yet)_
