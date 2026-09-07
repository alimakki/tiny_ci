# M6-04 — DAP server: debug pipelines in the editor

**Milestone:** M6 · **Complexity:** L · **Depends on:** T10 (reuses T11, T15) · **Status:** ⬜ Not started

> **Carried over from the earlier plan (2026-07).** This task is scheduled in **M6** and must be
> re-specified against the M2 server (`TinyCI.Server.Run`, the event bus, the runs store) and the
> M3 UI before work starts: update *Depends on*, add a **Read first** list, a **TDD plan**, and
> the shared **Definition of done** from `CONVENTIONS.md`. The design intent below still holds.

## Summary

A [Debug Adapter Protocol](https://microsoft.github.io/debug-adapter-protocol/)
server — the sibling of the LSP — so authors set **gutter breakpoints** in a
`.exs` pipeline file, hit them during a run, and inspect the store/context in the
editor's **Variables** panel. Debug the pipeline like code, in the same editor
used to write it. DAP is the standard protocol VS Code and Neovim already speak,
so this unifies the execution-control primitives (T10/T11/T15) behind one surface
the way the LSP unified diagnostics/completion/hover.

## Implementation checklist

- [ ] New package `tiny_ci_dap/` (or a sibling module to the LSP) speaking DAP
      over stdio; depends on core, never the reverse.
- [ ] `setBreakpoints` (file + line) → T10 step/stage breakpoints, resolving the
      line to a step/stage by walking the AST (reuse the T5 position model).
- [ ] `launch`/`attach` a run; `continue`/`next`/`stepIn`/`pause`/`disconnect`
      → T10 control commands.
- [ ] `scopes`/`variables` at a stop: expose store, context, resolved env, matrix
      combo, and the step's `set/2` config.
- [ ] `setVariable` on a store key → T10 `set_store` (and feeds a T17 re-run).
- [ ] `stepIn` on a module step → a T15 source-level session where available;
      cleanly report "unavailable" for sandboxed/third-party actions.
- [ ] Conditional breakpoints → T11 (reuse the `when:` grammar; no new language).
- [ ] Editor docs: VS Code `launch.json` and a Neovim DAP config; extend the
      existing VS Code client in `editors/vscode/`.

## Acceptance criteria

- [ ] A gutter breakpoint on a step line in VS Code pauses the run at that step.
- [ ] The Variables panel shows the live store/context; editing a value updates
      the store and the resumed run sees it.
- [ ] continue / step / pause map to execution control and resume correctly.
- [ ] Conditional breakpoints honour the `when:` grammar.
- [ ] Verified end-to-end in at least one editor; client config documented.

## Implementation notes

- DAP is to debugging what LSP is to authoring — same strategic bet, same package
  shape and "thin client / smart server" split.
- Line → step/stage resolution reuses the AST position work from T5.
- Keep the adapter a pure consumer of T1 events + sender of T10 control, so it
  works unchanged against local, sandboxed (T8), or remote (T16) runs.
