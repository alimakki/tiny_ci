# M0-04 — Cache: atomic writes, cross-process locking, eviction

**Milestone:** M0 · **Size:** M · **Depends on:** — · **Status:** ✅ Done (2026-09-08)
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

`TinyCI.Cache.save/4` and `restore/4` do `File.rm_rf!` followed by a recursive copy, with no
lock and no atomic publish. Two runs sharing a key (matrix combinations and DAG stages make
this the normal case, and M2 adds concurrent server runs) can interleave and leave an entry
that is half one run's `deps/` and half another's. An interrupted save leaves a partial entry
that the next run treats as a hit. The cache also grows forever.

After this task: an entry is either complete or absent (staging directory + atomic rename);
concurrent savers and restorers of the same key serialise on a filesystem lock that works
across OS processes; copies use filesystem cloning where available (`cp -c` on APFS,
`--reflink=auto` on Linux) and fall back to a plain copy; and the cache is pruned by size and
age, on demand and after every save.

## In scope

- `TinyCI.Cache` save/restore rewritten around staging + rename, with per-entry metadata.
- New `TinyCI.Cache.Lock` (mkdir-based advisory lock with stale detection).
- New `TinyCI.Cache.Copy` (clone-aware directory copy).
- New `TinyCI.Cache.prune/1` and `stats/0`; `mix tiny_ci.cache prune|stats`.
- Automatic prune after a successful save.
- Concurrency and atomicity tests.

## Out of scope

- Remote/shared caches (M4 revisits when runners exist).
- Changing the cache key scheme (`SHA256` of one key file). The `cache:` DSL option is unchanged.
- Hardlinking. **Deliberately rejected:** a hardlinked file shares its inode with the working
  tree, so a later in-place write in either location silently corrupts the other. Cloning
  (reflink) gives the speed without the aliasing.

## Read first

- `lib/tiny_ci/cache.ex` — all of it (it is short): `base_dir/0`, `project_id/1`,
  `compute_key/1`, `cache_entry_dir/2`, `hit?/3`, `restore/4`, `save/4`, `clean/1`, `copy_path/2`.
- `lib/tiny_ci/executor.ex` — `execute_with_cache/6` and `run_cached/7` (the only callers).
- `lib/mix/tasks/tiny_ci.cache.ex` — the existing `clean` task.
- `test/tiny_ci/cache_test.exs` — how tests point `base_dir/0` at a temp directory today
  (application env `:tiny_ci, :cache_base_dir`); keep that mechanism, and keep those tests
  `async: false` if they already are (application env is global).
- `test/tiny_ci/executor_test.exs` — cache hit/miss tests.

## Design

### Layout

```
<base_dir>/<project_id>/<key>/            # a committed entry (only ever appears by rename)
<base_dir>/<project_id>/<key>/.meta.json  # {"saved_at": iso8601, "last_used_at": iso8601, "paths": [...], "bytes": N}
<base_dir>/<project_id>/<key>/<path>...   # the cached paths, as today
<base_dir>/<project_id>/.tmp/<key>-<unique>/   # staging directory for a save in progress
<base_dir>/<project_id>/.lock/<key>/       # lock directory (exists = held); contains "owner"
```

`.tmp` and `.lock` are siblings of entries, on the same filesystem, so `File.rename/2` between
`.tmp/...` and `<key>` is atomic.

### Save

```
with_lock(key) do
  stage = .tmp/<key>-<unique>
  copy each path into stage (Copy.copy_tree/2)
  write stage/.meta.json (saved_at = last_used_at = now, bytes = du of stage)
  if entry exists: rename entry -> .tmp/<key>-old-<unique>
  rename stage -> entry
  rm_rf the old dir (outside the critical path is fine, but inside the lock is simpler)
end
prune(default limits)
```

If anything raises before the final rename, the stage dir is left under `.tmp/` and the entry
(old or absent) is untouched. `prune/1` removes `.tmp/*` older than one hour.

### Restore

```
with_lock(key) do
  if hit?: copy each cached path over the working tree (rm_rf destination first, as today)
  touch .meta.json last_used_at (write to .meta.json.tmp, rename)
end
```

`hit?/3` requires `.meta.json` to exist **and** every declared path to be present. An entry
without metadata is a pre-M0-04 entry; treat it as a miss so it gets rewritten atomically.

### `TinyCI.Cache.Lock`

```elixir
@spec with_lock(String.t(), keyword(), (-> result)) :: result when result: term()
# opts: timeout: ms (default 60_000), stale_after: ms (default 600_000), poll: ms (default 50)
```

- Acquire: `File.mkdir(lock_dir)` — atomic on POSIX; `{:error, :eexist}` means held.
- Write `lock_dir/owner` with `"#{System.pid()} #{node()} #{DateTime.utc_now()}"` for debugging.
- If held: if the lock dir's mtime is older than `stale_after`, `File.rm_rf` it and retry
  immediately; otherwise sleep `poll` and retry until `timeout`, then `raise TinyCI.Cache.LockTimeout`.
- Release in `after`, always.

### `TinyCI.Cache.Copy`

```elixir
@spec copy_tree(src :: String.t(), dst :: String.t()) :: :ok | {:error, term()}
```

- Darwin: `cp -Rpc src dst`; on non-zero exit retry `cp -Rp src dst`.
- Linux: `cp -Rp --reflink=auto src dst`.
- Anything else, or `cp` missing: `File.cp_r/2`.
- Preserve symlinks as symlinks (both `cp -R` variants do; `File.cp_r` does too).

### Prune

```elixir
@spec prune(keyword()) :: %{removed: non_neg_integer(), bytes_freed: non_neg_integer()}
# opts: max_bytes (default 5 GiB; env TINY_CI_CACHE_MAX_BYTES; app env :cache_max_bytes),
#       max_age_days (default 30; env TINY_CI_CACHE_MAX_AGE_DAYS; app env :cache_max_age_days)
```

Across **all** projects under `base_dir`: remove entries whose `last_used_at` is older than
`max_age_days`; then, while total `bytes` exceeds `max_bytes`, remove the least recently used
entry. Remove `.tmp/*` older than one hour. Never remove an entry whose lock is currently
held. `stats/0` returns `%{entries, bytes, projects}`.

### Mix task

`mix tiny_ci.cache clean` (unchanged), `mix tiny_ci.cache prune [--max-bytes N] [--max-age-days N]`,
`mix tiny_ci.cache stats`. Print a one-line summary each.

## TDD plan

Use `@tag :tmp_dir` and point `:cache_base_dir` at the tmp dir the way `cache_test.exs` does.

1. **`test/tiny_ci/cache/lock_test.exs`** — `with_lock/3` returns the function's value and
   removes the lock dir; a second process blocks while the first holds the lock (first process
   sends `:held`, waits for `:release`; assert the second has not replied before `:release`);
   a stale lock (create the dir, `File.touch!(dir, ~U[2020-01-01 00:00:00Z])`) is stolen; a
   fresh held lock with `timeout: 100` raises `LockTimeout`. → implement `Lock`.
2. **`test/tiny_ci/cache/copy_test.exs`** — copies a nested tree with a symlink and preserves
   the link; destination content equals source. → implement `Copy`.
3. **`test/tiny_ci/cache_test.exs`** — extend:
   - "save publishes atomically": after `save/4`, `.meta.json` exists with the declared paths
     and no `.tmp/*` remains.
   - "an interrupted save is invisible": expose `TinyCI.Cache.stage_entry/4` (returns the
     staging path) and `commit_entry/3` as `@doc false` public functions; call only the
     first; `hit?/3` is false; after `commit_entry`, true.
   - "an entry without metadata is a miss": build an old-style entry by hand.
   - "concurrent saves of one key leave one consistent entry": two `Task.async` saves with
     different file contents under the same key; after both, the entry's files are all from
     one save (write a marker file per save and assert only one marker is present) and no
     `.tmp/*` remains.
   - "restore touches last_used_at".
   → rewrite `save/4`, `restore/4`, `hit?/3`.
4. **`test/tiny_ci/cache/prune_test.exs`** — age-based removal; size-based LRU removal keeps
   the most recently used entry; `.tmp` older than an hour removed; a locked entry survives.
   → implement `prune/1`, `stats/0`.
5. **`test/mix/tasks/tiny_ci_cache_test.exs`** — `prune` and `stats` print summaries.
6. **`test/tiny_ci/executor_test.exs`** — existing hit/miss tests still pass unchanged (the
   caller API did not move).
7. Full suite; `mix tiny_ci.run`.

## Acceptance criteria

- [x] An interrupted save never produces a hit.
      — `cache_test.exs` "an interrupted save is invisible", "save publishes atomically with metadata".
- [x] Two concurrent saves of one key leave exactly one complete entry.
      — `cache_test.exs` "concurrent saves of one key leave one consistent entry".
- [x] A restore concurrent with a save sees either the old or the new entry, never a mix.
      — by construction: both hold the entry lock (`cache/lock_test.exs` "a second process blocks
      until the first releases") and publish is a single rename ("a second save replaces the
      entry wholesale").
- [x] Copies use `cp -c` / `--reflink=auto` when available and fall back silently.
      — `cache/copy_test.exs` (runs the platform path; the fallback chain is in `Copy.do_copy/3`).
- [x] `prune/1` enforces `max_bytes` (LRU) and `max_age_days`; defaults and env overrides documented.
      — `cache/prune_test.exs`; README "Dependency Caching".
- [x] A save triggers a prune with the default limits.
      — `save/4` calls `prune([])`; `cache_test.exs` "save publishes atomically" asserts no `.tmp/*` remains.
- [x] `mix tiny_ci.cache prune|stats` exist and are documented in the README.
      — `test/mix/tasks/tiny_ci_cache_test.exs`.

## Pitfalls

- `File.rename/2` onto an existing **non-empty directory** fails; hence the rename-away-then-in
  dance. Both renames are inside the lock.
- `File.touch!/2` for the stale-lock test needs an `:erlang.universaltime`-style or
  `DateTime` argument depending on Elixir version; check `File.touch!/2` docs.
- `du` is not portable; compute `bytes` by walking the staging tree with `File.stat!/1` sizes.
- The concurrency test must not rely on timing; assert on the final state only.

## Docs

- README → "Dependency Caching": atomicity guarantee, new tasks, limits and env vars.

## Deviations

- **`Lock.with_lock/3` takes the lock directory path, not a key.** The cache computes
  `<project>/.lock/<key>` and passes it in, which keeps the lock module free of cache layout
  knowledge and lets its tests use any `tmp_dir`.
- **Hand-built entries in existing tests now go through `save/4`.** `hit?/3` requires
  `.meta.json`, so `cache_test.exs` "returns true when all paths exist in cache" and
  `executor_test.exs` "cache hit: restores dirs and skips step" seed the entry with `Cache.save/4`
  instead of `File.mkdir_p!`. The executor's caller API is unchanged; only test setup moved.
- **Pre-metadata entries are still counted by `prune/1` and `stats/0`**, measured by walking the
  directory and dated by its mtime, so age-based eviction eventually clears them rather than
  leaving them forever.
- **`prune/1` takes each entry's lock with `timeout: 0`** rather than checking for the lock
  directory and then deleting, which would race with a save starting in between.
- **A save with no existing paths writes nothing** (as before) rather than publishing an
  entry with `paths: []`.

## Follow-ups

_(none yet)_
