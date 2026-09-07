# M1-02 — Run in a directory with no Mix project

**Milestone:** M1 · **Size:** S–M · **Depends on:** M1-01 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

A Go, Rust, Python, or JavaScript team is the audience for a language-agnostic local runner,
and none of them have `mix.exs`. This task makes the shell-step subset of tiny_ci work in any
directory, guards every remaining `Mix.*` reference at runtime, gives module steps a clear
"not available here" message, and adds an integration test that runs the built escript in a
non-Elixir project.

## In scope

- An architecture test asserting `lib/tiny_ci/**` has no unguarded `Mix.` reference.
- `TinyCI.Sandbox.Trust.root_app/0` already guards `Mix.Project`; audit `TinyCI.Action.Resolver`,
  `TinyCI.Action.Lockfile`, `TinyCI.Registry`, `TinyCI.Action.Audit` for assumptions that a
  `mix.lock` or a compiled project exists and make each degrade to "no lockfile / no
  first-party app" gracefully.
- A clearer error when a `module:` step's module is not loadable, mentioning that module steps
  need the module on the code path (i.e. `mix tiny_ci.run` inside the Elixir project).
- Discovery and `--root` relative to the current directory (already so; add the test).
- `test/integration/escript_test.exs` tagged `:escript`, excluded unless `TINY_CI_ESCRIPT=1`.
- A `.tiny_ci/build.exs` stage that runs the escript smoke test in a fixture non-Elixir dir.

## Out of scope

- Loading user Elixir code from a non-Mix directory (a plugin mechanism). Module steps stay
  an Elixir-project feature; say so in the docs.
- The Burrito binary (M1-03) — this task proves the code path with the escript.

## Read first

- `grep -rn "Mix\." lib/tiny_ci` — the current list (one hit in `trust.ex`, guarded).
- `lib/tiny_ci/action/resolver.ex`, `lib/tiny_ci/action/lockfile.ex`, `lib/tiny_ci/registry.ex`,
  `lib/tiny_ci/action/audit.ex` — look for `mix.lock`, `Mix.Project`, `Mix.Dep`,
  `:application.get_key`, `Application.loaded_applications/0` and think about what each does
  when the process is an escript in `/tmp/some-go-project`.
- `lib/tiny_ci/action.ex` — `validate_spec/1` and the "could not be loaded" message.
- `lib/tiny_ci/discovery.ex` — `find_pipeline/1`, `find_pipeline_by_name/2`.
- `lib/tiny_ci/sandbox/backend/seatbelt.ex` / `bubblewrap.ex` — `available?/0` requires an
  `elixir` executable; in a toolchain-free environment the sandbox is unavailable and the
  driver fails closed. That is correct; document it.
- `test/test_helper.exs` — how tags are excluded by host capability.

## Design

### Architecture test

`test/tiny_ci/architecture_test.exs`: read every file under `lib/tiny_ci/`, find lines matching
`~r/\bMix\./`, and assert each is either preceded (same line or the line above) by a
`function_exported?(Mix.Project, ...)`/`Code.ensure_loaded?(Mix)` guard or is inside a
`@moduledoc`/comment. Simplest robust form: maintain an explicit allowlist of
`{file, line_pattern}` pairs in the test and assert the set of matches equals the allowlist.
The point is that a new unguarded `Mix.` call fails CI.

### Graceful degradation

For each module in the audit list decide and implement:

- No `mix.lock` in `root` → lockfile resolution returns `{:ok, %{}}`/`:no_lockfile` and audit
  reports "no lockfile (not an Elixir project)" rather than an error, **unless** the pipeline
  references third-party actions, in which case the existing error stands.
- No root application → `Trust.classify/2` treats modules with no owning app as `:local`
  (already) and modules owned by any loaded app other than builtins as `:third_party`.

### Module step message

When `Action.validate_spec/1` finds a module that cannot be loaded, the message becomes:

```
Step :deploy refers to module MyApp.Deploy, which could not be loaded.
Module steps run inside your Elixir project: use `mix tiny_ci.run` there, or replace the step with `cmd:`.
```

### Escript integration test

```elixir
@moduletag :escript
setup_all: build once with `System.cmd("mix", ["escript.build"], env: [{"MIX_ENV", "prod"}])`
test "runs a shell-only pipeline in a directory with no mix.exs":
  tmp = fixture dir with go.mod, main.go (any content), and tiny_ci.exs:
      name :go_ci
      stage :build do
        step :vet, cmd: "echo vet ok"
        step :test, cmd: "echo test ok"
      end
  {out, 0} = System.cmd(escript_path, ["run", "--no-color"], cd: tmp)
  assert out =~ "vet ok"; refute File.exists?(Path.join(tmp, "mix.exs"))
test "--dry-run output matches mix tiny_ci.run --dry-run" (both with --no-color)
test "a module: step gives the module-steps message and exit 1"
```

`test_helper.exs`: exclude `:escript` unless `System.get_env("TINY_CI_ESCRIPT") == "1"`.

### Dogfood

`.tiny_ci/build.exs` gains a stage after the escript build:

```elixir
stage :smoke, needs: [:escript_core] do
  step :non_elixir_dir, cmd: "TINY_CI_ESCRIPT=1 mix test --only escript"
end
```

(Adjust the stage names to whatever M1-01 added.)

## TDD plan

1. **`test/tiny_ci/architecture_test.exs`** — write the allowlist test; it passes today with
   the single guarded `trust.ex` line. → commit it first so the rest of the task is protected.
2. **`test/tiny_ci/action_validation_test.exs`** — the new message for an unloadable module.
   → change the message.
3. For each audited module, write a test with a `tmp_dir` root containing no `mix.lock` and
   assert the graceful result described above. → implement.
4. **`test/tiny_ci/discovery_test.exs`** — `find_pipeline/1` and `list_pipelines/1` on a
   `tmp_dir` with `tiny_ci.exs` and no `mix.exs` (likely already covered; add if not).
5. **`test/integration/escript_test.exs`** — as designed; run it with `TINY_CI_ESCRIPT=1 mix
   test --only escript`. → fix whatever breaks (expect: nothing after steps 2–3; if the
   escript prints application-start noise, find the app and silence it in prod).
6. Add the dogfood stage; run `mix tiny_ci.run build`.

## Acceptance criteria

- [ ] The escript runs a shell-only pipeline to completion in a directory without `mix.exs`.
- [ ] `tiny_ci run --dry-run` output there matches the Mix task's for the same file.
- [ ] A `module:` step outside a project fails at load time with the documented message.
- [ ] `lib/tiny_ci/**` has no unguarded `Mix.` reference, enforced by a test.
- [ ] Lockfile/audit/registry code paths degrade gracefully with no `mix.lock`.
- [ ] The `:escript` integration test exists, is excluded by default, and is run by the dogfood
      build pipeline.

## Pitfalls

- `Application.spec(:tiny_ci, :vsn)` works in escripts; `Mix.Project.config()[:version]` does not.
- `System.cmd("mix", ...)` in `setup_all` inherits `MIX_ENV=test` from the test run; override
  it to `prod` explicitly or the escript will include tidewave/bandit.
- `File.cwd!/0` inside the escript is the directory the user ran it from — that is the desired
  root. Do not derive root from the escript's own location.

## Docs

- README "Installation" → a "Non-Elixir projects" paragraph: what works (everything with
  `cmd:`), what does not (module steps, sandboxed actions), and why.
- `docs/actions.md`: same note in the module-steps section.

## Follow-ups

_(none yet)_
