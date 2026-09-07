# T2 — Formalize the action contract (`TinyCI.Action` behaviour)

**Phase:** 0 — Foundations · **Complexity:** M · **Depends on:** none (unblocks T6–T9) · **Status:** ✅ Done

## Summary

Turn the informal "module with `execute/2`" convention into a real, typed,
documented behaviour that module steps (and hooks) implement — the foundation for
the marketplace, lockfile resolution, sandboxing, and provenance.

## Current state (already in repo)

- Module steps implement `execute/2` by convention (`executor.ex` calls
  `apply(module, :execute, [config, ctx])`); hooks implement `run/2`
  (`hooks.ex`).
- `TinyCI.Context` is a plain **map** built by `Context.build/1`; the executor
  adds many dynamic keys (`:store`, `:stage_env`, `:pipeline_env`, `:no_cache`,
  `:run_id`, `:artifacts_dir`, `:env`, `:root`).
- `Context.build/1` allows arbitrary overrides (doctest uses `pr_number: 42`).

## Implementation checklist

- [x] `TinyCI.Action` behaviour in `lib/tiny_ci/action.ex`:
      `@callback execute(config :: keyword, ctx :: TinyCI.Context.t()) :: :ok | {:ok, map()} | {:error, term()}`.
- [x] Optional `@callback metadata() :: TinyCI.Action.Metadata.t()` (`@optional_callbacks`).
- [x] `TinyCI.Action.Metadata` struct in `lib/tiny_ci/action/metadata.ex` with
      `:name`, `:version`, `:inputs` (name/type/required), `:capabilities`
      (`[:network, :filesystem_write, :env_read, ...]`). Unknown capabilities raise.
- [x] Promoted `TinyCI.Context` to a struct + typespec; preserved existing fields
      (`branch`, `commit`, `changed_files`, `store`, `timestamp`); `build/1` still
      accepts arbitrary overrides (merged onto the struct) so module steps still read `ctx.store`.
- [x] Loader (`DSL.Interpreter` → `TinyCI.Action.validate_spec/1`) verifies a `module:`
      step target implements the behaviour (`execute/2`) and a hook module exports
      `run/2`; fails with a descriptive error **before execution** otherwise.
- [x] `mix tiny_ci.gen.action MyApp.Deploy` generator scaffolds a compiling module
      implementing the behaviour + a passing ExUnit test stub.
- [x] Back-compat shim: modules using the old `execute/2` convention still run and pass
      loader verification (documented as deprecated in `docs/actions.md` and the README).

## Acceptance criteria

- [ ] `TinyCI.Action` defines the `execute/2` callback with documented return semantics.
- [ ] Optional `metadata/0` declares `:name`, `:version`, `:inputs`, `:capabilities`.
- [ ] `TinyCI.Context` is a struct with a typespec; existing fields preserved;
      module steps still read `ctx.store`.
- [ ] Validator/loader verifies a `module:` target implements `TinyCI.Action`
      (`function_exported?/3` or behaviour reflection) and fails descriptively.
- [ ] `mix tiny_ci.gen.action MyApp.Deploy` generates module + passing test stub.
- [ ] All existing pipelines/tests pass unchanged (back-compat shim acceptable,
      documented as deprecated).

## Implementation notes

- Capabilities are **declared** here, **enforced** in T8 — design the field now to
  avoid a breaking change later; treat as advisory until then.
- Keep `set/2` config flowing into the keyword list exactly as today.
- Gotcha: don't couple the behaviour to an execution location. T8/T16 run actions
  in a sandbox / remote node, so the contract must be serializable in spirit
  (config + context in, result + store-delta out). Avoid PIDs/file handles/closures
  across the boundary.
