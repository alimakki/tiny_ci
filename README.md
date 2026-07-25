# TinyCI

> **Early development.** This project is a work in progress. APIs, DSL syntax, and behaviour may change between versions. Feedback and contributions are welcome.

A local CI runner for Elixir projects. Define your build pipeline as code — stages, steps, conditions, hooks — and run it from the command line. No YAML, no cloud dependency.

## Quick Start

1. Create a `tiny_ci.exs` file in your project root:

```elixir
name :my_pipeline

on_success :notify, cmd: "echo 'Build passed on branch $TINY_CI_BRANCH'"
on_failure :alert, cmd: "curl -s -X POST $SLACK_WEBHOOK_URL -d '{\"text\":\"Build failed on $TINY_CI_BRANCH\"}'"

stage :test, mode: :parallel do
  step :unit, cmd: "mix test", timeout: 120_000
  step :lint, cmd: "mix credo"
  step :format, cmd: "mix format --check-formatted"
end

stage :deploy, mode: :serial, when: branch() == "main" do
  step :release, cmd: "mix release"
end
```

2. Run it:

```bash
mix tiny_ci.run
```

## Usage

```
mix tiny_ci.run [pipeline] [options]
```

| Flag | Short | Description |
|------|-------|-------------|
| `--file PATH` | `-f` | Path to a pipeline file (skips discovery) |
| `--root DIR` | `-r` | Project root for pipeline discovery |
| `--dry-run` | | Show what would execute without running anything |
| `--list` | | List all available pipelines in `.tiny_ci/` |
| `--filter STAGES` | | Run only the named stage(s) — see below |
| `--output FORMAT` | | Output format: `json` for machine-readable output |
| `--no-cache` | | Bypass all cache lookups for this run |
| `--artifacts-dir DIR` | | Override the base directory for artifact storage |
| `--list-artifacts` | | Show artifacts from the most recent run and exit |

The optional `pipeline` argument selects a named pipeline from `.tiny_ci/`:

```bash
mix tiny_ci.run           # discovers tiny_ci.exs or .tiny_ci/pipeline.exs
mix tiny_ci.run ci        # runs .tiny_ci/ci.exs
mix tiny_ci.run jobs/release  # runs .tiny_ci/jobs/release.exs
mix tiny_ci.run --list    # prints all available pipelines
```

### Filtering Stages (`--filter`)

Run only specific named stages without editing the pipeline file — useful for
debugging a single stage locally.

```bash
# Run only the :test stage
mix tiny_ci.run --filter :test

# Run :build and :test, skip everything else
mix tiny_ci.run --filter :build,:test

# Preview which stages would run (without executing)
mix tiny_ci.run --dry-run --filter :deploy
```

Stages not in the filter list are silently omitted — they do not appear as
skipped in the output.

If a filtered-in stage declares `needs:` pointing to a stage that was filtered
out, a warning is printed and the stage runs without that dependency:

```
Warning: ":test" needs ":build" which was filtered — running :test without it
```

Passing an unknown stage name to `--filter` is an error; the available stage
names are listed in the error message.

### Machine-Readable Output (`--output json`)

Add `--output json` to get a JSON object on stdout instead of human-readable
text. All ANSI output, stage headers, and progress lines are suppressed — only
the JSON object is printed.

```bash
# Run and capture JSON
mix tiny_ci.run --output json

# Pipe into jq
mix tiny_ci.run --output json | jq '.status'
# → "passed" or "failed"

# Check per-stage results
mix tiny_ci.run --output json | jq '[.stages[] | {name, status, duration_ms}]'
```

Output shape:

```json
{
  "status": "passed",
  "duration_ms": 1234,
  "stages": [
    {
      "name": "test",
      "status": "passed",
      "duration_ms": 500,
      "steps": [
        {
          "name": "unit",
          "status": "passed",
          "output": "...",
          "duration_ms": 200,
          "attempts": 1,
          "allowed_failure": false
        }
      ],
      "matrix_runs": []
    }
  ]
}
```

Matrix stages include a `matrix_runs` array instead of top-level `steps`. Each
run has a `combination` map (e.g. `{"elixir": "1.17", "otp": "26"}`), its own
`status`, `duration_ms`, and a `steps` array.

Exit codes are unchanged: `0` on success, `1` on failure — the JSON `status`
field and the exit code always agree.

Exit codes: `0` on success, `1` on failure — suitable for git hooks and scripts.

### Pipeline Discovery

When `--file` is not given and no pipeline name is provided, TinyCI searches in order:

1. `tiny_ci.exs` (project root)
2. `.tiny_ci/pipeline.exs`

Named pipelines live in `.tiny_ci/<name>.exs` or nested as `.tiny_ci/<dir>/<name>.exs`.

## DSL Reference

Pipeline files use a flat, declarative DSL. No `defmodule`, no `use` statements — just
top-level directives. Files are parsed into a controlled AST rather than compiled as
arbitrary Elixir modules.

### `name`

Optional. Sets the pipeline name. Defaults to the filename stem (`deploy.exs` → `:deploy`).

```elixir
name :my_pipeline
```

### Environment Variables

The `env` directive declares environment variables that are automatically inherited by steps. It can be used at the pipeline level (all stages and steps inherit) or inside a stage block (only steps in that stage inherit). Step-level `env:` values take precedence and override inherited ones.

```elixir
# Pipeline-level: available to every step
env "MIX_ENV": "test"
env "DATABASE_URL": "postgres://localhost/mydb"

stage :test do
  # Stage-level: only steps in this stage inherit these
  env "NODE_ENV": "test"

  step :unit, cmd: "mix test"
  # MIX_ENV, DATABASE_URL, and NODE_ENV are all available here

  step :assets, cmd: "npm test"
  # Override a specific key for one step
  step :assets_prod, cmd: "npm run build", env: %{"NODE_ENV" => "production"}
end
```

Multiple variables can be declared on one line or across multiple `env` calls — they are merged in declaration order:

```elixir
env "APP": "myapp", "REGION": "us-east-1"
```

`--dry-run` shows declared env vars at the pipeline and stage level.

### Stages

By default, stages run sequentially. When any stage declares `needs:`, the pipeline switches to DAG execution: independent stages run in parallel while dependent stages wait for their prerequisites.

```elixir
stage :name, mode: :parallel do
  # steps...
end
```

| Option | Default | Description |
|--------|---------|-------------|
| `:mode` | `:parallel` | How steps within the stage execute — `:parallel` or `:serial` |
| `:needs` | `[]` | List of stage names that must complete successfully before this stage starts |
| `:when` | (always run) | Condition expression; stage is skipped when it evaluates to falsy |
| `:working_dir` | (pipeline root) | Default working directory for all steps in this stage |
| `:matrix` | `[]` | Keyword list of variable names to value lists; stage runs once per combination |
| `:max_parallel` | (unlimited) | Maximum number of matrix runs executing at the same time |
| `:allow_failure` | `false` | When `true`, a failing matrix combination does not fail the parent stage |

### Stage Dependencies (DAG)

The `needs:` option declares explicit dependencies between stages. Stages without `needs:` at the same level run in parallel; stages with `needs:` wait for all listed stages to pass.

```elixir
# build and lint run in parallel (no dependencies between them)
stage :build do
  step :compile, cmd: "mix compile"
end

stage :lint do
  step :format, cmd: "mix format --check-formatted"
  step :credo,  cmd: "mix credo"
end

# test waits for build and lint to both succeed
stage :test, needs: [:build, :lint] do
  step :unit, cmd: "mix test"
end

# deploy waits for test
stage :deploy, needs: [:test], when: branch() == "main" do
  step :release, cmd: "mix release"
end
```

**Execution topology** for the above:

```
Level 1 (parallel): :build  :lint
Level 2:            :test          ← waits for both
Level 3:            :deploy        ← waits for test
```

**Failure propagation:** if a stage fails, all stages that `needs:` it (directly or transitively) are automatically skipped. Independent stages at the same level still run.

**Cycle detection:** circular dependencies (`a needs b, b needs a`) are caught at parse time with a descriptive error — the pipeline will not start.

`--dry-run` shows the dependency graph grouped by level, with `[needs: ...]` shown for each dependent stage.

### Matrix Builds

The `matrix:` option replicates a stage across multiple variable combinations. TinyCI computes the cartesian product of all values, starts one run per combination (in parallel by default), and groups results under the parent stage name in the summary.

```elixir
stage :test, matrix: [elixir: ["1.17", "1.18"], otp: ["26", "27"]] do
  step :unit, cmd: "mix test"
end
```

The above generates four parallel runs:

| Combination | Env vars injected |
|-------------|-------------------|
| `elixir=1.17, otp=26` | `ELIXIR=1.17  OTP=26` |
| `elixir=1.17, otp=27` | `ELIXIR=1.17  OTP=27` |
| `elixir=1.18, otp=26` | `ELIXIR=1.18  OTP=26` |
| `elixir=1.18, otp=27` | `ELIXIR=1.18  OTP=27` |

Each step in the stage receives its combination's values as uppercased environment variables (`ELIXIR`, `OTP`). The same values are also written into the pipeline store so module steps can read them via `ctx.store`.

**Limiting concurrency** — use `max_parallel:` to cap how many runs execute simultaneously:

```elixir
stage :test,
  matrix: [elixir: ["1.17", "1.18"], otp: ["26", "27"]],
  max_parallel: 2 do
  step :unit, cmd: "mix test"
end
```

**Allowing partial failure** — by default any failing combination marks the entire stage as failed. Set `allow_failure: true` to let the pipeline continue even when some combinations fail:

```elixir
stage :compatibility,
  matrix: [os: ["ubuntu", "macos", "windows"]],
  allow_failure: true do
  step :smoke, cmd: "./run_smoke_test.sh"
end
```

**Reporter output** — each combination is shown as a sub-row under the stage:

```
  ✓ test — passed (3.2s)
    ✓ [elixir=1.17, otp=26] (0.8s)
      ✓ unit (0.8s)
    ✓ [elixir=1.17, otp=27] (0.9s)
      ✓ unit (0.9s)
    ✓ [elixir=1.18, otp=26] (0.7s)
      ✓ unit (0.7s)
    ✓ [elixir=1.18, otp=27] (0.8s)
      ✓ unit (0.8s)
```

`--dry-run` lists all generated combinations without executing anything.

### Steps

Each step is a shell command or a module callback.

```elixir
# Shell command
step :test, cmd: "mix test", timeout: 60_000, env: %{"MIX_ENV" => "test"}

# Module step — module must be pre-compiled and available on the load path
step :deploy, module: MyApp.Deploy do
  set :region, "us-east-1"
  set :replicas, 3
end
```

| Option | Description |
|--------|-------------|
| `:cmd` | Shell command to execute |
| `:module` | Module implementing `execute(config, context)` |
| `:timeout` | Max execution time in ms; step fails if exceeded |
| `:env` | Map of environment variables merged into the shell environment |
| `:allow_failure` | When `true`, step can fail without failing the stage |
| `:when` | Condition expression; step is skipped when it evaluates to falsy |
| `:working_dir` | Directory to run the command in (string path) |
| `:retry` | Number of times to retry on failure (e.g. `retry: 3` = up to 3 retries) |
| `:retry_delay` | Milliseconds to wait between retry attempts (default: no delay) |

### Conditions

The `:when` option is supported on both **stages** and **steps**. It accepts a boolean expression built from these primitives:

| Expression | Description |
|------------|-------------|
| `branch()` | Current git branch name (string) |
| `env("VAR")` | Value of environment variable, or `nil` if unset |
| `file_changed?("glob")` | `true` if any file matching the glob changed since last commit |

Combine with standard boolean operators: `and`, `or`, `not`, `==`, `!=`.

**Stage-level conditions** skip the entire stage when not met:

```elixir
stage :deploy, when: branch() == "main" do
  step :release, cmd: "mix release"
end

stage :test, when: file_changed?("lib/**") or file_changed?("test/**") do
  step :unit, cmd: "mix test"
end
```

**Step-level conditions** skip individual steps within a running stage, leaving the rest of the stage unaffected:

```elixir
stage :check do
  step :unit,     cmd: "mix test"
  step :dialyzer, cmd: "mix dialyzer", when: branch() == "main"
  step :audit,    cmd: "mix deps.audit", when: env("CI") != nil
end
```

A skipped step is reported with a `○` icon in the summary and does not affect the stage outcome. `--dry-run` shows which steps would be skipped before any execution.

### Working Directory

The `working_dir:` option sets the directory a shell command runs in. It can be set on a stage (applies to all steps) or on an individual step (overrides the stage value).

```elixir
# Stage-level: all steps run inside frontend/
stage :frontend, working_dir: "frontend" do
  step :install, cmd: "npm install"
  step :build,   cmd: "npm run build"
  step :test,    cmd: "npm test", working_dir: "frontend/packages/core"
end

# Step-level only
stage :check do
  step :mix_test, cmd: "mix test"
  step :js_lint,  cmd: "eslint src", working_dir: "assets"
end
```

Relative paths are resolved from the directory containing the pipeline file. Absolute paths are used as-is. If the directory does not exist, the step fails immediately with a clear error before any command is run. `--dry-run` shows the resolved path for each step.

### Dependency Caching

The `cache:` option skips a step and restores its output directories when the nominated key file (e.g. `mix.lock`) has not changed since the last run. On the first run (cache miss) the step executes normally and its output is saved; subsequent runs with the same key are served from cache.

```elixir
stage :install do
  # Skip `mix deps.get` when mix.lock hasn't changed
  step :deps, cmd: "mix deps.get",
    cache: [paths: ["deps", "_build"], key: "mix.lock"]
end
```

- `paths:` — list of directories/files to cache and restore (relative to step working dir or project root)
- `key:` — path to the file whose SHA-256 hash is used as the cache key (relative to project root)
- Cache is stored at `~/.cache/tiny_ci/<project_id>/<key_hash>/`
- A cache hit restores the directories **before** the step runs and skips the command; the reporter shows `[cache hit]`
- A cache miss runs the step and saves the directories afterward; the reporter shows `[cache miss]`
- `--dry-run` shows `[cache: key=mix.lock, paths=[deps, _build]]` in the step plan
- `--no-cache` bypasses all cache lookups for the current run
- `mix tiny_ci.cache clean` removes all cache entries for the current project:

```bash
mix tiny_ci.cache clean
mix tiny_ci.cache clean --root /path/to/project
```

### Artifact Persistence

The `artifact:` option declares build outputs that a step produces. After the step completes successfully, the declared paths are copied to a per-run storage directory so they survive the build and can be inspected or referenced by downstream steps.

```elixir
stage :build, mode: :serial do
  step :compile, cmd: "mix release",
    artifact: [name: "release", paths: ["_build/prod/rel"]]
end

stage :package, mode: :serial do
  # Access the artifact path from the store
  step :bundle, module: MyApp.Package do
    set :source, store(:artifact_release)
  end
end
```

- `name:` — string identifier for this artifact (used as the directory name and store key)
- `paths:` — list of paths (relative to the step's working directory or project root) to copy
- `required:` — when `true`, a missing path fails the step; when `false` (default) a warning is printed and the step still passes
- Artifacts are stored at `~/.local/share/tiny_ci/artifacts/<project_id>/<run_id>/<name>/`
- Each run gets an isolated subdirectory (`<YYYYMMDD_HHMMSS>_<commit7>`) so runs never overwrite each other
- After a step with `artifact:` completes, the artifact's storage path is written to the pipeline store under the key `artifact_<name>` — downstream module steps can read it via `ctx.store.artifact_release` and shell steps can use `store(:artifact_release)` in their `env:`
- `--dry-run` shows `[artifact: name=..., paths=[...], dest=...]` in the step plan
- `--artifacts-dir DIR` overrides the base storage location for the current run
- `mix tiny_ci.run --list-artifacts` lists artifacts from the most recent run

```bash
# Show artifacts from the last run
mix tiny_ci.run --list-artifacts

# Store artifacts in a custom directory
mix tiny_ci.run --artifacts-dir /tmp/ci-artifacts
```

### Step Retries

The `retry:` option retries a failed step automatically, useful for flaky network calls, intermittent package downloads, or external service timeouts.

```elixir
stage :test do
  # Retry up to 3 times on failure
  step :flaky_test, cmd: "mix test --seed random", retry: 3

  # Retry with a 2-second delay between attempts
  step :fetch_deps, cmd: "mix deps.get", retry: 2, retry_delay: 2000
end
```

- `retry: N` — retry up to N times; total max attempts = N + 1
- `retry_delay: N` — wait N milliseconds between attempts (default: no delay)
- Each attempt is logged with its number (e.g. `[attempt 2/3]`)
- `allow_failure: true` exhausts all retries before allowing the failure
- `timeout:` applies per attempt, not across all attempts combined
- `--dry-run` shows `[retry: N]` and `[retry_delay: Nms]` in the step plan
- The summary reports `passed on attempt N` or `failed after N attempts` when retries were used

### Hooks

Hooks run after the pipeline completes. Shell command hooks and module hooks are both supported.

```elixir
# Shell command hook
on_success :notify, cmd: "say 'Build passed'"
on_failure :alert, cmd: "curl -X POST $SLACK_WEBHOOK_URL -d '{\"text\":\"Build failed\"}'"

# Module hook — module must be pre-compiled and available on the load path
on_success :slack, module: MyApp.SlackNotifier do
  set :channel, "#deploys"
end

on_failure :slack, module: MyApp.SlackNotifier do
  set :channel, "#alerts"
end
```

Hook failures are logged to stderr but do not change the pipeline exit code.

### Module Steps and Hooks

Module steps implement the **`TinyCI.Action` behaviour** (`execute/2`); module hooks
implement `run/2`. Both receive the config keyword list (from `set/2` calls) and the
pipeline context (`%TinyCI.Context{}`):

```elixir
defmodule MyApp.Deploy do
  use TinyCI.Action

  @impl TinyCI.Action
  def execute(config, context) do
    region = Keyword.fetch!(config, :region)
    branch = context.branch

    # deploy logic...
    :ok        # or {:ok, map} to write to the store, or {:error, reason}
  end

  # Optional — advertises identity and the capabilities the action needs.
  @impl TinyCI.Action
  def metadata do
    %TinyCI.Action.Metadata{name: "my_app.deploy", version: "1.0.0", capabilities: [:network]}
  end
end

defmodule MyApp.SlackNotifier do
  def run(config, context) do
    emoji   = if context.pipeline_result == :on_success, do: "✅", else: "❌"
    message = "#{emoji} *#{context.branch}* — pipeline #{context.pipeline_result}"

    {_output, exit_code} =
      System.cmd("curl", [
        "-s", "-o", "/dev/null",
        "-X", "POST", config[:webhook_url],
        "-H", "Content-Type: application/json",
        "-d", ~s({"channel":"#{config[:channel]}","text":"#{message}"})
      ])

    if exit_code == 0, do: :ok, else: {:error, :curl_failed}
  end
end
```

Module steps return `:ok` or `{:ok, map}` to merge data into the pipeline store.
Module hooks return `:ok` or `{:error, reason}`.

Scaffold a new action (module + passing test stub) with the generator:

```sh
mix tiny_ci.gen.action MyApp.Deploy
# creates lib/my_app/deploy.ex and test/my_app/deploy_test.exs
```

The loader verifies, **before any step runs**, that each `module:` step
implements `TinyCI.Action` (exports `execute/2`) and each module hook exports
`run/2`, failing with a descriptive error otherwise. See
[`docs/actions.md`](docs/actions.md) for the full contract.

> **Deprecated:** modules that export `execute/2` without `use TinyCI.Action`
> still run by convention, but adopting the behaviour is recommended so the
> compiler verifies your callbacks via `@impl`.

> **Note:** Module steps and hooks must be pre-compiled and available on the Elixir
> load path before TinyCI runs. They cannot be defined inside the `.exs` pipeline file.

### Third-party actions & the lockfile

Third-party actions are ordinary **Hex dependencies** declared in your `mix.exs`,
so **`mix.lock` is the action lockfile** — every action is pinned to an exact
version and checksum, with no mutable-tag supply-chain risk.

Before any step runs, `mix tiny_ci.run` verifies every `module:` action against
the lockfile and **fails closed**: an action whose package is absent from
`mix.lock`, or whose loaded version has drifted from the locked one, aborts the
run with a descriptive error. Your own (first-party) modules need no pin.

```sh
mix tiny_ci.actions.audit          # print the resolved action tree (package, version, checksum, status)
```

The lockfile covers the **BEAM automation layer**, not binaries pulled by
`cmd:`/actions (apt, Docker images, npm) — pin those with their own ecosystems.
See [`docs/actions.md`](docs/actions.md#supply-chain-action-resolution--the-lockfile).

### Signed run attestations (provenance)

A run can emit a **signed attestation** of exactly what executed — pipeline,
commit, per-step outcome/duration, and every action at its locked
version/checksum — as a tamper-evident, in-toto/SLSA-style record.

```bash
mix tiny_ci.attest.gen_key --out ci_key                       # one-time keypair
mix tiny_ci.run --attest run.att.json --signing-key ci_key    # run + attest
mix tiny_ci.attest.verify run.att.json --key ci_key.pub       # verify (fails if modified)
```

"What ran" is sourced from the [event stream](docs/events.md) and action
versions/checksums from the lockfile, so the attestation ties *what was pinned*
to *what actually ran*. Signing is pluggable (Ed25519 local keypair by default).
See [`docs/provenance.md`](docs/provenance.md).

### Discovering actions (registry)

The registry is a **curated index over the action packages you already depend
on** — small and verifiable, not a vast marketplace. A package self-identifies by
listing its action modules in its `:tiny_ci_actions` application env, so the index
builds programmatically from installed deps.

```bash
mix tiny_ci.actions.search deploy                 # find actions by name/summary
mix tiny_ci.actions.search --capability network   # filter by blast radius
mix tiny_ci.actions.index --out actions.json      # generate a static JSON index
```

Each result surfaces the package, version, declared **capabilities** (blast
radius), and a **review tier** (`verified` / `community` / `unreviewed`). Tiers
come from a checked-in curated overlay merged onto the scan. See
[`docs/action-registry.md`](docs/action-registry.md).

### Sandboxed execution of third-party actions

Because the BEAM is not a security boundary, **third-party** module actions (code
shipped by a dependency) run inside an **OS sandbox** with only the capabilities
they declared, while your own first-party code runs inline. Driver selection is
automatic and **fails closed** — inline execution refuses untrusted code, and the
sandbox refuses to run if no OS backend is available.

An action's `TinyCI.Action.Metadata` capabilities (`:network`,
`:filesystem_read/write`, `:env_read`, `:process_spawn`), intersected with the
run's grants, become a **deny-by-default** policy the OS enforces. Config and a
sanitized context cross the boundary as plain serialized data (no shared
PIDs/handles); the `{:ok, store_delta}` result merges back exactly as an inline
step's would, with granted secrets masked.

The backend is chosen per host: macOS **Seatbelt** (`sandbox-exec`) or Linux
**Bubblewrap** (`bwrap`); an OCI-container backend for CI fits the same contract.
Confinement extends to native code and subprocesses, so a NIF or `System.cmd/3`
that tries to reach the network or write outside its grant is blocked. See
[`docs/sandbox.md`](docs/sandbox.md).

## Sharing Data Between Steps

The **pipeline store** is a key-value map that accumulates data across steps and stages
within a single pipeline run. It lets earlier steps produce values that later steps consume.

### Writing to the store (module steps)

A module step writes to the store by returning `{:ok, map}` from `execute/2`:

```elixir
defmodule MyApp.BuildImage do
  def execute(_config, _ctx) do
    tag = "myapp:#{System.get_env("GIT_SHA", "latest")}"
    # ... build the image ...
    {:ok, %{image_tag: tag}}   # merged into the store
  end
end
```

Shell steps cannot write to the store.

### Reading from the store (module steps)

Module steps read prior values from `ctx.store`:

```elixir
defmodule MyApp.PushImage do
  def execute(_config, ctx) do
    tag = ctx.store.image_tag   # written by an earlier step
    {_out, 0} = System.cmd("docker", ["push", tag])
    :ok
  end
end
```

### Reading from the store (shell steps)

Shell steps do **not** receive store values automatically. Declare exactly
which keys you need using `store(:key)` in the step's `env:` option:

```elixir
stage :build do
  step :tag_image, module: MyApp.BuildImage    # writes image_tag to store
end

stage :deploy do
  step :push,
    cmd: "docker push $IMAGE_TAG",
    env: %{"IMAGE_TAG" => store(:image_tag)}

  step :notify,
    cmd: "echo Deployed $IMAGE_TAG to production",
    env: %{"IMAGE_TAG" => store(:image_tag)}
end
```

Only the keys you explicitly reference are exposed. Everything else in the
store stays invisible to the shell environment — so a step that writes a
computed auth token cannot accidentally leak it to unrelated steps.

### Scope

The store is **local to a pipeline run**. It starts empty, accumulates values left to
right across steps and top to bottom across stages, and is discarded when the run ends.

```
Stage 1 step A writes {image_tag: "myapp:abc"}
Stage 1 step B sees   store = %{image_tag: "myapp:abc"}
Stage 2 step C sees   store = %{image_tag: "myapp:abc"}   ← carries forward
Stage 2 step D writes {pushed: true}
Stage 3 step E sees   store = %{image_tag: "myapp:abc", pushed: true}
```

In parallel stages, all steps start with the same store snapshot; their outputs are
merged after all steps finish, so two parallel steps writing the same key results in
an arbitrary winner. Avoid writing the same key from parallel steps.

### Hooks and the store

The same `store(:key)` syntax works in hook `env:` options:

```elixir
on_success :deploy_notify,
  cmd: "echo Deployed $TAG to production",
  env: %{"TAG" => store(:image_tag)}
```

Hooks receive `TINY_CI_RESULT`, `TINY_CI_BRANCH`, and `TINY_CI_COMMIT`
automatically — store values are only injected when you ask for them.

### Sharing between pipelines

There is no built-in mechanism to share data between separate `mix tiny_ci.run`
invocations. Use the filesystem or environment variables as the bridge:

```elixir
# pipeline: build
stage :package do
  step :write_tag, cmd: "echo myapp:$(git rev-parse --short HEAD) > .tiny_ci_tag"
end

# pipeline: deploy  (run separately, e.g. after build)
stage :push do
  step :deploy, cmd: "docker push $(cat .tiny_ci_tag)"
end
```

## Pipeline Context

Every pipeline run builds a context map from the git environment:

```elixir
%{
  branch: "main",              # current git branch
  commit: "a1b2c3d...",       # full commit SHA
  changed_files: ["lib/..."], # files changed since last commit
  store: %{},                  # accumulated data from module steps
  timestamp: ~U[...]           # UTC timestamp
}
```

Module hooks also receive `:pipeline_result` (`:on_success` or `:on_failure`).

## DSL Allowlist

Pipeline files are validated against an allowlist of permitted constructs before execution:

- `name`, `stage`, `step`, `on_success`, `on_failure`, `set`
- Stage options: `:mode`, `:needs`, `:when`, `:working_dir`, `:matrix`, `:max_parallel`, `:allow_failure`
- Step options: `:cmd`, `:module`, `:timeout`, `:env`, `:allow_failure`, `:when`, `:working_dir`, `:retry`, `:retry_delay`, `:cache`, `:artifact`
- Condition expressions: `branch()`, `env/1`, `file_changed?/1`, `==`, `!=`, `and`, `or`, `not`, `if/else`

Constructs outside this list (e.g. `defmodule`, `System.cmd`, `File.read`) are
rejected at load time with a descriptive error.

This allowlist is described once, machine-readably, in **`TinyCI.DSL.Spec`** —
every directive, option key (with its type), and condition primitive. The
validator derives its permitted-key set from the Spec, and the language server's
completion and hover read from the same source, so the three can never drift.

## Language Server (diagnostics, completion, hover)

A full editing experience runs **live in your editor**. `tiny_ci_lsp/` is a
separate package (it depends on core, never the other way around) that implements
a Language Server Protocol server over stdio:

- **Diagnostics** — a disallowed construct, unknown option, dependency cycle, or
  syntax error is underlined at the offending range and clears when you fix it.
- **Completion** — context-aware suggestions: directives at the right scope,
  stage/step/hook option keys inside their calls, and `branch()` / `env(...)` /
  `file_changed?(...)` inside a `when:` condition.
- **Hover** — a one-line description plus an example for the symbol under the
  cursor.
- **Go-to-definition** — jump from a `needs:` atom to its `stage` declaration, or
  from a `module:` alias to the module's source.
- **Flow diagnostics** — undefined `needs:` targets and dependency cycles inline,
  plus pipeline-store dataflow warnings (`store(:k)` read with no writer; the same
  key written by steps that may run in parallel).

It never executes your file. Diagnostics call the same controlled-AST path the
runner uses (`TinyCI.DSL.Interpreter.diagnose_string/2`), so the in-editor
message is identical to what `mix tiny_ci.run` prints at load time. Completion and
hover read from `TinyCI.DSL.Spec`, the same source the validator's allowlist
derives from. Cursor context is determined by walking the AST (via
`Code.Fragment.container_cursor_to_quoted/1`), not by matching text.

```bash
cd tiny_ci_lsp
mix deps.get
mix escript.build      # produces ./tiny_ci_lsp — point your editor at it
```

The server binary alone does nothing — your editor needs a client to launch it.
A ready-to-build VS Code extension lives in **[editors/vscode/](editors/vscode/)**
(`npm install`, then <kbd>F5</kbd> or package a `.vsix`); Neovim's built-in LSP
needs only a few lines of config. See **[docs/lsp.md](docs/lsp.md)** for both, plus
architecture.

## Multiple Pipelines

Organize multiple pipelines in `.tiny_ci/`:

```
.tiny_ci/
  ci.exs          # mix tiny_ci.run ci
  deploy.exs      # mix tiny_ci.run deploy
  jobs/
    nightly.exs   # mix tiny_ci.run jobs/nightly
```

```bash
mix tiny_ci.run --list    # shows: ci, deploy, jobs/nightly
mix tiny_ci.run ci
mix tiny_ci.run jobs/nightly --dry-run
```

## Event System

Every phase of a pipeline run emits a typed event struct. These events are the
foundation for the event log, run history CLI, and web dashboard (coming in Phase 1).

All events live under `TinyCI.Events.*` and share two mandatory fields:

| Field | Type | Description |
|-------|------|-------------|
| `run_id` | `String.t()` | Unique identifier for the pipeline run |
| `timestamp` | `DateTime.t()` | UTC wall-clock time the event occurred |

### Event Types

| Struct | Emitted when |
|--------|--------------|
| `PipelineStarted` | A pipeline run begins |
| `PipelineCompleted` | A pipeline run finishes (`status: :passed \| :failed`) |
| `StageStarted` | A stage begins executing |
| `StageSkipped` | A stage is skipped (condition or filter) |
| `StageCompleted` | A stage finishes |
| `StepStarted` | A step begins within a stage |
| `StepSkipped` | A step is skipped (condition) |
| `StepOutputLine` | One line of step output (streaming mode) |
| `StepRetrying` | A step is about to be retried after failure |
| `StepCompleted` | A step finishes |
| `MatrixRunStarted` | One matrix combination begins |
| `MatrixRunCompleted` | One matrix combination finishes |
| `HookStarted` | A pipeline hook begins |
| `HookCompleted` | A pipeline hook finishes |

All structs implement `Jason.Encoder`. Atoms are encoded as strings; `DateTime`
values are encoded as ISO 8601 strings. Keyword-list `combination` fields on
matrix events are encoded as JSON objects with string keys.

```elixir
alias TinyCI.Events.StageCompleted

event = %StageCompleted{
  run_id: "20240115_103000_main_abc1234",
  timestamp: DateTime.utc_now(),
  stage: :test,
  status: :passed,
  duration_ms: 1234
}

Jason.encode!(event)
# => {"run_id":"20240115_103000_main_abc1234","timestamp":"2024-01-15T10:30:00.000000Z",
#     "stage":"test","status":"passed","duration_ms":1234}
```

## Project Structure

```
lib/
  mix/tasks/
    tiny_ci.run.ex        # CLI entry point (mix tiny_ci.run)
  tiny_ci/
    application.ex        # OTP application / task supervisor
    context.ex            # Git context builder
    discovery.ex          # Pipeline file discovery
    dry_run.ex            # --dry-run plan printer
    dsl/
      condition_eval.ex   # Condition expression evaluator
      interpreter.ex      # DSL file parser → PipelineSpec
      validator.ex        # AST allowlist validator
    dag.ex                # DAG level computation and cycle detection
    dsl.ex                # Macro-based DSL (internal use)
    events.ex             # Typed event vocabulary (14 structs)
    executor.ex           # Stage/step execution engine
    hooks.ex              # Hook runner
    matrix.ex             # Matrix combination generator and helpers
    matrix_run_result.ex  # MatrixRunResult struct
    output.ex             # Command output streaming
    pipeline_spec.ex      # PipelineSpec struct
    reporter.ex           # Summary and output formatting
    tiny_ci.ex            # Step and Stage struct definitions
    step_result.ex        # StepResult struct
    stage_result.ex       # StageResult struct
test/
  mix/tasks/
    tiny_ci_run_test.exs  # Mix task integration tests
  tiny_ci/
    context_test.exs
    discovery_test.exs
    dsl/
      condition_eval_test.exs
      interpreter_test.exs
      validator_test.exs
    dsl_test.exs
    events_test.exs
    executor_test.exs
    integration_test.exs
    reporter_test.exs
```

## Development

```bash
mix test                           # run full suite
mix format                         # format code
mix compile --warnings-as-errors   # check for warnings
mix credo                          # static analysis
```

## Roadmap

### Completed

- **Core execution** — serial and parallel stage modes, fail-fast pipeline, conditional stages
- **Git context** — automatic branch/commit detection passed through the pipeline
- **CLI** — `mix tiny_ci.run` with discovery, `--file`, `--root`, `--list`, named pipelines, proper exit codes
- **Generic config** — `set key, value` for module step and hook configuration
- **Output** — live streaming with per-step prefixes in parallel mode, buffered fallback in non-TTY
- **Robustness** — step timeouts, `--dry-run`, `allow_failure` steps
- **Richer conditions** — `branch()`, `env/1`, `file_changed?/1` with boolean combinators
- **Hooks** — `on_success` / `on_failure` pipeline hooks (shell and module-based)
- **Step data passing** — pipeline store for sharing data between module steps
- **Custom DSL** — declarative pipeline format with an allowlist validator
- **Stage dependencies (DAG)** — `needs:` for fan-out/fan-in topologies with parallel independent stages, transitive skip propagation, and cycle detection at parse time
- **Matrix builds** — `matrix:` option for cartesian-product parallel stage runs with env var injection, `max_parallel:` concurrency cap, and `allow_failure:` for partial tolerance
- **Event structs** — 14 typed event structs covering every execution boundary (pipeline, stage, step, matrix, hooks), each with `run_id`, `timestamp`, and `Jason.Encoder` support
- **Dependency caching** — `cache: [paths: [...], key: "file"]` skips steps on hash-keyed hits, stores at `~/.cache/tiny_ci/`, `--no-cache` flag, `mix tiny_ci.cache clean` to purge
- **Artifact persistence** — `artifact: [name: "build", paths: [...]]` copies declared outputs to `~/.local/share/tiny_ci/artifacts/<project>/<run_id>/`, injects path into pipeline store, `required: true` fails the step if paths are absent, `--artifacts-dir` override, `--list-artifacts` to inspect
- **Language server (live diagnostics)** — `tiny_ci_lsp`, a separate stdio LSP package that surfaces the validator's load-time errors live in-editor with accurate ranges, debounced as you type, over a shared code path with the runner ([docs/lsp.md](docs/lsp.md))

### Up Next

- **Secrets management** — `secret "MY_KEY"` reading from env or a local secrets file, with value masking in output
- **Watch mode** — `mix tiny_ci.run --watch` to re-run on file changes
