# T8 — Sandboxed execution for module/third-party actions

**Phase:** 2 — Supply chain · **Complexity:** L–XL · **Depends on:** T2 · **Status:** ✅ Done

## Summary

Run third-party module steps inside an OS-level sandbox with only their declared
capabilities, so a malicious/compromised action cannot read secrets, touch the
filesystem, or reach the network unless explicitly permitted. The BEAM is not a
security boundary (NIFs, `System.cmd`, sockets) — isolation must come from the OS.

## Implementation checklist

- [x] `TinyCI.Executor.Driver` behaviour with `:inline` (today's, first-party only)
      and `:sandbox` implementations. (`Driver` + `Driver.Inline` + `Driver.Sandbox`,
      wired at the executor's module-step seam; `Driver.select/2` auto-routes by trust.)
- [x] Sandbox driver runs an action in an isolated environment (ephemeral container
      / microVM), passing config+context in, receiving result+store-delta out over a
      serialized protocol (no shared PIDs/handles). (v1 backend: macOS Seatbelt child
      BEAM; `Sandbox.Protocol` is the ETF envelope.)
- [x] Capability enforcement (network / filesystem / env) from T2 metadata.
      (`Sandbox.Policy.from_metadata/2` → `Sandbox.Profile` Seatbelt rules + `env -i`.)
- [x] Secret redaction at the sandbox event/output boundary (T1).
      (`Sandbox.Redaction.redact/2`, applied to the delta/error before returning.)
- [x] Refuse third-party (non-first-party) actions under the `:inline` driver
      (enforce invariant #4). (`Driver.Inline` returns `{:untrusted_action, module}`.)
- [x] Escape-attempt test fixture (NIF/native) that must fail to break out.
      (Native `/usr/bin/touch` subprocess escape + `:gen_tcp`/`File` native-driver
      probes, all blocked by Seatbelt — descendants are confined.)

## Acceptance criteria

- [x] `Driver` behaviour exists with `:inline` and `:sandbox` implementations.
- [x] Sandboxed action receives only granted env/secrets + granted working-tree paths;
      attempts beyond declared capabilities are denied. (Verified live under Seatbelt:
      network deny/allow, write deny/allow, env allowlisting.)
- [x] A NIF/native escape-attempt fixture cannot break out.
- [x] Config/context cross the boundary via serialization (no shared PIDs/handles).
      (`Protocol` rejects PIDs/refs/ports/funs; context sanitized to action-facing keys.)
- [x] Result + store-delta returned and merged identically to inline.
- [x] Third-party actions refused under `:inline` with a clear error.

## Implementation notes

- **Backend chosen for v1:** macOS **Seatbelt** (`sandbox-exec`) — daemonless and
  actually exercised in CI on macOS; OCI-container backend fits the same
  `Backend` behaviour (`available?/0` + `run/3`) for Linux/prod. Containers/microVMs
  remain the future path; the `Backend` seam makes them additive.
- **Seatbelt profile is targeted, not deny-default reads** (a BEAM must read the
  runtime + every `.beam`): deny network unless declared; deny writes by default
  and allow scratch/temp/granted; explicit read-denies for secret paths. Env
  isolation is achieved by launching the child with `env -i` + only granted vars.
- **Trust classification** (`Sandbox.Trust`) reuses `Action.Resolver.builtin?/1`
  (single source for the builtin allowlist). first_party/builtin/local → inline;
  third_party → sandbox. Fails closed both ways.
- **The serialization protocol here is the same one T16 sends over the wire** —
  `Sandbox.Protocol` (ETF; `:safe` on the untrusted response decode). Request is
  trusted (carries the module atom pre-load), response is untrusted.
- **Runner** (`Sandbox.Runner`) is the in-sandbox entrypoint; the Seatbelt backend
  starts `elixir -pa <code paths> -e "TinyCI.Sandbox.Runner.cli()"` reading
  request/response paths from env. Child PATH must include both `elixir` and the
  OTP `bin` (from `:code.root_dir()`), since `env -i` clears it.
- Tests: pure modules + a `LocalBackend` (real Runner, no OS) exercise the glue
  unsandboxed; `test/.../seatbelt_test.exs` (`@moduletag :seatbelt`, `setup_all`
  skip when unavailable) proves real kernel enforcement. Docs: `docs/sandbox.md`.
- **Deferred:** container backend impl, `:process_spawn`/finer syscall policy,
  microVMs. The `Driver`/`Backend`/`Policy`/`Protocol` seams are stable for these.
