# M5-03 — Per-test failure records, targeted re-run, quarantine

**Milestone:** M5 · **Size:** L · **Depends on:** M0-06, M3-02 · **Status:** ⬜ Not started
**Design reference:** `docs/archive/design-2026-05.md` §2 (Adaptive Flaky Test Isolation)

> Detail level: design. Expand when M5 opens; the archived design has the detailed proposal.

## Summary

Retrying a whole job because one test is flaky wastes the whole job's time and hides the
flake. This task teaches tiny_ci to read a step's **test report**, record per-test results in
the run history, re-run only the failed tests, and quarantine tests that flip between passing
and failing across runs — surfacing them in the UI instead of blocking merges.

## Design notes

- Step option `test_report: [format: :junit, path: "reports/*.xml"]` (JUnit XML is the
  lingua franca; ExUnit has `--formatter JUnitFormatter` via a dep, Jest/pytest/Go tools emit
  it). Parsed after the step; per-test results become `test_result` events (new type; bump
  schema) and are folded by the projection into `tests: [%{id, status, duration_ms}]`.
- `retry_failed_tests: [cmd: "mix test --failed", max: 2]` — a command template run after a
  failure, only when the report identified failures; `{failed_tests}` placeholder expands to
  a space-separated list for tools that take paths.
- Quarantine: `TinyCI.Runs.TestHistory` folds recent runs per repo to compute a flake score
  (fails then passes on the same sha, or alternating across shas); tests above a threshold are
  marked quarantined in the UI and, with `quarantine: :ignore` on the step, no longer fail
  the step (still recorded).
- Everything derives from recorded events; no new store.

## Acceptance criteria

- [ ] A JUnit report is parsed and per-test results appear in the run's projection and UI.
- [ ] A failing step with a report re-runs only the failed tests when configured.
- [ ] A test that alternates across runs is shown as flaky; with `quarantine: :ignore` it does
      not fail the step.
