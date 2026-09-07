# T3 — LSP: live diagnostics from the validator

**Phase:** 1 — Language Server · **Complexity:** M · **Depends on:** shares code with `dsl/validator.ex` · **Status:** ✅ Done

## Summary

Surface the validator's load-time errors live in-editor as the author types a
`.exs` pipeline file. Ships as a separate package `tiny_ci_lsp` that depends on core.

## Implementation checklist

- [x] Refactor `dsl/validator.ex` to return a **list** of diagnostics with
      `{line, col}` spans (a `%Diagnostic{}` struct) instead of failing fast;
      runner treats any non-empty list as failure (shared code path).
      → `TinyCI.DSL.Diagnostic`, `Validator.diagnostics/1`; `validate/1` now wraps it.
- [x] New package `tiny_ci_lsp/` (separate mix project) depending on core.
- [x] Minimal LSP server over stdio using `gen_lsp`: initialize handshake,
      `textDocument/didOpen`, `didChange`, `didSave` (+ `didClose`, `shutdown`/`exit`).
- [x] Run validator/interpreter against the buffer (no execution) and publish
      `textDocument/publishDiagnostics` with accurate ranges.
      → `Interpreter.diagnose_string/2` + `TinyCI.LSP.DiagnosticMapper`.
- [x] Debounce `didChange` (~150–300ms). → 200ms default, `:debounce_ms` option.
- [x] Editor client config documented (VS Code thin extension or Neovim built-in LSP).
      → `docs/lsp.md`.

## Acceptance criteria

- [x] `tiny_ci_lsp` starts over stdio and completes the LSP initialize handshake.
- [x] A disallowed construct (e.g. `System.cmd(...)`, unknown stage option) produces
      a diagnostic at the offending range.
- [x] Diagnostics clear when fixed, on `didChange` (debounced).
- [x] Diagnostic messages match the runner's load-time messages (shared code path).
      → asserted directly in `interpreter_test.exs`.
- [x] Verified end-to-end in at least one editor; client config documented.
      → driven through the built escript over real stdio (initialize + didOpen →
      publishDiagnostics with a clean protocol stream); editor configs in `docs/lsp.md`.

## Implementation notes

- Use `gen_lsp` (Elixir). Server lives in `tiny_ci_lsp/lib/`.
- Parse untrusted buffers **without executing** — reuse the controlled-AST
  interpreter path, never `Code.eval_string`.
- The validator diagnostics refactor lands in **core** so both runner and LSP benefit.
