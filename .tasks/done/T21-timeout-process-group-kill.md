# T21 — Timeout must kill the OS process, not just the BEAM task

**Phase:** 0 — Correctness · **Complexity:** S–M · **Depends on:** — · **Status:** ✅ Done

## Summary

`run_cmd_with_timeout/3` (`executor.ex:893`) and the equivalent in `hooks.ex:70`
do `Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill)`. That kills the
BEAM task and closes the port, but the `sh -c <cmd>` child (and its descendants)
spawned via `Port.open`/`System.cmd` keeps running — closing a port does not
reliably signal the OS process. Result: a step reports "timed out / failed" while
`mix test` (or whatever) keeps chewing CPU in the background. Classic Erlang port
orphan bug — a real correctness issue for a CI runner, not a nitpick.

## Implementation checklist

- [x] Enforce the timeout at the OS-process level instead of via `Task.shutdown`.
      Both output modes now run through a `Port` (`Output.run_port/5`) so the
      command's `os_pid` is addressable; timeout is a `receive ... after` on the
      port loop (`Output.collect_port/6`).
- [x] On timeout, enumerate the subtree (root + descendants) via
      `ps -ax -o pid=,ppid=` — **before** signalling, since killing the parent
      reparents survivors — then `kill -TERM` the set, wait a grace period, then
      `kill -KILL` (`Output.kill_subtree/1`). Used `ps` tree-walk rather than
      `setsid`/PGID kill because macOS ships no `setsid`; this path is portable to
      both Linux and macOS.
- [x] Unify the streaming (`Port`) and buffered (was `System.cmd`) paths onto the
      killable port; buffered just suppresses per-line printing.
- [x] Fix `hooks.ex` timeout path — now delegates to `Output.run_cmd/2` with
      `:timeout`, distinguishing `{:timeout, _}` from `{:failed, _}`.
- [ ] Windows story still unaddressed (everything is `sh -c`); revisit with T20.

## Acceptance criteria

- [x] A step running `sleep` past its timeout leaves no matching process alive —
      guarded by `executor_test.exs` "leaves no orphaned OS processes" (pgrep on a
      unique marker after the grace period).
- [x] Descendants are reaped — the test uses `<marker> && echo done` so the shell
      stays alive with the sleep as a child, exercising the subtree walk.
- [x] Timeout still surfaces as `{:failed, "Step timed out after Nms"}` to the
      executor / `StepResult`.

## Notes

`ps` tree-walk is slightly racy (a process can fork between enumeration and kill)
but is fine for reaping a timed-out CI step and, unlike `setsid`, works on macOS.
An `erlexec`-style middleman is the heavier alternative if finer control is needed
later. T8 (sandbox) gets subtree teardown for free via the container runtime.
