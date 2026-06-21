# tiny_ci_lsp

A [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
server for [`tiny_ci`](../) pipeline files. It surfaces the pipeline validator's
load-time errors live in your editor as you type — without ever executing the
file.

This package depends on core (`{:tiny_ci, path: ".."}`); core never depends on
it. Diagnostics come from the shared `TinyCI.DSL.Interpreter.diagnose_string/2`
path, so in-editor messages match what `mix tiny_ci.run` prints.

## Build

```bash
mix deps.get
mix escript.build   # produces ./tiny_ci_lsp
```

## Test

```bash
mix test
```

Full architecture and editor configuration (Neovim, VS Code) live in
[`../docs/lsp.md`](../docs/lsp.md).
