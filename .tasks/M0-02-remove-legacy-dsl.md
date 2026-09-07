# M0-02 — Remove the macro DSL, the old validator, and scaffold leftovers

**Milestone:** M0 · **Size:** S · **Depends on:** — · **Status:** ✅ Done (2026-09-07)
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

Two pipeline definition paths ship today:

1. The **interpreted** flat-file DSL (`TinyCI.DSL.Interpreter` + `TinyCI.DSL.Validator` +
   `TinyCI.DSL.Spec`). This is the real one: the CLI, the LSP, and the docs use it.
2. The **macro** DSL (`use TinyCI.DSL` in `lib/tiny_ci/dsl.ex`), which compiles a module and
   generates `__pipeline__/0`. It funnels through `TinyCI.Pipeline.normalize_stage/1`, which
   only maps `name`, `mode`, `when`, and steps — it **silently drops** `needs:`, `matrix:`,
   `working_dir:`, `env`, `retry:`, `cache:` and `max_parallel:`. It also uses a second,
   older validator (`lib/tiny_ci/validator.ex`).

Path 2 is dead weight with a sharp edge. Remove it, along with the `mix new` scaffold module
`TinyCi` (`lib/tiny_ci.ex`, `hello/0`) and the demo file `lib/test_pipleline.ex` (sic), which
compiles into the library.

## In scope

Delete:

- `lib/tiny_ci/dsl.ex` (module `TinyCI.DSL`; the macro DSL)
- `lib/tiny_ci/pipeline.ex` (module `TinyCI.Pipeline`)
- `lib/tiny_ci/validator.ex` (module `TinyCI.Validator`; superseded by `TinyCI.DSL.Validator`)
- `lib/tiny_ci.ex` (module `TinyCi` with `hello/0`)
- `lib/test_pipleline.ex` (modules `MyApp.Pipeline`, `DeployStep`)
- `test/tiny_ci/dsl_test.exs`, `test/tiny_ci/pipeline_test.exs`,
  `test/tiny_ci/validator_test.exs`, `test/tiny_ci_test.exs`

Rewrite:

- `test/tiny_ci/integration_test.exs` — every test that builds a `defmodule ... use TinyCI.DSL`
  string and compiles it must instead build a flat pipeline string and load it with
  `TinyCI.DSL.Interpreter.interpret_string(source, "integration.exs")`. The interpreted
  format is documented in `README.md` → "DSL Reference" and in the interpreter's `@moduledoc`.
  Preserve every assertion; only the way the spec is produced changes. Tests already labelled
  "(new format via interpreter)" show the target shape.

Keep:

- `TinyCI.Stage.when_condition` accepting a 1-arity function **as well as** a condition AST.
  `TinyCI.Executor.skip_stage?/2` and `skip_step?/2` have clauses for both; executor tests
  build stages with functions directly. Do not remove those clauses.
- The validator's rejection message that mentions `use TinyCI.DSL`
  (`lib/tiny_ci/dsl/validator.ex` around line 119) and the test in
  `test/mix/tasks/tiny_ci_run_test.exs` ("returns validation error for legacy defmodule
  format"). Rejecting the old shape with a helpful message stays valuable.

## Out of scope

- Any change to the interpreted DSL or its validator.
- Renaming the `TinyCI.DSL.*` namespace (the parent module disappearing is fine in Elixir).

## Read first

- `lib/tiny_ci/dsl.ex`, `lib/tiny_ci/pipeline.ex`, `lib/tiny_ci/validator.ex` — confirm nothing
  outside the delete list calls them: `grep -rn "TinyCI.Pipeline\b\|TinyCI.Validator\b\|use TinyCI.DSL" lib test docs`.
- `test/tiny_ci/integration_test.exs` — note which describes use the macro format.
- `lib/tiny_ci/dsl/interpreter.ex` — `interpret_string/2`.
- `README.md` → "Project Structure" (around line 960) lists the files being removed.
- `docs/custom-dsl-design.md` — mentions the old format historically; keep the history but make
  sure nothing reads as current guidance.

## Design

There is no new design. The one judgement call: the integration tests currently define
module steps inline in the compiled string (e.g. a `DeployStep` module) and refer to them via
`module:`. With the interpreted format, a module step's module must already be loaded. Move
any such module into `test/support/integration_fixtures.ex` as
`TinyCI.IntegrationFixtures.<Name>` (use `use TinyCI.Action`) and reference it from the
pipeline string with its full name.

## TDD plan

This task removes code, so the "tests first" step is making the surviving tests prove the
behaviour the deleted tests covered.

1. Run `mix test test/tiny_ci/integration_test.exs` and list every test that compiles a
   `use TinyCI.DSL` module. For each, write the interpreted-format twin **next to it** (same
   assertions, `interpret_string/2` instead of `Code.compile_string`), run both, and only then
   delete the macro version.
2. `grep -rn "hello\b" test lib` — confirm `TinyCi.hello/0` has no callers besides its doctest.
3. Delete the files in the **In scope** list. `mix compile --warnings-as-errors` must pass with
   zero references left.
4. Run the full suite. The count drops by the number of deleted tests; nothing else changes.
5. Update `README.md` "Project Structure": remove `dsl.ex` ("Macro-based DSL"), `pipeline.ex`,
   `validator.ex` (the old one; keep `dsl/validator.ex`), `tiny_ci.ex`'s description if it
   lists the scaffold, and add nothing new.
6. Run `mix tiny_ci.run` at the repo root.

## Acceptance criteria

- [x] `grep -rn "use TinyCI.DSL" lib` returns only the validator's rejection message.
      (Verified by grep; `test/mix/tasks/tiny_ci_run_test.exs` "returns validation error for
      legacy defmodule format" still proves the rejection.)
- [x] `grep -rn "TinyCI.Pipeline\b\|TinyCI.Validator\b\|TinyCi\b" lib test` returns nothing
      except the `Mix.Tasks.TinyCi.*` task module names. (Verified by grep;
      `mix compile --warnings-as-errors` passes with zero references.)
- [x] `lib/test_pipleline.ex` and `lib/tiny_ci.ex` no longer exist.
- [x] Every assertion previously made in the macro-format integration tests is made by an
      interpreted-format test. The nine rewritten tests in `test/tiny_ci/integration_test.exs`:
      "multi-stage passing pipeline produces correct results and output", "pipeline halts on
      stage failure and reports correctly", "conditional stage is skipped based on context",
      "module step receives config and context end-to-end", "env variables flow through DSL to
      execution", "timeout kills slow step in end-to-end run", "module step reads store from
      context across stages", "allow_failure step does not fail the stage end-to-end",
      "module-based on_success hook receives context with pipeline_result".
- [x] `mix compile --warnings-as-errors`, `mix test` (930 passed, 7 excluded), `mix credo` pass.
- [x] README Project Structure: the `dsl.ex` (macro DSL) and `dsl_test.exs` entries are removed
      and nothing was added, per TDD plan step 5. See Deviations.

## Pitfalls

- `Code.compile_string/1` in tests leaves modules loaded for the rest of the VM. After
  rewriting, make sure no other test depended on a module defined by a deleted test.
- The interpreted format needs stage/step names as **atoms** and `cmd:` values as strings;
  the macro tests sometimes used parenthesised `step(:x, cmd: ...)` — the flat DSL accepts
  both, but the validator only allows the constructs in `TinyCI.DSL.Spec`.

## Docs

- README Project Structure (see step 5).
- `docs/custom-dsl-design.md`: if it presents the macro DSL as an alternative, add a one-line
  note that it was removed in M0-02.

## Deviations

- The README "Project Structure" listing was already a curated subset of `lib/` before this task
  (it omits `sandbox/`, `provenance/`, `registry/`, `action/`, `control/`, the extra Mix tasks,
  and more). TDD plan step 5 says to remove the deleted entries and "add nothing new", so the
  listing is not a literal match for `find lib -name '*.ex'`. Bringing it up to date is a docs
  task in its own right.
- `lib/tiny_ci/pipeline.ex` and `lib/tiny_ci/validator.ex` were never listed in the README, so
  only `dsl.ex` and `dsl_test.exs` were removed from it.
- The `env variables flow through DSL to execution` test used a `~s(...)` sigil for the command
  in the macro format. The interpreted DSL requires `cmd:` to be a string literal, so the
  rewritten test uses an escaped double-quoted string that yields the same shell command.
- The integration test's inline `ImageTagger` / `StoreVerifier` / `Notifier` / `HookNotifier`
  modules were moved to `test/support/integration_fixtures.ex` and the two already-interpreted
  tests that referenced `TinyCI.IntegrationTest.ImageTagger` now reference the fixture.
- `lib/tiny_ci/hooks.ex` and `lib/tiny_ci/pipeline_spec.ex` docs referred to
  `module.__hooks__/0` / `module.__pipeline__/0`; reworded to refer to `%PipelineSpec{}`.

## Follow-ups

- README "Project Structure" is stale relative to `lib/` (see Deviations); regenerate it.
