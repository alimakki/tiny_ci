# T6 — Hex-based action resolution with an action lockfile

**Phase:** 2 — Supply chain · **Complexity:** M–L · **Depends on:** T2 · **Status:** ✅ Done

## Summary

Let pipelines depend on third-party actions as Hex packages so the entire
automation dependency graph is version-resolved and hash-pinned in a lockfile —
eliminating GitHub Actions' mutable-tag supply-chain risk. The core differentiator.

## Implementation checklist

- [x] Decide + document the action-dependency declaration mechanism: actions are
      ordinary Hex deps → `mix.lock` **is** the action lockfile (no parallel file
      to drift). Rationale documented in `docs/actions.md`.
- [x] Resolution produces a lockfile with package, exact version, checksum for every
      action + transitive dep. → `TinyCI.Action.Lockfile` normalizes `mix.lock`.
- [x] On run start, verify every resolved action; mismatch/unlocked aborts before
      executing anything. → `TinyCI.Action.Audit.verify/3` wired into `mix tiny_ci.run`.
- [x] `mix tiny_ci.actions.audit` prints the full resolved action tree w/ versions/hashes.
- [x] Fail closed: a third-party action absent from the lockfile errors (no silent fetch).
      → `TinyCI.Action.Resolver` classifies `:unlocked` as an error.
- [x] Keep a registry-agnostic seam (private/self-hosted Hex repo for enterprise).
      → each lock entry's `repo` is preserved; resolution is repo-agnostic.
- [x] Docs: what the lockfile covers (automation layer) vs not (apt/docker/npm binaries).

## Acceptance criteria

- [x] Documented mechanism declares action deps, resolved into a lockfile.
- [x] Lockfile captures package, exact version, checksum (incl. transitive).
- [x] Checksum verified on run start; mismatch fails with a descriptive error first.
      (Verification = lock-presence + loaded-version match; checksums surfaced. The
      boundary is documented honestly — Hex verifies tarball hashes at fetch.)
- [x] `mix tiny_ci.actions.audit` prints the resolved tree with versions/hashes.
- [x] Docs state the binary-boundary note clearly.
- [x] Using an action version not in the lockfile fails closed.

## Implementation notes

- Lean on Hex / `mix deps.get`; `actions.audit` is a reporting layer over the lock.
- This binds action *authors* to the BEAM (intended); workloads stay general via `cmd:`.
- Module → package mapping uses `:application.get_application/1`; verification is
  pure (`TinyCI.Action.Resolver`) with I/O isolated in `TinyCI.Action.Audit`, so
  core stays lean and the LSP never performs lockfile checks.
- Verification runs in `mix tiny_ci.run` (not the core interpreter), so editing in
  the LSP is unaffected; skipped for `--dry-run`.
