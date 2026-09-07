# Working a task — conventions for implementing agents

Every task file in this directory is written to be picked up cold by an agent and finished
without further clarification. This file holds the rules that apply to all of them so the
task files can stay focused on *what* and *why*.

## Before you start

1. Read [`AGENTS.md`](../AGENTS.md) (Elixir style guide) and [`ROADMAP.md`](../ROADMAP.md).
2. Read the task file top to bottom, then every file under its **Read first** section. Do not
   start typing until you can explain the current behaviour of each of those files.
3. Check the task's **Depends on** line. If a dependency is not ✅ in `INDEX.md`, stop and say so.
4. Run `mix test` once before changing anything so you know the baseline is green
   (1011 tests as of 2026-09-07; 7 are excluded on hosts without a given sandbox backend).

## Test-first workflow

Work in red → green → refactor loops, one behaviour at a time. The task's **TDD plan** is
ordered for this: each numbered item names the test to write *first* and the production
change that makes it pass.

- Write the test exactly where the plan says. Use `describe "fun/arity"` blocks and
  `use ExUnit.Case, async: true` unless the test touches shared global state (the file
  system outside `@tag :tmp_dir`, application env, named processes), in which case
  `async: false` with a comment explaining why.
- Run only the new test file first (`mix test path/to/test.exs`), watch it fail for the
  *right reason*, then implement, then run the full suite.
- Prefer real processes and real files over mocks. Use `@tag :tmp_dir` for filesystem tests;
  the `tmp_dir` is passed in the test context. Use fixture modules under `test/support/`
  (compiled into the test build via `elixirc_paths`) when a test needs an action module.
- Never `Process.sleep/1` to wait for something. Use `assert_receive`, monitors, or a
  polling helper with a deadline. The suite currently finishes in about six seconds; keep it
  that way.
- Tests that start OS processes must leave none behind. Follow the pattern in
  `test/tiny_ci/executor_test.exs` ("leaves no orphaned OS processes"): tag the command with
  a unique marker and `pgrep` for it after the run.
- Doctests are welcome for pure functions. Add `doctest Module` to the module's test file.

## Scope discipline

- Implement the task's **In scope** list and nothing else. If you find an adjacent bug, note
  it under "Follow-ups" at the bottom of the task file instead of fixing it.
- Do not rename or move existing modules unless the task says to.
- Do not add a dependency unless the task's **Dependencies added** section lists it.
- Keep `lib/tiny_ci/**` free of `Mix.*` calls at runtime (M1-02 makes this a test).
- Keep the human console output byte-identical unless the task changes output on purpose.
  `test/tiny_ci/events/sink/console_test.exs` and `test/tiny_ci/reporter_test.exs` guard it.

## Documentation

- Every new public function gets `@doc` with a `## Examples` section where the function is
  pure. Every new module gets `@moduledoc` that says what it is *for*, not just what it does.
- Every new DSL directive or option is added to `TinyCI.DSL.Spec` **and** documented in the
  README's DSL Reference. The LSP reads the spec; the README is what people read.
- If the task changes CLI flags, update the flag table in `README.md` and the `@moduledoc`
  of the Mix task / CLI module.
- New user-facing concepts get a page under `docs/` (see `docs/events.md` for the tone).

## Definition of done (all tasks)

- [ ] Every acceptance criterion in the task file is checked off, with the test that proves it named.
- [ ] `mix format --check-formatted` passes.
- [ ] `mix compile --warnings-as-errors` passes.
- [ ] `mix test` passes with no new exclusions and no `async: false` added without a comment.
- [ ] `mix credo` (default profile) reports no issues.
- [ ] README / docs updated per the task's **Docs** section.
- [ ] `INDEX.md` status updated (⬜ → ✅) and the task file's **Status** line updated.
- [ ] The dogfood pipeline still passes: `mix tiny_ci.run` at the repo root.

## Commits

One task, one commit (or a small series if the task is explicitly staged). Message format:

```
M0-01: isolate step crashes from the run

<what changed and why, in prose>
```

Do not commit `_build/`, `deps/`, `erl_crash.dump`, or anything under `tmp/`.

## When the task file is wrong

Task files are written against the code as of their **Written against** line. If the code has
moved, prefer the *intent* of the task and record the discrepancy in a "Deviations" section
at the bottom of the task file. If the intent itself no longer makes sense, stop and report
rather than guess.
