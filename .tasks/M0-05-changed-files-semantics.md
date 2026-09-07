# M0-05 — `file_changed?` against a base ref plus the dirty tree; git runs in `root`

**Milestone:** M0 · **Size:** S–M · **Depends on:** — · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

`TinyCI.Context.changed_files/0` runs `git diff --name-only HEAD~1`. That is the wrong
question for every real use:

- Locally, the author cares about **uncommitted** edits and about everything on the branch
  **since it diverged from its base**, not the last commit alone.
- On a server (M2), the runner cares about the diff between the pushed SHA and the PR's base
  branch (or the previously built SHA).
- On the initial commit `HEAD~1` does not exist, so the list is empty and every
  `file_changed?` condition is false.

Separately, `Context.build/1`, `branch/0`, `commit/0`, and `changed_files/0` run `git` in the
**current working directory**, not in the pipeline root passed via `--root`. A server that
checks a repo out into a workspace must be able to build a context for that directory.

After this task: `Context.build(root: dir, base: ref)` computes `changed_files` as the union of
(a) files changed between `merge-base(base, HEAD)` and `HEAD`, and (b) unstaged, staged, and
untracked-but-not-ignored files; the base ref is detected sensibly when not given; every git
call runs in `root`; and the resolved base is recorded on the context for `--dry-run` and M5.

## In scope

- `TinyCI.Context`: `build/1` with `root:` and `base:` options; `branch/1`, `commit/1`,
  `changed_files/2`, `detect_base/1`, all taking `root`. Arity-0 variants remain as
  `File.cwd!/0` conveniences (thin wrappers).
- New context field `base_ref` (the resolved ref or SHA, or `nil` when none could be found).
- `Mix.Tasks.TinyCi.Run`: `--base REF` flag; `TINY_CI_BASE_REF` env var; passes `root:` to
  `Context.build/1`.
- `TinyCI.DryRun`: prints the resolved base.
- `test/support/git_fixtures.ex`: helpers to build throwaway git repos in `tmp_dir`.

## Out of scope

- Changing glob semantics (`Context.any_file_matches?/2` is untouched).
- Using the trigger's base branch on the server (M5-01 wires that through; this task only
  makes `base:` an option).

## Read first

- `lib/tiny_ci/context.ex` — all of it.
- `lib/tiny_ci/dsl/condition_eval.ex` — `eval({:file_changed?, _, [glob]}, ctx)` reads
  `ctx.changed_files`.
- `lib/tiny_ci/executor.ex` — `run_pipeline/3` calls `TinyCI.Context.build/0` when no context
  is passed; find where the Mix task builds the context (`lib/mix/tasks/tiny_ci.run.ex`,
  `run_with_filter/5` and neighbours) and where `root` is put on the context.
- `lib/tiny_ci/dry_run.ex` — header lines (`Branch: ... | Commit: ...`).
- `test/tiny_ci/context_test.exs`, `test/tiny_ci/dsl/condition_eval_test.exs`.
- `test/mix/tasks/tiny_ci_run_test.exs` — how a tmp project root is created for CLI tests.

## Design

### Base detection — `Context.detect_base(root) :: String.t() | nil`

In order, return the first that resolves (`git rev-parse --verify --quiet <ref>` exits 0):

1. `System.get_env("TINY_CI_BASE_REF")` when set and non-empty.
2. `@{upstream}` (the current branch's tracking ref).
3. The remote default branch: `git symbolic-ref --quiet refs/remotes/origin/HEAD`.
4. First existing of `origin/main`, `origin/master`, `main`, `master`.
5. `HEAD~1`.
6. `nil` (initial commit with no remote): callers use the **empty tree**
   `4b825dc642cb6eb9a060e54bf8d69288fbee4904`, so every tracked file counts as changed.

One adjustment after resolution: if the resolved base commit **equals** `HEAD` (you are on
`main`, everything pushed, or you picked `main` while on `main` with no remote), fall back to
`HEAD~1` when it exists. Without this, a clean tree on the base branch would report nothing
changed and skip every `file_changed?` stage, which surprises people running the pipeline
after a push. Document this rule.

An explicit `base:` option skips detection entirely (still subject to the equals-HEAD rule).

### Changed files — `Context.changed_files(root, opts)`

```elixir
@spec changed_files(String.t(), keyword()) :: [String.t()]
# opts: base: String.t() | nil (default: detect_base(root)), include_dirty: boolean (default true)
```

Union of, each run in `root` with `-z` (NUL-separated, so paths with spaces survive):

- committed: `git diff --name-only -z <merge_base>..HEAD` where
  `merge_base = git merge-base <base> HEAD` (or the empty tree when base is `nil`);
- unstaged: `git diff --name-only -z`;
- staged: `git diff --name-only -z --cached`;
- untracked: `git ls-files --others --exclude-standard -z`.

Skip the last three when `include_dirty: false`. Split on `<<0>>`, drop blanks, `Enum.uniq/1`,
`Enum.sort/1`. Renames show as both old and new paths (`--name-only` does that already).
If `git` is missing or `root` is not a repository, return `[]` as today.

### Context

```elixir
def build(overrides \\ []) do
  root = Keyword.get(overrides, :root, File.cwd!())
  base = Keyword.get(overrides, :base) || detect_base(root)
  %__MODULE__{
    branch: branch(root), commit: commit(root),
    changed_files: changed_files(root, base: base, include_dirty: Keyword.get(overrides, :include_dirty, true)),
    base_ref: base, store: %{}, timestamp: DateTime.utc_now()
  }
  |> Map.merge(Map.new(Keyword.drop(overrides, [:base, :include_dirty])))
end
```

Add `base_ref: String.t() | nil` to the struct, `@type t`, and the "Guaranteed fields" doc.
`root` is already preserved as an extra key by `Map.merge/2`; keep it that way (do not add
`root` to the struct in this task — several modules `Map.get(ctx, :root)` and would keep
working either way, but the executor also `Map.put`s it; leave the shape alone).

All git calls: `System.cmd("git", args, cd: root, stderr_to_stdout: true)`.

### CLI and dry run

- `--base REF` → `Context.build(root: root, base: ref)`. Find the single place the Mix task
  builds the context and thread the option through `run_with_filter/5` (or wherever it lands).
- `DryRun` header: `Branch: main | Commit: b9496e7… | Base: origin/main (a1b2c3d)` where the
  parenthesised part is the short SHA of the merge base; `Base: (none — initial commit)` when nil.

## TDD plan

Tests use real git repositories in `tmp_dir`. Add `test/support/git_fixtures.ex`:

```elixir
TinyCI.GitFixtures.init_repo(dir)              # git init -b main, local user.name/email
TinyCI.GitFixtures.commit(dir, %{"path" => "content"}, msg \\ "c")  # write + add + commit, returns sha
TinyCI.GitFixtures.clone(bare_or_src, dest)    # for upstream tests
TinyCI.GitFixtures.git!(dir, args)             # System.cmd wrapper that raises on non-zero
```

`git commit` needs an identity: pass `-c user.name=t -c user.email=t@t` on every call rather
than mutating global config. These tests are `async: true`; nothing touches the cwd.

1. **`test/tiny_ci/context_test.exs`** — `describe "changed_files/2"`:
   - initial commit, no remote: returns every tracked file (empty-tree base).
   - two commits, clean tree, no remote, on `main`: returns the second commit's files only
     (HEAD~1 fallback via the equals-HEAD rule).
   - unstaged edit to a committed file: included.
   - staged new file: included.
   - untracked file: included; untracked file matching `.gitignore`: excluded.
   - `include_dirty: false`: dirty files excluded.
   - explicit `base:` pointing at the first commit on a three-commit branch: files from
     commits two and three.
   - a path with a space survives.
   - a non-repository `root`: `[]`.
   → implement `changed_files/2` and the empty-tree path.
2. **`test/tiny_ci/context_test.exs`** — `describe "detect_base/1"`:
   - clone a bare "origin" with `main`, make a feature branch with one commit: base is
     `@{upstream}`'s name or `origin/main` (assert the merge base equals origin's `main` SHA
     rather than the exact string, so either detection step passes).
   - on `main` tracking `origin/main` with one unpushed commit: `changed_files` returns that
     commit's files (merge base = origin/main).
   - `TINY_CI_BASE_REF` honoured (this one test is `async: false`, or use an explicit `env:`
     option on `detect_base/2` — prefer the option, keep `async: true`).
   → implement `detect_base/1`.
3. **`test/tiny_ci/context_test.exs`** — `describe "build/1 with root:"`: build for a tmp repo
   whose branch is `feature/x` while the test process cwd is the tiny_ci repo; `ctx.branch ==
   "feature/x"`, `ctx.base_ref` set, `ctx.root` preserved. → thread `root` through.
4. **`test/tiny_ci/dsl/condition_eval_test.exs`** — `file_changed?("lib/**")` true/false against
   a context built from a fixture repo (not a hand-written list) — one test each.
5. **`test/tiny_ci/dry_run_test.exs`** — header contains `Base:`.
6. **`test/mix/tasks/tiny_ci_run_test.exs`** — `--base` reaches the context: a pipeline with
   `stage :only_docs, when: file_changed?("docs/**")` in a fixture repo where docs changed only
   in commit 2 of 3; `--base <sha1>` runs the stage, `--base <sha2>` skips it.
7. Full suite; `mix tiny_ci.run`; `mix tiny_ci.run --dry-run` shows a `Base:` line.

## Acceptance criteria

- [ ] An uncommitted edit to `lib/foo.ex` makes `file_changed?("lib/**/*.ex")` true.
- [ ] `changed_files/2` does not raise or return `[]` on a fresh repo with one commit.
- [ ] Base ref is detected from upstream / origin default / `main` / `HEAD~1` in that order,
      overridable by `--base` and `TINY_CI_BASE_REF`, with the equals-HEAD fallback.
- [ ] Every git invocation in `Context` runs in `root`.
- [ ] `--dry-run` prints the resolved base.
- [ ] README "Conditions" documents `file_changed?` semantics precisely (base detection order,
      dirty tree inclusion, equals-HEAD rule, initial commit).

## Pitfalls

- `git diff A..B` vs `git diff A B`: both work for commits; use the two-argument form with the
  merge-base SHA to avoid ambiguity with branch names containing dots.
- `git rev-parse --abbrev-ref HEAD` returns `HEAD` in detached state (server checkouts at a SHA
  will be detached). That is acceptable for `branch/1`; M2 passes the branch explicitly via
  `overrides`.
- `--exclude-standard` is what honours `.gitignore`; without it, `_build/` shows up as changed.
- Keep `changed_files` sorted so tests are deterministic and event payloads stable.

## Docs

- README → "Conditions": rewrite the `file_changed?` row and add a short "How changed files
  are computed" subsection. Add `--base` to the flag table.

## Follow-ups

_(none yet)_
