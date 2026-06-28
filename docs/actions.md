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
  * `:outputs` — store keys (atoms) the action writes via its `{:ok, map}`
    return. Declaring them lets the language server reason about store dataflow
    (`store(:k)` readers vs. writers).
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

## Supply chain: action resolution & the lockfile

Third-party actions are ordinary **Hex dependencies**. You declare them in your
project's `mix.exs` and `mix deps.get` resolves them, so **`mix.lock` *is* the
action lockfile** — every action and transitive dependency is pinned to an exact
version and the checksum Hex verified at fetch time. There is no separate
lockfile to drift out of sync.

```elixir
# mix.exs — an action is just a dependency
{:acme_deploy, "~> 1.2"}
```

```elixir
# .tiny_ci/pipeline.exs — reference a module the package provides
step :ship, module: Acme.Deploy
```

### Resolution & run-start verification

A `module:` target resolves to its owning Hex package via the OTP application
that provides it. **Before any step runs**, `mix tiny_ci.run` verifies every
action:

  * **Locked (hex)** — the package is pinned in `mix.lock` and the loaded version
    matches the locked one. A mismatch aborts the run (your build has drifted from
    the lock — run `mix deps.get`).
  * **Unlocked** — a third-party action whose package is **absent from the
    lockfile** aborts the run. Unpinned actions **fail closed**; there is no
    silent fetch.
  * **First-party / local** — your own project's modules (and modules with no
    owning package) need no pin.
  * **Git / path deps** — allowed, but surfaced as *not* hash-pinned by Hex.

This eliminates the mutable-tag supply-chain risk of `uses: org/action@v1`-style
references that can change under you.

### Auditing

`mix tiny_ci.actions.audit` prints the resolved action tree — each action's
package, version, pinned checksum, and status — and exits non-zero if anything
is unsound, so it is usable as a CI gate:

```sh
mix tiny_ci.actions.audit            # the default pipeline
mix tiny_ci.actions.audit deploy     # .tiny_ci/deploy.exs
```

### What the lockfile covers (and what it doesn't)

The lockfile pins the **BEAM automation layer** — the action packages that run
your pipeline. It does **not** pin binaries those actions (or `cmd:` steps) shell
out to: `apt`/`brew` packages, Docker base images, `npm`/`pip` installs, etc.
Pin those with their own ecosystems' lockfiles and digests. This is a deliberate
boundary: action *authors* bind to the BEAM, while general workloads stay
language-agnostic behind `cmd:` steps.

> **Verification boundary.** Hex verifies each package's tarball checksum at
> fetch and records it in `mix.lock`. TinyCI verifies at run start that every
> action is present in the lock and the loaded version matches, and surfaces the
> pinned checksums — it does not re-hash already-installed files. Use a private
> or self-hosted Hex repository for enterprise/air-gapped resolution; the lock
> records each package's `repo`, so resolution is registry-agnostic.

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
