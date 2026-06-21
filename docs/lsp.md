# Language server — live diagnostics

`tiny_ci_lsp` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
server that surfaces the pipeline validator's load-time errors **live in your
editor** as you type a `.exs` pipeline file. A disallowed construct
(`System.cmd(...)`, an unknown stage option, a dependency cycle, a syntax error)
is underlined at the offending range, and the squiggle clears the moment you fix
it.

It ships as a **separate package** (`tiny_ci_lsp/`) that depends on core — the
core runtime never depends on the language server, keeping the CLI lean.

## How it stays honest

The server never executes your pipeline file. It calls
`TinyCI.DSL.Interpreter.diagnose_string/2` — the same controlled-AST path the
runner uses at load time — so a message you see in-editor is **byte-for-byte the
message `mix tiny_ci.run` prints**. There is no second, drifting set of rules.

```
editor ──stdio──▶ TinyCI.LSP.Server ──▶ TinyCI.DSL.Interpreter.diagnose_string/2
   ▲                     │                       │ (parse + validate + DAG, no eval)
   │                     │                       ▼
   └──publishDiagnostics─┘◀── DiagnosticMapper ◀─ [%TinyCI.DSL.Diagnostic{}]
```

- **`TinyCI.DSL.Diagnostic`** (core) — one problem with a 1-based `{line, column}`
  span and a severity. Produced by the validator (one per allowlist violation)
  and by the interpreter (syntax errors, dependency-graph problems).
- **`TinyCI.DSL.Validator.diagnostics/1`** (core) — returns the full list of
  diagnostics with spans. `validate/1` is now a thin wrapper over it, so the
  runner and the LSP share one code path.
- **`TinyCI.LSP.Server`** — a `gen_lsp` server speaking LSP over stdio.
- **`TinyCI.LSP.DiagnosticMapper`** — converts core diagnostics (1-based) into
  LSP `Diagnostic` ranges (0-based), extending to the end of the line when only a
  start position is known.

### What is reported

1. **Syntax errors** — e.g. `missing terminator: end`, at the parser's location.
2. **Allowlist violations** — every disallowed construct or bad option, each at
   its own span (see the [DSL Allowlist](../README.md#dsl-allowlist)).
3. **Dependency-graph problems** — unknown `needs:` references and cycles, once
   the grammar is otherwise valid.

Module-existence checks are intentionally **not** run in the editor: a step's
`:module` is often uncompiled while you are still editing, so flagging it would
be noise. The runner still checks it at load time.

## Lifecycle handled

| Notification / request        | Behaviour                                            |
|-------------------------------|------------------------------------------------------|
| `initialize` / `initialized`  | Handshake; advertises full-text sync + save text     |
| `textDocument/didOpen`        | Analyze and publish immediately                      |
| `textDocument/didChange`      | Analyze and publish, **debounced** (`200ms` default) |
| `textDocument/didSave`        | Analyze and publish immediately                      |
| `textDocument/didClose`       | Clear diagnostics for the document                   |
| `shutdown` / `exit`           | Graceful shutdown                                     |

`didChange` is debounced so a burst of keystrokes results in a single analysis
once typing settles. The delay is configurable via the `:debounce_ms` start
option (used mainly by tests).

## Building

```bash
cd tiny_ci_lsp
mix deps.get
mix escript.build      # produces ./tiny_ci_lsp (a self-contained executable)
```

Copy the resulting `tiny_ci_lsp` binary somewhere on your `PATH`, or reference it
by absolute path in your editor config. It requires only an Erlang/Elixir
runtime compatible with the build (Elixir `~> 1.19`).

## Editor configuration

The server is a generic stdio LSP. Point your editor at the `tiny_ci_lsp`
executable and attach it to TinyCI pipeline files (`.tiny_ci/**/*.exs` and
`tiny_ci.exs`). Two examples follow.

### Neovim (built-in LSP, 0.11+)

```lua
vim.lsp.config.tiny_ci = {
  cmd = { "tiny_ci_lsp" },          -- absolute path if not on $PATH
  filetypes = { "elixir" },
  root_markers = { ".tiny_ci", "tiny_ci.exs", "mix.exs", ".git" },
}

-- Only attach to TinyCI pipeline files, not every Elixir file.
vim.api.nvim_create_autocmd("BufRead", {
  pattern = { "*/.tiny_ci/*.exs", "*/tiny_ci.exs" },
  callback = function() vim.lsp.enable("tiny_ci") end,
})
```

On Neovim < 0.11 use `nvim-lspconfig` with an equivalent custom server
definition (`cmd = { "tiny_ci_lsp" }`).

### VS Code (thin extension)

A minimal `vscode-languageclient` extension is enough — no language-specific
features beyond launching the server are required:

```ts
import { workspace, ExtensionContext } from "vscode";
import {
  LanguageClient,
  LanguageClientOptions,
  ServerOptions,
} from "vscode-languageclient/node";

let client: LanguageClient;

export function activate(_context: ExtensionContext) {
  const serverOptions: ServerOptions = {
    command: "tiny_ci_lsp", // absolute path if not on $PATH
    args: [],
  };

  const clientOptions: LanguageClientOptions = {
    // Attach only to pipeline files.
    documentSelector: [
      { scheme: "file", pattern: "**/.tiny_ci/**/*.exs" },
      { scheme: "file", pattern: "**/tiny_ci.exs" },
    ],
  };

  client = new LanguageClient(
    "tinyCi",
    "TinyCI",
    serverOptions,
    clientOptions,
  );
  client.start();
}

export function deactivate(): Thenable<void> | undefined {
  return client?.stop();
}
```

## Notes for contributors

- All logging goes to **stderr** — stdout is reserved for the JSON-RPC stream and
  any stray byte there corrupts the protocol. `TinyCI.LSP.CLI.main/0` enforces
  this at runtime.
- `gen_lsp` stops the VM when the transport reaches EOF (so the server exits when
  the editor disconnects). Tests disable that via
  `config :gen_lsp, exit_on_end: false` in `config/config.exs`.
- End-to-end tests use `GenLSP.Test` (a TCP transport) to drive the real server
  through the initialize handshake and the diagnostic publish/clear cycle.
