# M2-02 — Bare-mirror cache per repository, one workspace per run at the exact SHA

**Milestone:** M2 · **Size:** M · **Depends on:** M2-01 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M2-01 landed

## Summary

A server run must execute against a clean checkout of a specific commit, not against
whatever directory the server happens to be in. This task gives `tiny_ci_server` a
`Workspace` component: a bare mirror per repository kept fresh with `git fetch`, and a cheap
per-run working directory created from the mirror with `git clone --shared` and detached at
the requested SHA. Fetches for one repository are serialised; checkouts are concurrent.

`TinyCI.Server.Run` gains a `:preparing` phase that performs the checkout when its request
names a repository instead of a ready `root`.

## In scope

- `TinyCI.Server.Workspace` (functions) and `TinyCI.Server.Workspace.Repo` (one GenServer per
  repository, serialising mirror operations).
- `TinyCI.Server.Repo` config struct (the subset needed here: `id`, `name`, `url`,
  `default_branch`, `submodules?`).
- `RunRequest` gains `repo: %Repo{} | nil` and `sha`; `Run` prepares the workspace, passes the
  workspace path as `root`, and removes it afterwards according to a keep policy.
- Test fixtures using local bare repositories (reuse `TinyCI.GitFixtures` from core's
  `test/support` by adding `"../test/support"` to the server's test `elixirc_paths`).

## Out of scope

- Credentials management. SSH keys and git credential helpers of the server's user are used
  as-is. Injecting a token from the secrets store via `GIT_ASKPASS` is a follow-up.
- LFS.

## Read first

- `lib/tiny_ci/server/run.ex` (M2-01) — `handle_continue(:start)`.
- `test/support/git_fixtures.ex` (M0-05).
- `lib/tiny_ci/cache.ex` — `project_id/1` hashing style (repo ids use the same idea).
- git docs: `git clone --mirror`, `git fetch --prune`, `git clone --shared --no-checkout`,
  `git checkout --detach`, `git submodule update --init --recursive`.

## Design

### Layout

```
<data_dir>/repos/<repo_id>.git/                  # bare mirror
<data_dir>/workspaces/<run_id>/                  # per-run checkout (removed after the run unless kept)
```

`repo_id` = first 16 hex chars of `sha256(normalised_url)`. Normalisation (also used by
M2-04 to match webhook payloads to config): lowercase host, strip scheme, strip a trailing
`.git` and `/`, convert `git@host:owner/repo` to `host/owner/repo`.

### `TinyCI.Server.Workspace.Repo` (GenServer, via a `Registry` keyed by `repo_id`)

```elixir
ensure_mirror(repo) :: :ok | {:error, term()}    # clone --mirror if absent
fetch(repo) :: :ok | {:error, term()}            # git fetch --prune (serialised per repo)
resolve(repo, ref) :: {:ok, sha} | {:error, :unknown_ref}   # git rev-parse in the mirror
```

Fetch is a `GenServer.call` with a long timeout (`5 min`), so two triggers for the same repo
do not run two fetches at once. If the mirror is missing or corrupt (`git fsck` unnecessary;
just `rev-parse --git-dir` failing), delete and re-clone.

### `TinyCI.Server.Workspace` (functions)

```elixir
checkout(repo, sha, run_id) :: {:ok, path} | {:error, term()}
# 1. Repo.ensure_mirror; 2. Repo.fetch unless the sha already exists in the mirror
#    (`git cat-file -e <sha>^{commit}`); 3. git clone --shared --no-checkout <mirror> <path>;
# 4. git -C path checkout --detach <sha>; 5. if repo.submodules?: submodule update --init --recursive
remove(run_id) :: :ok
keep_or_remove(run_id, status, policy) :: :kept | :removed
```

Policy (config, M2-07 wires it; defaults here): `keep_failed: 5` — keep the workspaces of the
five most recent non-passed runs per repo (for M6-01 shell-on-failure), remove everything else
immediately. `prune_workspaces/1` enforces the count.

All git commands run with `GIT_TERMINAL_PROMPT=0` and `stderr_to_stdout: true`; error tuples
carry the trimmed output.

### Run integration

`RunRequest` gains `repo`, `sha`. In `Run.handle_continue(:start)`: when `repo` is present,
status `:preparing`, broadcast, `Workspace.checkout/3`; on success set `root` to the workspace
path and continue as before; on failure status `:failed` with the git output as reason. After
the run finishes (any status), `Workspace.keep_or_remove/3`.

`Context.build(root: ws, base: request.base_ref, include_dirty: false)` — the branch is passed
as an override (`branch: request.branch`) because a detached checkout reports `HEAD`.

## TDD plan

1. **`test/tiny_ci/server/workspace/repo_test.exs`** — `ensure_mirror/1` on a fixture bare repo
   creates `<data_dir>/repos/<id>.git`; `fetch/1` after a new commit in the origin makes
   `resolve/2` return the new SHA; two concurrent `fetch/1` calls both return `:ok` and only one
   `git fetch` runs at a time (assert by wrapping `System.cmd` behind a small `Git` module with
   an injectable runner that records concurrency — or simpler: assert the second call blocks
   until the first returns using message ordering). → implement.
2. **`test/tiny_ci/server/workspace_test.exs`** — `checkout/3` yields a directory whose
   `git rev-parse HEAD` is the SHA and which contains the committed files; an unknown SHA
   errors; two concurrent checkouts of different SHAs of the same repo both succeed;
   `remove/1` deletes; `keep_or_remove/3` keeps failed within the limit and prunes the oldest.
   → implement.
3. **`test/tiny_ci/server/run_test.exs`** — a request with `repo` + `sha` (fixture origin
   containing a `tiny_ci.exs` with an `echo` step) goes `:preparing` → `:running` → `:passed`,
   the run's `root` was under `workspaces/`, and the workspace is gone afterwards; a failing
   pipeline's workspace is kept. → integrate.
4. Suites, credo, dogfood.

## Acceptance criteria

- [ ] Mirrors are created once and fetched serially per repository.
- [ ] A checkout is detached at exactly the requested SHA and independent of other runs.
- [ ] Concurrent checkouts of one repository work.
- [ ] Workspaces are removed after passing runs and kept (bounded) after failures.
- [ ] Git failures surface as run failures with the git output, never as crashes.

## Pitfalls

- `git clone --shared` makes the clone depend on the mirror's objects; never delete the mirror
  while a workspace exists. `remove/1` before re-cloning a corrupt mirror.
- `git fetch --prune` on a `--mirror` clone updates `refs/heads/*` directly (no `origin/`
  prefix). `resolve/2` with a branch name works; with `origin/main` it does not.
- Detached checkouts: `Context.branch/1` returns `"HEAD"`. Pass the branch explicitly.

## Docs

- `docs/server.md`: "Repositories and workspaces" section: layout, keep policy, credential
  expectations.

## Follow-ups

- Token injection via `GIT_ASKPASS` from the secrets store.
