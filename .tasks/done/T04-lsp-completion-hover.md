# T4 — LSP: completion and hover

**Phase:** 1 — Language Server · **Complexity:** M · **Depends on:** T3 · **Status:** ✅ Done

## Summary

Context-aware autocomplete for directives and option keys, plus hover docs, so
authors write pipelines without constantly checking the docs.

## Implementation checklist

- [x] Create one canonical `TinyCI.DSL.Spec` in **core** describing every directive,
      its valid contexts, options (with types), and a docstring.
      → `TinyCI.DSL.Spec` + `TinyCI.DSL.Spec.Entry`.
- [x] Make the validator allowlist, LSP completion/hover, and (ideally) README
      generator all read from `TinyCI.DSL.Spec` — single source of truth.
      → validator derives its permitted option keys from `Spec.option_keys/1`
      (sync test in `validator_test.exs`); completion/hover read the Spec; README
      DSL-allowlist section documents the Spec as the source.
- [x] `textDocument/completion` for directives (`stage`, `step`, `on_success`, …).
- [x] Context-aware option-key completion (stage options inside `stage`, step
      options inside `step`). → `TinyCI.LSP.Completion` keyed on `TinyCI.LSP.Context`.
- [x] Completion for condition primitives (`branch()`, `env()`, `file_changed?()`).
- [x] `textDocument/hover` with one-line description + example for symbol under cursor.
      → `TinyCI.LSP.Hover` + `TinyCI.LSP.Doc`.
- [x] Determine cursor context by walking the AST/enclosing block (not regex).
      → `TinyCI.LSP.Context` via `Code.Fragment.container_cursor_to_quoted/1`;
      hover symbol via `Code.Fragment.surround_context/2`.

## Acceptance criteria

- [x] Inside `stage do … end` offers `mode:`, `needs:`, `when:`, `working_dir:`,
      `matrix:`, `max_parallel:`, `allow_failure:`; inside `step` offers step options.
- [x] Top level offers `name`, `env`, `stage`, `on_success`, `on_failure` (+ added directives).
- [x] Condition context offers `branch()`, `env(...)`, `file_changed?(...)`.
- [x] Hover shows a one-line description + example.
- [x] Completion + hover derive from a single machine-readable DSL spec (not duplicated).

## Implementation notes

- The `TinyCI.DSL.Spec` refactor is the highest-leverage work in the LSP phase — do it here.
- Cursor context is derived from the AST, never regex: `container_cursor_to_quoted/1`
  closes the open containers around the cursor (the buffer is usually incomplete
  while typing) and inserts a `{:__cursor__, _, _}` marker that `TinyCI.LSP.Context`
  walks to, tracking the enclosing directive/block.
- The server keeps each open document's latest text (updated immediately on
  `didChange`, ahead of the debounced diagnostic publish) so completion and hover
  always see the live buffer.
