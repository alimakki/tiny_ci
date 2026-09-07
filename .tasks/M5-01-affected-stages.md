# M5-01 — `paths:` stage option; base ref from the trigger; unaffected stages skipped

**Milestone:** M5 · **Size:** S–M · **Depends on:** M0-05, M2-04 · **Status:** ⬜ Not started

> Detail level: design. Expand when M5 opens.

## Summary

Monorepos rebuild everything on every push. tiny_ci already has `when: file_changed?(glob)`;
this task adds the sugar people expect, `paths: ["packages/api/**", "shared/**"]` on a stage,
and makes the server supply the right base ref so "changed" means "changed in this PR" or
"since the last successful build of this branch".

## Design notes

- DSL: `paths:` (list of globs) on `stage` → equivalent to
  `when: file_changed?(g1) or file_changed?(g2) ...`; validator + spec entry; dry-run shows
  the expansion. Combining `paths:` and `when:` means both must hold.
- Base ref on the server: PRs → `base_branch` (M2-04 already carries it); pushes → the sha of
  the last **passed** run of that branch for that pipeline from the runs store
  (`TinyCI.Runs.last_passed(project_id, branch, pipeline)`), falling back to the repo's default
  branch. `RunRequest.base_ref` is filled by the scheduler.
- `Context.build(... include_dirty: false)` in workspaces is already the case.
- Skipped-by-paths stages report `reason: "no matching changes"`; a stage skipped this way
  counts as passed for `needs:` (as today for `when:`), and the status check description says
  "N stages skipped (no changes)".

## Acceptance criteria

- [ ] A push touching only `packages/web/**` runs only stages whose `paths:` match (or have none).
- [ ] PR runs diff against the PR base; branch pushes against the last passed sha.
- [ ] `--dry-run` shows the resolved base and which stages `paths:` would skip.
