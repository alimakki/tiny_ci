# The action contract (`TinyCI.Action`)

A **module step** in a TinyCI pipeline delegates its work to an *action* — an
Elixir module. This document describes the formal contract those modules
implement: the `TinyCI.Action` behaviour, its optional metadata, the pipeline
context they receive, and how the loader verifies them before a run.

It is the foundation for later features — the action marketplace, lockfile
resolution, sandboxed/remote execution, and provenance — so the contract is
designed to be **serializable in spirit**: *config in, result + store-delta out*.

## The behaviour

```elixir
defmodule MyApp.Deploy do
  use TinyCI.Action

  @impl TinyCI.Action
  def execute(config, ctx) do
    region = Keyword.fetch!(config, :region)
    IO.puts("Deploying to #{region} from #{ctx.branch}")
    {:ok, %{deployed_at: DateTime.utc_now()}}
  end
end
```

`use TinyCI.Action` injects `@behaviour TinyCI.Action`, so the compiler verifies
your `@impl` callbacks.

### `execute/2`

```elixir
@callback execute(config :: keyword(), ctx :: TinyCI.Context.t()) ::
            :ok | {:ok, map()} | {:error, term()}
```

  * `config` — the step's `set/2` configuration as a keyword list.
  * `ctx` — the pipeline `%TinyCI.Context{}` (see below).

Return semantics:

| Return          | Meaning                                                              |
| --------------- | ------------------------------------------------------------------- |
| `:ok`           | step passed; the pipeline store is unchanged                        |
| `{:ok, map}`    | step passed; `map` is merged into the store for later steps/stages  |
| `{:error, term}`| step failed (stage fails unless the step is `allow_failure: true`)  |

### `metadata/0` (optional)

```elixir
@impl TinyCI.Action
def metadata do
  %TinyCI.Action.Metadata{
    name: "my_app.deploy",
    version: "1.0.0",
    inputs: [%{name: :region, type: :string, required: true}],
    capabilities: [:network]
  }
end
```

`%TinyCI.Action.Metadata{}` declares:

  * `:name` / `:version` — marketplace identity.
  * `:inputs` — input descriptors (`%{name:, type:, required:}`; build with
    `TinyCI.Action.Metadata.input/3`).
  * `:capabilities` — what the action needs. Recognized atoms come from
    `TinyCI.Action.Metadata.known_capabilities/0`: `:network`,
    `:filesystem_read`, `:filesystem_write`, `:env_read`, `:env_write`,
    `:process_spawn`.

> **Capabilities are advisory today.** They are *declared* here and become the
> basis for sandbox enforcement in a later milestone. Declaring them now keeps
> the contract stable. Unknown capability atoms raise at declaration time.

## The pipeline context

`execute/2` receives a `%TinyCI.Context{}`. Its guaranteed fields are:

  * `:branch` — current git branch
  * `:commit` — full commit SHA
  * `:changed_files` — files changed since the last commit
  * `:store` — the accumulated pipeline store (`map`)
  * `:timestamp` — when the context was built

The executor adds run-scoped keys (`:run_id`, `:artifacts_dir`, `:events`,
`:stage_env`, …) as the run progresses; treat the fields above as the stable
surface. Read the store with `ctx.store`; write to it by returning `{:ok, map}`.

## Loader verification

When a pipeline is loaded, the loader checks **before any step runs** that:

  * every `module:` step target implements `TinyCI.Action` (exports `execute/2`), and
  * every module hook target exports `run/2`.

Targets that cannot be loaded, or that lack the required callback, fail with a
descriptive error — e.g.

```
Invalid module step or hook:
  • Step :push in stage :deploy module MyApp.Deploy does not implement TinyCI.Action (missing execute/2)
```

## Generator

Scaffold a new action with a compiling module and a passing test stub:

```sh
mix tiny_ci.gen.action MyApp.Deploy
# lib/my_app/deploy.ex
# test/my_app/deploy_test.exs
```

## Back-compatibility (deprecated)

Modules that export `execute/2` **without** `use TinyCI.Action` still run — they
satisfy the contract by convention and pass loader verification. This is
**deprecated**: adopt the behaviour so the compiler checks your callbacks. No
pipeline changes are required to upgrade; add `use TinyCI.Action` and the
`@impl` annotations.

## Serializability note

T8/T16 run actions inside a sandbox or on a remote node. Keep `execute/2` pure
with respect to its boundary: take `config` + `ctx`, return a result and a store
delta. Do not smuggle PIDs, file handles, or closures across that boundary.
