# The execution model

This page describes *where a step runs*: the seam between the executor and the
process it starts, the trust level that decides which backend may be used, and
the sessions that give the steps of a stage a shared environment.

The seam exists so the same runner can execute a pipeline on a laptop and on a
server. Mode changes defaults and policy; it never selects a different execution
code path.

## Trust belongs to the invocation

A pipeline file is controlled by whoever can open a pull request, so it cannot
declare itself trusted. There is no `trust` DSL directive. Every run carries
`ctx.trust`:

| Where the run started | Default trust |
|---|---|
| `:local` mode | `:trusted` |
| `:server` mode | `:untrusted` |

An entrypoint may set an explicit `trust:` on the context when it knows more than
the mode does — for example, a server configured to trust a particular
repository. A pull request from a fork is untrusted regardless of that setting
(M2).

A trusted run with no image uses the host backend. A trusted run with an image
uses the container backend, and an untrusted run always uses the container
backend (with the operator's default image when the pipeline names none). The
selection is `TinyCI.Execution.Policy`; an untrusted run never falls back to the
host. No runtime, or no image for an untrusted run, is an explicit error. See
[isolation.md](isolation.md).

## The backend contract

`TinyCI.Execution.Backend` is the behaviour:

```elixir
name()          # :local, :container, ...
available?()    # can this backend run on this host?
open(spec)      # {:ok, session} | {:error, reason}
exec(session, command, on_line)  # {:passed | :failed | :timeout, output}
close(session)  # :ok, idempotent
```

A backend **spawns processes and reports output lines**. It never:

- writes to stdout or the console,
- renders, prefixes, or buffers output for display,
- redacts secret values,
- decides between streaming and buffered presentation.

Those are all concerns of the layers above it. `on_line` is the only output
channel: the executor turns each line into a `step_output` event and the console
sink renders it. Event payloads are masked once in the run's dispatcher before any
sink sees them; returned results and hook stderr are masked where they are
produced.

`exec/3` owns the deadline. On timeout it must already have killed the command's
whole process tree — the shell and its descendants on the host, or the step's
process group inside a container.

## Commands and sessions

`TinyCI.Execution.Command` says what to run:

```elixir
%Command{run: {:shell, "mix test"}, env: %{}, working_dir: "app", timeout: 60_000}
%Command{run: {:argv, "bwrap", args}, timeout: 30_000}
```

A shell command is passed to `sh -c`; an argv runs literally. This is the same
semantics shell steps and sandbox launchers had before the seam. (The container
backend quotes argv elements and runs them through the image's `sh`; no host
shell is involved.)

`TinyCI.Execution.SessionSpec` says where:

```elixir
%SessionSpec{workspace: "/repo", run_id: "20261017_...", image: nil, network: true, limits: %{}}
```

- A session is opened per **stage**, per **matrix combination**, and per **shell
  hook**.
- A regular stage's session spans its body, its `after:` boundary, and any stage
  retry, so retrying keeps the toolchain and `$HOME` state the session exists to
  preserve.
- Steps in a parallel stage share their stage's session; matrix combinations do
  not share one (a retried matrix stage opens fresh sessions per combination).
- `:workspace` is the project root. A step's own `working_dir` stays on its
  command, so a container backend can map it under the mounted workspace.
- `:image`, `:network`, and `:limits` are ignored by the Local backend and
  consumed by the Container backend.

`TinyCI.Execution.with_session/3` opens the session, yields it, and closes it in
an `after` path, so a normal return, a raise, and an exit all release it.

## The Local backend

`TinyCI.Execution.Backend.Local` runs commands as direct children of the runner
through `TinyCI.Output`. `open/1` and `close/1` are no-ops. It is the default for
trusted local runs, so a pipeline keeps running on the host with zero
configuration.

The Local backend is not a sandbox. It is the host. Untrusted code must not run
on it; see [sandbox.md](sandbox.md) for module-action confinement and
[reliability.md](reliability.md) for the current boundaries.

## The parity invariant

A pipeline executed by `TinyCI.Executor` must produce the same structured
results and the same ordered event stream regardless of mode and backend. The
test `TinyCI.ExecutionParityTest` runs the same shell pipeline under `:local`
mode and under `:server` mode with an explicitly trusted invocation, then
compares normalized results and events. If it ever fails, someone has added a
mode branch to the executor.

Durations, timestamps, and run ids are naturally different and are normalized;
everything a user could observe — statuses, output, event order, event fields —
must match.

## Isolation

The container backend, `TinyCI.Execution.Policy`, `--isolate`, and the refusal of
repository module code in untrusted runs are in place; see
[isolation.md](isolation.md). A stage's `network: false` applies to its container
session; the Local backend ignores it.

## What is still missing

- **M1.5-03:** the `image:` directive and reproducible pipeline/stage images.
  The backend already consumes `SessionSpec.image`.
- **M1.5-04:** registering open sessions and OS pids with the run so cancellation
  can close them and a startup sweep can remove leaked containers.
