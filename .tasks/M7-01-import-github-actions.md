# M7-01 — `tiny_ci import` converts simple GitHub Actions workflows

**Milestone:** M7 · **Size:** M · **Depends on:** M1-01 · **Status:** ⬜ Not started

> Detail level: design. Expand when M7 opens.

## Summary

Migration cost keeps teams on their current CI. A one-time importer that turns a typical
`.github/workflows/ci.yml` into a `tiny_ci.exs` — jobs to stages, `needs` to `needs:`, `run`
steps to `cmd:`, `env` at each level, `strategy.matrix` to `matrix:`, `timeout-minutes` to
`timeout:`, `continue-on-error` to `allow_failure:`, `if: github.ref == 'refs/heads/main'` to
`when: branch() == "main"` — and leaves a clearly marked `# TODO` for every `uses:` action it
cannot express. It is an importer, not a runtime compatibility layer.

## Design notes

- YAML parsing needs a dependency; put the importer in the **CLI layer of `tiny_ci_dist`** or a
  small `tiny_ci_import` app so core stays `jason`-only. `yaml_elixir` is the usual choice.
- Output is run through `TinyCI.DSL.Interpreter.interpret_string/2` before being written; the
  importer refuses to emit a file that does not validate.
- Print a summary: converted N jobs, M steps, K TODOs, with the line numbers of the TODOs.
- Fixture corpus: five real-world workflows of increasing complexity under `test/fixtures/gha/`.

## Acceptance criteria

- [ ] The five fixtures import to valid pipelines; `--dry-run` on each succeeds.
- [ ] Every unsupported construct becomes a `# TODO` comment naming the original key.
- [ ] Documented in `docs/import.md` with before/after examples.
