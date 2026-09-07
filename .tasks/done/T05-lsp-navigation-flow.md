# T5 — LSP: navigation and flow-aware diagnostics

**Phase:** 1 — Language Server · **Complexity:** M–L · **Depends on:** T3, T4 · **Status:** ✅ Done

## Summary

Go-to-definition and semantic warnings about stage dependencies and the pipeline
store — catching wiring mistakes the syntactic validator can't see.

## Implementation checklist

- [x] Go-to-definition for `needs: [:x]` → the `stage :x` declaration.
      → `TinyCI.LSP.Definition` (`textDocument/definition`).
- [x] Go-to-definition for `module:` references → the module (if on the load path).
      → resolves via `module_info(:compile)[:source]`; uncompiled modules don't resolve.
- [x] Flow diagnostic: undefined `needs:` target. → `TinyCI.DSL.FlowAnalysis`.
- [x] Cycle detection highlighted inline (reuse `dag.ex`).
      → `FlowAnalysis` calls `DAG.build_levels/1`, anchors a diagnostic per member.
- [x] Store-key dataflow pass: collect writers (module step outputs from
      `metadata/0`) and readers (`store(:k)` anywhere).
      → added `:outputs` to `TinyCI.Action.Metadata`; readers via AST `store(...)` nodes.
- [x] Warn when `store(:k)` is read but no step writes `:k`.
- [x] Warn when two parallel steps write the same store key.
- [x] Downgrade to info-level hint when writers can't be statically known.

## Acceptance criteria

- [x] Go-to-definition on a `needs:` symbol jumps to the `stage` declaration.
- [x] A `needs:` referencing a non-existent stage produces a diagnostic.
- [x] A dependency cycle is reported inline (reuse `dag.ex`).
- [x] `store(:image_tag)` read with no writer produces a warning naming the key.
- [x] Two parallel steps writing the same key produce a warning on both.

## Implementation notes

- Reuse `dag.ex` for cycle/needs analysis.
- Store-key analysis needs each action's declared outputs from `metadata/0`.
  Added the `:outputs` field to `TinyCI.Action.Metadata` here (a small, forward-
  compatible extension of the T2 contract) so writers are statically knowable.
- Positions: `stage`/`step` calls and `store(...)` carry `line`/`column` in the
  AST; `needs:` atoms are bare, so those diagnostics anchor to the `stage` call.
- Concurrency for the duplicate-writer check: same `mode: :parallel` stage, or
  two stages unordered by `needs:` in DAG mode. Sequential stages never conflict.
- `FlowAnalysis` runs from `Interpreter.diagnose_string/2` (LSP path), replacing
  the older position-free `dag_diagnostics`. The runner's hard `DAG.validate`
  path is unchanged; store warnings are editor-only/advisory.
