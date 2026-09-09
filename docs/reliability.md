# Reliability and trust

TinyCI currently targets trusted local repositories and dependencies. It is not
yet a safe multi-tenant runner or a complete unattended deployment control plane.

## Execution contracts

- Mix task failures raise `Mix.Error`, producing a nonzero CLI exit even under
  `MIX_ENV=test`. Programmatic callers should use the executor's result tuples.
- Managed JSON and NDJSON stdout are separate modes. Hooks and filter warnings
  use stderr; JSON preserves aborted status and reports elapsed wall time.
- The project root is the default shell working directory. Relative overrides
  are anchored there, not to the `.tiny_ci` directory.
- Parallel stage and matrix stores merge explicit writes, not inherited
  snapshots. Conflicting explicit writes retain declaration-order precedence.
- Inline module deadlines stop the callback task. Sandbox deadlines terminate
  the managed executable's OS subtree and clean up its scratch directory.
- Ordinary module IO is captured before redaction. This does not intercept named
  devices, arbitrary Logger output, module loading, or independent processes.
- Cache identity includes execution inputs as well as the nominated key file.
  Lookup and restore share a lock; module actions still run after a cache restore.
- Run IDs have random suffixes. Matrix artifact destinations are distinct;
  artifact copying rejects path traversal, escaping symlinks, and cycles.

## Remaining boundaries

These are follow-ups, not guarantees provided by this hardening pass:

- **Whole-run isolation:** shell commands execute on the host. Dependencies can
  run code while compiling/loading; action metadata still executes before OS
  confinement. Sandbox reads are broadly allowed. Do not execute untrusted PRs
  or action packages without isolating the entire runner externally.
- **Process ownership:** breakpoint abort remains cooperative. A callback task's
  termination does not kill arbitrary independently spawned BEAM or OS processes.
  Shell/backend timeout cleanup takes a process-tree snapshot, not a cgroup lease.
- **Secret scope:** secrets resolve at run start and are broadly injected. Stage
  scoping, approval-gated access, and comprehensive Logger/device interception
  remain separate work.
- **History and events:** M0-06 is still pending. Output events arrive after step
  completion, retry logs are not complete, ordinary step events lack matrix
  identity, and hooks are outside the executor event stream. Correct these before
  relying on a persisted stream for full reconstruction.
- **Workspace and scheduling:** stages still switch to DAG mode when `needs:` is
  used, DAG execution has level barriers, and matrix combinations share mutable
  workspaces. No global resource cap or hard run cancellation exists yet.
- **Cache lifecycle:** the key is not a complete source/dependency graph. Lock
  stealing is age-based, and `cache clean` must not run concurrently with builds.
- **Artifact races:** pre-copy path checks are defense in depth for a trusted
  workspace, not protection against a concurrent adversary swapping symlinks.
  Publication is not yet atomic.
- **Provenance:** signing currently rereads source/action identity after execution.
  Capture immutable inputs at run start before treating attestations as a complete
  account of exactly what ran.

The existing roadmap covers durable history, standalone packaging, isolated
checkouts, scheduling, and forge integration. Language redesign, readiness-based
DAG scheduling, reusable pipeline fragments, and full sandbox hardening should
have their own explicit contracts and regression suites.
