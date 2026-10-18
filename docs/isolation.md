# Isolation and untrusted runs

TinyCI has two independent isolation layers:

- **Module actions in trusted runs** run under an OS sandbox when they come from
  a dependency ([sandbox.md](sandbox.md)).
- **Untrusted runs** — a server run, or a local run started with `--isolate` —
  execute every shell step and shell hook in a container and refuse repository
  module code entirely.

This page describes the second layer. The execution seam and trust defaults are
in [execution-model.md](execution-model.md).

## Trust belongs to the invocation

A pipeline file is exactly what an untrusted pull request controls, so it cannot
declare itself trusted. There is no `trust` directive. The entrypoint sets
`ctx.trust`:

| Invocation | Default trust |
|---|---|
| `tiny_ci run` / `mix tiny_ci.run` in `:local` mode | `:trusted` |
| `tiny_ci run --isolate` | `:untrusted` |
| a server run (M2) | `:untrusted`, unless the server explicitly trusts the repository |

A trusted local run with no image keeps running on the host, exactly as before.
`--isolate` is the local way to reproduce a server run or to try a stranger's
branch.

## What an untrusted run guarantees

Before any stage starts:

1. Every `module:` step and hook is classified. Only `:builtin` actions — code
   shipped with OTP/Elixir, not the repository or a dependency — may run. Any
   other module action fails the run with a message naming the step/hook.
2. Pipeline loading does **not** load repository modules. Classification runs
   without `Code.ensure_loaded/1`, so `@on_load` code cannot execute on the host.
3. `mix.lock` is parsed as data, never evaluated.

While it runs:

- Every shell step and shell hook runs in a container, never on the host.
- A stage gets one long-lived container. Steps in the stage share `$HOME`,
  installed tools, and the container filesystem. Matrix combinations and each
  hook phase get their own.
- Only the workspace is bind-mounted (read-write at `/workspace`; `.git` is a
  nested read-only mount when present). The host environment is not passed
  through to steps; each step receives only its resolved pipeline/stage/step
  environment and declared secrets. In an untrusted run, `when: env("NAME")` is
  limited to that resolved environment too and does not fall back to the host
  process environment.
- `network: false` on a stage runs its container with `--network=none`.
- A timeout kills the step's process group inside the container, leaving sibling
  steps in the same stage alone. If the process group was never recorded (for
  example a deadline shorter than container startup), the stage session is
  removed instead, which also ends any sibling steps; this is the fail-closed
  tradeoff. `close/1` removes the container on every exit path.

With no usable runtime, or with an untrusted run that has no image and no
operator default, the run fails closed. There is no silent fallback to the host.

## Operator configuration

```elixir
config :tiny_ci,
  default_image: "ghcr.io/acme/ci:24.04",
  container_runtime: :auto,          # :auto | :docker | :podman
  container_limits: %{memory: "2g", cpus: 2, pids: 512}
```

- `:default_image` has no built-in default; an untrusted run requires it until
  the `image:` directive lands (M1.5-03).
- `:auto` tries Docker, then Podman.
- Limits are applied to the stage container with `--memory`, `--cpus`, and
  `--pids-limit`.

The image must provide a POSIX `sh`, `setsid`, `sleep`, `cat`, and `rm`. `open/1`
probes for them and fails with a clear error; distroless images are not
supported as-is.

## Running rootless

Rootless Podman or Docker is recommended. Docker runs containers with
`--user <host uid>:<host gid>` so files written into `/workspace` remain owned by
the invoking user; rootless Docker omits `--user` and relies on its mapping of
container root to the invoking user. Rootless Podman uses `--userns=keep-id` and
a `:Z` SELinux label on the workspace mount; the container uid is the host uid.
Docker Desktop and rootful Docker may behave differently for ownership and
cgroup limits.

## What is not protected

A container is not a virtual machine. M1.5 does **not** provide:

- **Egress filtering.** The network is on by default (stages need to fetch
  dependencies). An untrusted step can reach anything the container network can.
  `network: false` is all-or-nothing.
- **Secret exfiltration protection.** Declared secrets are injected into the
  step that needs them. Do not give an untrusted run secrets you would not give
  the pull request author. The untrusted-server rule that resolves no secrets is
  M2-06.
- **Also on `mix tiny_ci.run`:** the Mix entrypoint has already loaded the
  project (`mix.exs` and its dependencies) before the task runs, so
  `mix tiny_ci.run --isolate` isolates *pipeline steps* but cannot protect you
  from a hostile `mix.exs`. Use the `tiny_ci` escript for a truly untrusted
  checkout; the Mix task prints a warning when `--isolate` is used.
- **Workspace contents.** The whole workspace is mounted, including any
  gitignored files such as `.tiny_ci/secrets` in a local checkout. The `.git`
  directory or file is mounted read-only so a step cannot rewrite host git
  configuration or hooks; it remains readable, so a sanitized checkout should not
  contain credentials in `.git/config`. In an untrusted run, a symlinked
  `.tiny_ci/secrets` file or parent directory is refused when it resolves outside
  the project root rather than followed to a host file. Context git commands also
  disable `core.fsmonitor`, `core.hooksPath`, and `diff.external` so repository
  config cannot name a host program.
- **Untrusted runs do not use the dependency cache.** Cache restore/save are
  host-side file operations driven by repository paths; an untrusted run skips
  them. Artifacts are skipped too: artifact validation and copy are separate
  host-side operations, so a step could race a symlink swap. A symlinked working
  directory that escapes the project root is refused as well.
- **Resource-exhaustion protection beyond the configured limits.** Kernel
  container escapes are out of scope. Use a VM or a dedicated runner if the
  threat model includes the kernel.
- **Deliberate session escapes.** Timeouts kill the step's process group and its
  descendants. A step that deliberately creates a new session with `setsid` can
  escape that group until the stage session is removed; M1.5-04's run
  cancellation closes every session of a cancelled run.
- **Windows isolation** and remote/Kubernetes execution.
- **A wedged container runtime.** Lifecycle commands (`run`, `exec`, `cp`,
  `rm`, `inspect`) assume the Docker/Podman daemon responds. Cancellation and a
  bounded lifecycle deadline land with M1.5-04; until then a stuck daemon can
  block a stage.

Cancellation is cooperative until M1.5-04. `close/1` removes the stage container
on normal, failed, and timed-out runs; a runner crash can leave a labelled
container for the M1.5-04 startup sweep (`docker ps --filter label=tiny_ci.run_id`).
