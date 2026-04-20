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

The optional `pipeline` argument selects a named pipeline from `.tiny_ci/`:

```bash
mix tiny_ci.run           # discovers tiny_ci.exs or .tiny_ci/pipeline.exs
mix tiny_ci.run ci        # runs .tiny_ci/ci.exs
mix tiny_ci.run jobs/release  # runs .tiny_ci/jobs/release.exs
mix tiny_ci.run --list    # prints all available pipelines
```

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

### Stages

Stages run sequentially. The pipeline halts on the first stage failure.

```elixir
stage :name, mode: :parallel do
  # steps...
end
```

| Option | Default | Description |
|--------|---------|-------------|
| `:mode` | `:parallel` | How steps within the stage execute — `:parallel` or `:serial` |
| `:when` | (always run) | Condition expression; stage is skipped when it evaluates to falsy |

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

Module steps implement `execute/2`; module hooks implement `run/2`. Both receive the
config keyword list (from `set/2` calls) and the pipeline context map:

```elixir
defmodule MyApp.Deploy do
  def execute(config, context) do
    region = Keyword.fetch!(config, :region)
    branch = context.branch

    # deploy logic...
    :ok        # or {:error, reason}
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

> **Note:** Module steps and hooks must be pre-compiled and available on the Elixir
> load path before TinyCI runs. They cannot be defined inside the `.exs` pipeline file.

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
- Stage options: `:mode`, `:when`
- Step options: `:cmd`, `:module`, `:timeout`, `:env`, `:allow_failure`
- Condition expressions: `branch()`, `env/1`, `file_changed?/1`, `==`, `!=`, `and`, `or`, `not`, `if/else`

Constructs outside this list (e.g. `defmodule`, `System.cmd`, `File.read`) are
rejected at load time with a descriptive error.

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
    dsl.ex                # Macro-based DSL (internal use)
    executor.ex           # Stage/step execution engine
    hooks.ex              # Hook runner
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

### Up Next

- **Phase 13 — Watch Mode** — `mix tiny_ci.run --watch` to re-run on file changes
- **Phase 14 — Polish & Distribution** — `mix tiny_ci.init`, `--only stage_name`, step retries, escript/Burrito binary

### Ideas to Explore

- **Pipeline composition** — include or extend another pipeline file
- **Live TUI** — real-time terminal UI showing stage/step progress
- **Secret management** — `secret "MY_KEY"` reading from an encrypted store
- **Step caching** — skip steps whose inputs haven't changed
- **Matrix builds** — `stage :test, matrix: [elixir: ["1.17", "1.18"]]`
