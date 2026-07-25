# Sandboxed execution

A `module:` step runs real code. When that code is **first-party** (your own app),
a **builtin** (OTP/Elixir), or **script-local** (defined in a pipeline file), it
runs inline in the runner's BEAM — fast and unrestricted. When it is
**third-party** (shipped by a dependency), it runs inside an **OS sandbox** with
only the capabilities it declared.

This matters because *the BEAM is not a security boundary*. A module compiled
into a dependency can call NIFs, `System.cmd/3`, or open sockets with the full
authority of the runner. Isolation has to come from the operating system.

## Drivers

Every module step is dispatched through a `TinyCI.Executor.Driver`:

| Driver | Runs where | Used for |
|--------|-----------|----------|
| `Driver.Inline` | the runner's BEAM | first-party / builtin / local code |
| `Driver.Sandbox` | an OS sandbox | third-party (dependency) code |

Selection is automatic (`TinyCI.Sandbox.Trust` classifies the module by its
owning OTP application), and it **fails closed**:

- `Inline` **refuses** a third-party module — it will not run untrusted code
  unsandboxed, even if asked to.
- `Sandbox` **refuses** to run if no OS backend is available, rather than
  silently falling back to inline.

A run can override selection through the `:sandbox` context key
(`driver: :inline | :sandbox | :auto`), but the default is `:auto`.

## Capabilities → policy

An action declares what it needs in its `TinyCI.Action.Metadata`:

```elixir
def metadata do
  %TinyCI.Action.Metadata{
    name: "acme.deploy",
    version: "1.0.0",
    capabilities: [:network, :filesystem_write, :env_read]
  }
end
```

`TinyCI.Sandbox.Policy` turns those declarations, intersected with the run's
concrete **grants**, into an OS-enforceable policy. It is **deny-by-default**: a
grant only takes effect if the matching capability is declared, and an
undeclared capability grants nothing.

| Capability | Grant | Effect |
|------------|-------|--------|
| `:network` | — | outbound sockets allowed |
| `:filesystem_read` | `read_paths:` | those paths readable |
| `:filesystem_write` | `write_paths:` | those paths writable (and readable) |
| `:env_read` | `env:` | those env vars visible |
| `:process_spawn` | — | may spawn OS processes |

## What crosses the boundary

The action runs in a **separate OS process**, so nothing is shared but bytes
(`TinyCI.Sandbox.Protocol`, External Term Format):

- **In:** the step's config and a *sanitized* context — only the documented
  action-facing fields (`branch`, `commit`, `changed_files`, `store`,
  `timestamp`, and the granted `env`). Executor handles (`:events`, `:run_id`, …)
  never leave the runner.
- **Out:** `{:ok, store_delta}` or `{:error, reason}`, merged into the pipeline
  store exactly as an inline step's result would be.

The protocol refuses to encode a request containing a PID, reference, port, or
function, and decodes the untrusted response with the `:safe` flag. Any granted
secret values are masked (`TinyCI.Sandbox.Redaction`) before the result reaches
the event stream or the console.

## Backends

The OS mechanism is pluggable behind `TinyCI.Sandbox.Backend`:

- **`Backend.Seatbelt`** (macOS, reference implementation) — confines a child
  BEAM with `sandbox-exec`. The child is launched with `env -i`, so it inherits
  **no** environment except a minimal runtime base and the granted vars: an
  ungranted secret is simply *absent*, not merely hidden. The kernel enforces
  the generated `TinyCI.Sandbox.Profile`, so network, filesystem, and native
  bypass attempts are all caught.
- An **OCI-container** backend for Linux/CI fits the same one-function contract
  (`run/3`) and shares the protocol — the same envelope the future orchestrator/
  runner split (T16) sends over the wire.

### Seatbelt profile (v1)

Fully denying reads is impractical for a BEAM (it must read the runtime and
every `.beam`), so v1 enforces a targeted, kernel-backed policy:

- **network** denied unless `:network` is declared;
- **writes** denied by default, allowed only under the sandbox scratch dir, the
  temp locations the runtime needs, and explicitly granted paths;
- **explicit read denials** for any path the run marks secret.

Because Seatbelt confines a process *and all its descendants*, these controls
hold for native code too — a NIF or a `System.cmd/3` subprocess that tries to
open a socket or write outside the grant is blocked exactly as BEAM code is.
This is verified by the enforcement tests in
[`test/tiny_ci/sandbox/seatbelt_test.exs`](../test/tiny_ci/sandbox/seatbelt_test.exs),
including a native-subprocess escape attempt that fails to break out.

## Scope

The sandbox covers the **BEAM automation layer** — the action's own code and the
processes it spawns. It is not a substitute for pinning the binaries an action
pulls (Docker images, apt/npm packages); pin those with their own ecosystems and
the [action lockfile](./actions.md).
