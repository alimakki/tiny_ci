# Action registry

tiny_ci actions are ordinary Hex packages (see [supply chain](./actions.md) —
`mix.lock` *is* the action lockfile). The **registry** is a thin, curated index
*over* those packages: a way to discover well-made, locked, typed actions and to
see each one's blast radius before you wire it into a pipeline.

The design goal is the deliberate opposite of a vast unaudited marketplace —
**small, curated, verifiable**. The registry adds no runtime service and no new
trust root; it is metadata generated from packages you already depend on.

## How a package self-identifies

A package advertises the actions it ships by listing their modules in its
application environment under the `:tiny_ci_actions` key. In the package's
`mix.exs`:

```elixir
def application do
  [
    env: [
      tiny_ci_actions: [Acme.Deploy, Acme.Notify]
    ]
  ]
end
```

Because this lives in the compiled `.app` file, the index builds
**programmatically** by scanning installed dependencies — no network, and no
separate manifest to drift out of sync. Everything else an entry needs (name,
version, inputs, declared capabilities) comes from each module's
[`metadata/0`](../lib/tiny_ci/action/metadata.ex):

```elixir
defmodule Acme.Deploy do
  use TinyCI.Action

  @moduledoc "Ships a release to production over SSH."

  @impl true
  def metadata do
    %TinyCI.Action.Metadata{
      name: "acme.deploy",
      version: "1.2.0",
      capabilities: [:network, :env_read],
      inputs: [%{name: :app, type: :string, required: true}]
    }
  end

  @impl true
  def execute(config, ctx), do: # ...
end
```

The module's `@moduledoc` first line becomes the entry's one-line summary.

## Searching

```bash
# scan locally-installed action packages
mix tiny_ci.actions.search deploy

# filter by blast radius or review tier
mix tiny_ci.actions.search --capability network
mix tiny_ci.actions.search deploy --tier verified

# search a generated static index instead of scanning
mix tiny_ci.actions.search deploy --index actions.json
```

Each result shows the package, version, declared capabilities (its blast radius),
and review tier:

```
1 action(s) matching "deploy":

  acme.deploy  1.2.0  [verified]
      acme_actions — Acme.Deploy
      caps: network, env_read
      Ships a release to production over SSH.
```

The term matches case-insensitively against an action's name, package, module,
and summary.

## Generating a static index

The v1 registry is a generated, checkable JSON artifact rather than a hosted
service:

```bash
mix tiny_ci.actions.index --out actions.json
```

This scans installed packages and writes an index like:

```json
{
  "actions": [
    {
      "package": "acme_actions",
      "version": "1.2.0",
      "module": "Acme.Deploy",
      "name": "acme.deploy",
      "summary": "Ships a release to production over SSH.",
      "capabilities": ["network", "env_read"],
      "inputs": [{"name": "app", "type": "string", "required": true}],
      "tier": "unreviewed"
    }
  ]
}
```

## Review tiers

A freshly scanned entry is always `:unreviewed` — the scan reports *what a package
claims about itself*, nothing more. Curated tiers are **editorial** and are not
derivable from the package, so they live in a separate, checked-in **overlay**
index that assigns tiers to specific actions. Generating with an overlay layers
the two:

```bash
mix tiny_ci.actions.index --overlay curated.json --out actions.json
```

The scan supplies live version and capability data; the overlay supplies the
tier. An action present only in the overlay (curated but not installed locally)
is still listed.

| Tier | Meaning |
|------|---------|
| `verified` | Reviewed against the checklist below; recommended. |
| `community` | Known and listed, not formally reviewed. |
| `unreviewed` | Self-reported by the package; no review performed. |

### Submission / review checklist

An action qualifies for the `verified` tier when:

- [ ] **Source is available** and the package builds from it.
- [ ] **Minimal capabilities** — it declares only the capabilities it actually
      uses (`network`, `filesystem_read/write`, `env_read/write`,
      `process_spawn`), and no undeclared network or filesystem access exists.
- [ ] **Tests are present** and cover the action's `execute/2` contract.
- [ ] **Metadata is complete** — `name`, `version`, `inputs`, and `capabilities`
      are declared, and the module self-identifies via `:tiny_ci_actions`.
- [ ] **Pinned** — the package is a normal Hex dependency, so `mix.lock` pins it
      by checksum (verified at run start; see [supply chain](./actions.md)).

## Design notes

- **No bespoke registry service in v1.** A generated static JSON index is enough
  until there's demand for more; a future network scanner can discover packages
  by the same `:tiny_ci_actions` marker.
- The registry is **purely additive metadata** — it never runs actions, never
  reaches into executor internals, and imposes no dependency on core. It reads
  the same [`Metadata`](../lib/tiny_ci/action/metadata.ex) that lockfile
  resolution and (from T8) sandbox policy rely on.
