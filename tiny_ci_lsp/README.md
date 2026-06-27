# tiny_ci_lsp

A [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
server for [`tiny_ci`](../) pipeline files. As you type — without ever executing
the file — it provides:

- **diagnostics** — the pipeline validator's load-time errors, live;
- **completion** — context-aware directives, option keys, and condition primitives;
- **hover** — a one-line description and example for the symbol under the cursor.

This package depends on core (`{:tiny_ci, path: ".."}`); core never depends on
it. Diagnostics come from the shared `TinyCI.DSL.Interpreter.diagnose_string/2`
path, so in-editor messages match what `mix tiny_ci.run` prints. Completion and
hover read from `TinyCI.DSL.Spec`, the same single source of truth the
validator's allowlist derives from.

## Build

```bash
mix deps.get
mix escript.build   # produces ./tiny_ci_lsp
```

The build always runs in `MIX_ENV=prod` (enforced by `cli/0` in `mix.exs`) so
core's dev-only deps (`tidewave`, `bandit`) stay out of the binary — their
startup output would otherwise corrupt the LSP stdio stream. Don't build with
`MIX_ENV=dev`.

## Test

```bash
mix test
```

Full architecture and editor configuration (Neovim, VS Code) live in
[`../docs/lsp.md`](../docs/lsp.md).
