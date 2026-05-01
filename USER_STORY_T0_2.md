# User Story: T0.2 — Structured Output (`--output json`)

## Story

As a developer using TinyCI in scripts, git hooks, or CI integrations,  
I want machine-readable JSON output from pipeline runs,  
so that I can consume results programmatically without parsing human-formatted text.

## Acceptance Criteria

- `mix tiny_ci.run --output json` prints a single JSON object to stdout on completion
- JSON structure: `{status, duration_ms, stages: [{name, status, duration_ms, steps: [...]}]}`
- Matrix stages include a `matrix_runs` array in their JSON representation
- `--output json` suppresses all ANSI/human-readable output (no mixing)
- `mix tiny_ci.run --output json | jq '.status'` returns `"passed"` or `"failed"`
- Exit code is still `0`/`1` regardless of `--output json`
- Unknown `--output` values print a clear error
- Jason added as explicit production dependency in `mix.exs`

---

## Tasks

### Tests (written first)

- [x] Write `TinyCI.Results` unit tests: all-passed pipeline serializes correctly
- [x] Write `TinyCI.Results` unit tests: failed pipeline has `"failed"` status
- [x] Write `TinyCI.Results` unit tests: skipped stages appear with `"skipped"` status
- [x] Write `TinyCI.Results` unit tests: matrix stages include `matrix_runs` array
- [x] Write `TinyCI.Results` unit tests: allowed-failure steps serialized correctly
- [x] Write `TinyCI.Results` unit tests: multi-attempt steps have correct `attempts` field
- [x] Write Mix task tests: `--output json` produces valid JSON with correct `status`
- [x] Write Mix task tests: `--output json` suppresses human-readable output
- [x] Write Mix task tests: failed pipeline still exits 1 with `--output json`
- [x] Write Mix task tests: unknown `--output` value prints error and exits 1

### Implementation

- [x] Add `{:jason, "~> 1.4"}` to production deps in `mix.exs`
- [x] Run `mix deps.get`
- [x] Create `lib/tiny_ci/results.ex` with `TinyCI.Results.to_json/2`
- [x] Serialize `StageResult` → stage map with nested step maps
- [x] Serialize `MatrixRunResult` → `matrix_runs` array
- [x] Add `output: :string` switch to `OptionParser` in Mix task
- [x] Validate `--output` value (only `"json"` accepted, error otherwise)
- [x] Branch in `execute_pipeline/2`: json mode → suppress reporter, print JSON
- [x] Branch in `execute_pipeline/2`: ensure exit code still reflects pipeline status

### Quality

- [x] `mix format` — no formatting issues
- [x] `mix test` — all tests pass
- [x] `mix credo` — no issues
- [x] Document `--output` flag in README
