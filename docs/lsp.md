# Language server — diagnostics, completion, hover

`tiny_ci_lsp` is a [Language Server Protocol](https://microsoft.github.io/language-server-protocol/)
server that gives `.exs` pipeline files a full editing experience **live in your
editor**:

- **Diagnostics** — a disallowed construct (`System.cmd(...)`, an unknown stage
  option, a dependency cycle, a syntax error) is underlined at the offending
  range, and the squiggle clears the moment you fix it.
- **Completion** (`textDocument/completion`) — context-aware suggestions for
  directives, option keys, and condition primitives.
- **Hover** (`textDocument/hover`) — a one-line description plus an example for
  the symbol under the cursor.

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

## Completion and hover

Completion and hover read from a single, machine-readable description of the DSL
in core, **`TinyCI.DSL.Spec`** — every directive, every option key with its type,
and every condition primitive, each with a one-line summary and an example. The
validator derives its allowlist of permitted option keys from the same Spec, so
what the editor offers is exactly what the validator accepts. There is no second
list to keep in sync.

```
editor ──completion/hover──▶ TinyCI.LSP.Server
                                  │
              ┌───────────────────┴───────────────────┐
              ▼                                         ▼
   TinyCI.LSP.Context                          TinyCI.LSP.Hover
   (walks the AST around the cursor)           (symbol under cursor)
              │                                         │
              ▼                                         ▼
   TinyCI.LSP.Completion ───▶ TinyCI.DSL.Spec ◀─── TinyCI.DSL.Spec.lookup
                              (single source of truth)
```

- **`TinyCI.DSL.Spec`** (core) — the directive/option/primitive catalogue.
- **`TinyCI.LSP.Context`** — determines the cursor context by walking the AST
  (`Code.Fragment.container_cursor_to_quoted/1`), **not** by matching text. The
  buffer is usually incomplete while typing, so the fragment API closes the open
  containers and inserts a cursor marker we walk to.
- **`TinyCI.LSP.Completion`** — turns a context into `CompletionItem`s from the Spec.
- **`TinyCI.LSP.Hover`** — finds the symbol under the cursor with
  `Code.Fragment.surround_context/2`, looks it up in the Spec, and renders Markdown.

### What completion offers, by cursor context

| Cursor is …                              | Suggestions                                                            |
|------------------------------------------|------------------------------------------------------------------------|
| at file scope                            | `name`, `env`, `stage`, `on_success`, `on_failure`                     |
| inside `stage do … end`                  | `step`, `env`                                                          |
| inside `step` / hook `do … end`          | `set`                                                                  |
| in a `stage` option list                 | `mode:`, `needs:`, `when:`, `working_dir:`, `matrix:`, `max_parallel:`, `allow_failure:` |
| in a `step` option list                  | `cmd:`, `module:`, `env:`, `timeout:`, `when:`, `retry:`, `cache:`, … |
| in a hook option list                    | `cmd:`, `module:`, `env:`, `timeout:`                                  |
| inside a `when:` value                   | `branch()`, `env(...)`, `file_changed?(...)`                           |

## Lifecycle handled

| Notification / request        | Behaviour                                            |
|-------------------------------|------------------------------------------------------|
| `initialize` / `initialized`  | Handshake; advertises sync, completion, hover        |
| `textDocument/didOpen`        | Track buffer; analyze and publish immediately        |
| `textDocument/didChange`      | Track buffer; analyze and publish, **debounced** (`200ms`) |
| `textDocument/didSave`        | Track buffer; analyze and publish immediately        |
| `textDocument/didClose`       | Drop the buffer; clear diagnostics                   |
| `textDocument/completion`     | Context-aware suggestions from the DSL spec          |
| `textDocument/hover`          | Description + example for the symbol under the cursor |
| `shutdown` / `exit`           | Graceful shutdown                                    |

The server keeps the latest text of each open document (updated immediately on
`didChange`, before the debounced diagnostic publish) so completion and hover
always see the live buffer.

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

A ready-to-build client lives in **[`editors/vscode/`](../editors/vscode/)**. The
server binary alone does nothing in VS Code — the editor needs a client extension
to launch it and attach it to pipeline files. Quick start:

```bash
cd tiny_ci_lsp && mix escript.build     # build the server (mise does this on enter)
cd ../editors/vscode && npm install     # the client's one dependency
```

Then either press <kbd>F5</kbd> with `editors/vscode/` open (Extension Development
Host), or package and install it:

```bash
cd editors/vscode
npx --yes @vscode/vsce package
code --install-extension tiny-ci-lsp-0.1.0.vsix
```

The extension finds the server at `<workspace>/tiny_ci_lsp/tiny_ci_lsp`, falls
back to `tiny_ci_lsp` on `PATH`, and honours a `tinyCi.serverPath` setting. It
attaches only to `**/.tiny_ci/**/*.exs` and `tiny_ci.exs`. See
[`editors/vscode/README.md`](../editors/vscode/README.md) for details and
troubleshooting.

> Note: a server binary is not enough on its own — without this client (or the
> Neovim config above) VS Code shows no diagnostics, completion, or hover.

## Notes for contributors

- All logging goes to **stderr** — stdout is reserved for the JSON-RPC stream and
  any stray byte there corrupts the protocol. `TinyCI.LSP.CLI.main/0` enforces
  this at runtime.
- `gen_lsp` stops the VM when the transport reaches EOF (so the server exits when
  the editor disconnects). Tests disable that via
  `config :gen_lsp, exit_on_end: false` in `config/config.exs`.
- End-to-end tests use `GenLSP.Test` (a TCP transport) to drive the real server
  through the initialize handshake and the diagnostic publish/clear cycle.
