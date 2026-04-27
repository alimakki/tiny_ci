# User Story: T0.1 — Stage Filter (`--filter`)

## Story

As a developer debugging a pipeline locally,  
I want to run only specific named stages without editing the pipeline file,  
so that I can iterate quickly on a single stage without waiting for unrelated stages.

## Acceptance Criteria

- `mix tiny_ci.run --filter :test` runs only the `:test` stage
- `mix tiny_ci.run --filter :build,:test` runs both `:build` and `:test`
- Stages not in the filter list are silently omitted (not shown as skipped in output)
- If `:test` needs `:build` and `:build` is filtered out, a warning is printed:
  `Warning: ":test" needs ":build" which was filtered — running :test without it`
- `--dry-run --filter :deploy` shows only the filtered stages
- Invalid stage names in `--filter` print a clear error listing available stages

---

## Tasks

### Tests (written first)

- [x] Write executor tests: single-stage filter runs only that stage
- [x] Write executor tests: multi-stage filter runs only listed stages
- [x] Write executor tests: filtered stages are not present in results (silent omission)
- [x] Write executor tests: `needs:` warning printed when dependency is filtered out
- [x] Write executor tests: DAG mode with filter strips filtered deps and warns
- [x] Write Mix task tests: `--filter :stage` parses and passes filter correctly
- [x] Write Mix task tests: unknown stage in `--filter` prints error and exits with code 1
- [x] Write dry-run tests: `--dry-run --filter :stage` shows only filtered stages

### Implementation

- [x] Add `filter: :string` switch to `OptionParser` in `Mix.Tasks.TinyCi.Run`
- [x] Implement `parse_filter/1` to split comma-separated atom list
- [x] Validate filter stage names against available stages; error on unknown names
- [x] Pass parsed filter through `dispatch_pipeline/3` → executor opts and dry run
- [x] Implement `apply_filter/2` in `TinyCI.Executor` to silently remove non-listed stages
- [x] Emit `needs:` warning in `apply_filter/2` for filtered-out dependencies
- [x] Strip filtered-out stage names from `needs` lists so DAG validation passes
- [x] Pass `:filter` opt through `run_pipeline/3` to `apply_filter/2`
- [x] Filter stages before `DryRun.print_plan/2` in the Mix task

### Quality

- [x] `mix format` — no formatting issues
- [x] `mix test` — all tests pass (437 tests, 0 failures)
- [x] `mix credo` — no issues
- [x] Document `--filter` flag in README
