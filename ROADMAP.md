# tiny_ci Roadmap

Feature backlog ordered by implementation priority. Each item follows the user story format with desired outcomes and acceptance criteria.

---

## 1. Pipeline & Stage-Level Environment Variables

**User story**
As a pipeline author, I want to declare environment variables at the pipeline or stage level so that all steps within that scope inherit them without repeating `env:` on every individual step.

**Desired outcomes**
- A top-level `env` directive sets variables available to all stages and steps in the pipeline.
- A stage-level `env` directive sets variables available only to steps within that stage.
- Step-level `env` overrides stage-level, which overrides pipeline-level (cascade with override).
- Variables are injected into shell step processes and accessible to module steps via context.
- Declared variables appear in `--dry-run` output.

**Acceptance criteria**
- [ ] `env name: "value"` is valid DSL at pipeline scope
- [ ] `env name: "value"` is valid DSL inside a `stage` block
- [ ] Shell steps receive merged env without explicit per-step `env:`
- [ ] Step-level `env:` takes precedence over inherited values
- [ ] Validator accepts `env` as an allowlisted DSL construct

---

## 2. Step-Level `when` Conditions

**User story**
As a pipeline author, I want to apply conditional execution to individual steps — not just entire stages — so that I can skip specific checks on certain branches or environments without restructuring my pipeline into extra stages.

**Desired outcomes**
- The `when` option accepted on `step` uses the same condition DSL already supported on `stage`.
- A skipped step is reported in the summary as "skipped" with its condition displayed.
- Skipped steps do not affect the pass/fail outcome of their stage.
- `--dry-run` shows per-step skip/run status.

**Acceptance criteria**
- [x] `step "name", cmd: "...", when: branch() == "main"` is valid DSL
- [x] Condition is evaluated at runtime against pipeline context
- [x] Skipped steps appear in reporter output with `:skipped` status
- [x] Module steps support `when:` in the same way as shell steps
- [x] Validator allowlists `when:` on step constructs

---

## 3. Working Directory per Step / Stage

**User story**
As a pipeline author, I want to set a working directory on a step or stage so that commands execute relative to a subdirectory of the project without prepending `cd path &&` to every command.

**Desired outcomes**
- A `working_dir:` option on a step changes the process working directory for that step only.
- A `working_dir:` option on a stage sets the default for all steps in that stage; steps may override it.
- Relative paths are resolved from the pipeline root (where `tiny_ci.exs` lives).
- An invalid or non-existent `working_dir` fails the step immediately with a clear error message.
- `--dry-run` displays the resolved working directory for each step.

**Acceptance criteria**
- [ ] `step "name", cmd: "npm test", working_dir: "frontend"` runs in `<root>/frontend`
- [ ] Stage-level `working_dir:` is inherited by steps that don't declare their own
- [ ] Absolute paths are accepted as-is; relative paths are resolved from pipeline root
- [ ] Non-existent directory produces `{:error, :working_dir_not_found}` before execution
- [ ] Validator allowlists `working_dir:` on both step and stage

---

## 4. Step Retries

**User story**
As a pipeline author, I want to configure a step to retry automatically on failure so that transient errors — flaky network calls, intermittent package downloads, external service timeouts — do not fail the whole pipeline.

**Desired outcomes**
- A `retry:` option specifies the maximum number of retry attempts (integer ≥ 1).
- An optional `retry_delay:` option (milliseconds) introduces a wait between attempts.
- Each attempt is logged with its attempt number (e.g., `[attempt 2/3]`).
- If all attempts fail, the step is marked failed and the pipeline proceeds according to normal failure rules.
- Retries are visible in `--dry-run` output as metadata.

**Acceptance criteria**
- [ ] `step "name", cmd: "...", retry: 3` retries up to 3 times on non-zero exit
- [ ] `retry_delay: 1000` waits 1 second between attempts
- [ ] Reporter shows attempt count on failure: `failed after 3 attempts`
- [ ] `allow_failure: true` combined with `retry:` exhausts retries before allowing failure
- [ ] Timeouts apply per attempt, not across all attempts combined

---

## 5. Secrets Management

**User story**
As a pipeline author, I want to declare named secrets so that sensitive values are never echoed to logs, are available to steps as environment variables, and can be sourced from the environment or a local secrets file without being hardcoded in the pipeline definition.

**Desired outcomes**
- A `secret "NAME"` directive declares a secret by name; tiny_ci reads its value from the process environment at runtime.
- Secret values are masked in all output (replaced with `[MASKED]` if they appear in stdout/stderr).
- If a declared secret is not present in the environment, the pipeline fails at startup with a clear error listing missing secrets.
- An optional `.tiny_ci/secrets` file (key=value, gitignored) is sourced automatically if present.
- Secrets are never written to the pipeline store or exposed in `--dry-run` output (only their names are shown).

**Acceptance criteria**
- [ ] `secret "DATABASE_URL"` is valid DSL; value is read from `System.get_env/1`
- [ ] Missing secret at pipeline start produces a descriptive startup error
- [ ] Secret values in stdout/stderr are replaced with `[MASKED]`
- [ ] `.tiny_ci/secrets` file is loaded when present; format is `KEY=value` per line
- [ ] `--dry-run` lists declared secret names without values
- [ ] Validator allowlists `secret` as a DSL construct

---

## 6. Dependency Caching

**User story**
As a pipeline author, I want to cache directories between pipeline runs (keyed by a file hash) so that dependency installation steps are skipped when nothing has changed, dramatically reducing pipeline duration.

**Desired outcomes**
- A `cache` directive accepts a list of directory paths and a `key:` expression (e.g., a file path whose hash becomes the cache key).
- On a cache hit, the cached directories are restored before the step runs; the step itself is skipped.
- On a cache miss, the step runs normally and its output directories are saved to the cache afterward.
- Cache is stored locally (e.g., `~/.cache/tiny_ci/<project>/<key>`).
- Cache hits and misses are reported in output with the resolved key.
- A `--no-cache` CLI flag disables all caching for a run.

**Acceptance criteria**
- [ ] `cache paths: ["deps", "_build"], key: "mix.lock"` is valid DSL on a step
- [ ] Cache key is the SHA256 of the named file's contents
- [ ] Cache hit skips the step and restores directories; reporter shows `[cache hit]`
- [ ] Cache miss runs the step and saves directories; reporter shows `[cache miss]`
- [ ] `mix tiny_ci.run --no-cache` bypasses all cache lookups
- [ ] Stale cache entries can be cleared with `mix tiny_ci.cache clean`

---

## 7. Artifact Persistence

**User story**
As a pipeline author, I want to declare build artifacts produced by one stage so that they are available to downstream stages, enabling multi-stage pipelines (compile → test → package → deploy) without relying on shared filesystem assumptions.

**Desired outcomes**
- An `artifact` directive on a step or stage declares one or more paths to persist after that step/stage completes.
- Downstream stages/steps can reference artifacts by name and have them available in a predictable location.
- Artifacts are stored per pipeline run (timestamped or by commit SHA) so runs don't overwrite each other.
- A `--artifacts-dir` CLI option overrides the default storage location.
- Missing declared artifact paths produce a warning (not an error) unless `required: true` is set.
- `mix tiny_ci.run --list-artifacts` shows artifacts from the last run.

**Acceptance criteria**
- [ ] `artifact "build", paths: ["_build/prod/rel"]` is valid DSL
- [ ] Downstream stage step receives artifact path via store or injected env var
- [ ] Artifact is copied/linked to `<artifacts_dir>/<run_id>/<name>/`
- [ ] Missing path with `required: true` fails the step
- [ ] Missing path without `required:` emits a warning and continues
- [ ] `--dry-run` shows artifact declarations and their resolved storage paths

---

## 8. Stage Dependency Graph (DAG)

**User story**
As a pipeline author, I want stages to declare explicit dependencies so that independent stages can run in parallel while dependent stages wait, enabling fan-out/fan-in topologies without forcing all stages into a single sequence.

**Desired outcomes**
- A `needs:` option on a stage declares one or more stage names that must complete successfully before this stage starts.
- Stages with no `needs:` (and no predecessors depending on them) run in parallel at the start.
- If a dependency stage fails, all stages that `needs:` it are skipped.
- The execution plan rendered by `--dry-run` shows the dependency graph visually.
- Circular dependency detection at parse time produces a clear error.

**Acceptance criteria**
- [ ] `stage "deploy", needs: ["test", "build"]` is valid DSL
- [ ] `test` and `build` run in parallel if they have no mutual dependencies
- [ ] `deploy` starts only after both `test` and `build` succeed
- [ ] Cycle detection at pipeline load time: `{:error, :circular_dependency, [...]}`
- [ ] Reporter shows parallel stages grouped on the same "level"
- [ ] `--dry-run` renders a dependency graph (ASCII or indented tree)

---

## 9. Matrix Builds

**User story**
As a pipeline author, I want to define a matrix of variable combinations so that a stage is automatically replicated and run once per combination, enabling me to test against multiple Elixir versions, operating systems, or configuration flags in a single pipeline definition.

**Desired outcomes**
- A `matrix:` option on a stage accepts a map of variable names to lists of values.
- tiny_ci generates one stage run per combination of matrix values (cartesian product).
- Each matrix run receives its variables as environment variables and as named entries in the pipeline store.
- Matrix runs execute in parallel by default; a `max_parallel:` option caps concurrency.
- The reporter groups matrix runs under their parent stage name with the variable combination shown.
- A failing matrix combination fails the parent stage; `allow_failure: true` on the matrix stage allows partial failure.

**Acceptance criteria**
- [ ] `matrix: [elixir: ["1.17", "1.18"], otp: ["26", "27"]]` produces 4 runs
- [ ] Each run receives `ELIXIR` and `OTP` env vars with its combination's values
- [ ] All 4 runs start in parallel (subject to `max_parallel:`)
- [ ] Reporter shows: `test [elixir=1.17, otp=26] ✓`, `test [elixir=1.17, otp=27] ✓`, etc.
- [ ] One failing combination marks the stage as failed
- [ ] `--dry-run` lists all generated matrix combinations without running them

---

## 10. Watch Mode

**User story**
As a developer, I want tiny_ci to watch my project files and automatically re-run the pipeline (or a specified subset of stages) when files change, so that I get continuous feedback during development without manually re-triggering runs.

**Desired outcomes**
- `mix tiny_ci.run --watch` starts a file watcher on the project root.
- On file change, the pipeline re-runs; if a run is in progress it is cancelled first (or queued, based on a `--watch-queue` flag).
- A `--watch-paths` option restricts which paths trigger a re-run (supports glob patterns).
- A debounce window (default 500ms, configurable via `--watch-debounce`) prevents rapid re-triggers.
- The terminal is cleared between runs (optional, `--watch-clear`).
- `Ctrl+C` exits watch mode cleanly, killing any in-progress run.

**Acceptance criteria**
- [ ] `mix tiny_ci.run --watch` enters watch mode after an initial run
- [ ] Saving any tracked file triggers a re-run within the debounce window
- [ ] `--watch-paths "lib/**/*.ex,test/**/*.exs"` only triggers on matched paths
- [ ] In-progress run is terminated cleanly before starting a new one
- [ ] Exit code on `Ctrl+C` is 0 (clean exit, not a failure)
- [ ] Watch mode is incompatible with `--dry-run`; clear error if combined
