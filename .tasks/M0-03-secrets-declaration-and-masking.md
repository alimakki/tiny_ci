# M0-03 — `secret` directive and masking in every sink and result

**Milestone:** M0 · **Size:** M · **Depends on:** M0-01 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

tiny_ci has no notion of a secret. The README's own example pipes `$SLACK_WEBHOOK_URL`
through a shell hook, and that value would appear verbatim in the console, the `--events`
NDJSON, the `--output json` document, the breakpoint payload, and the signed attestation.

This task adds:

1. A `secret` top-level directive that names a secret the pipeline needs.
2. Resolution of declared secrets at run start from (in order) an explicit provider map
   (used by M2-06), the process environment, and a gitignored `.tiny_ci/secrets` file.
   A missing secret fails the run before any step starts.
3. Injection of resolved secrets into every step's and hook's environment.
4. Masking of secret **values** in step output as it streams, in `StepResult.output`, and in
   every event before it reaches any sink — one mechanism, applied at three choke points so
   nothing downstream has to know about secrets.

`TinyCI.Sandbox.Redaction` already does the value-walking replacement for the sandbox
boundary. It is promoted to `TinyCI.Redaction` and becomes the single masking function.

## In scope

- `TinyCI.DSL.Spec` entry, `TinyCI.DSL.Validator` clause, interpreter support, and a new
  `secrets: [String.t()]` field on `TinyCI.PipelineSpec`.
- New module `TinyCI.Secrets` (resolution) and the promoted `TinyCI.Redaction` (masking).
- Executor: `secrets:` run option → `ctx.secrets` (name→value map) and
  `ctx.secret_values` (list of values); secrets become the lowest layer of `Env.base/1`.
- `TinyCI.Output.run_cmd/2`: a `redact:` option; every printed line and the returned output
  are masked.
- `TinyCI.Events.Dispatcher.start_link/2`: a `redact:` option; every event is masked before
  delivery to sinks.
- `TinyCI.Control.Session.build/2`: uses `ctx.secret_values` in addition to sandbox grants.
- `TinyCI.DryRun`: lists declared secret **names**.
- `Mix.Tasks.TinyCi.Run`: resolves secrets, reports missing ones, warns when
  `.tiny_ci/secrets` is not gitignored.
- Docs.

## Out of scope

- A server-side secrets store (M2-06). This task defines the provider hook it plugs into.
- Masking of secrets that appear *transformed* (base64, URL-encoded). Document the limitation.
- Masking values shorter than 4 bytes. Document the limitation.

## Read first

- `lib/tiny_ci/dsl/spec.ex` (how directives are declared; `env` is the closest model),
  `lib/tiny_ci/dsl/spec/entry.ex`, `lib/tiny_ci/dsl/validator.ex` (`validate_top_level/1`
  clauses for `env` and `name`), `lib/tiny_ci/dsl/interpreter.ex` (`build_spec/2`, how `env`
  directives are collected), `lib/tiny_ci/pipeline_spec.ex`.
- `lib/tiny_ci/sandbox/redaction.ex` — the function being promoted; `lib/tiny_ci/control/session.ex`
  and `lib/tiny_ci/executor/driver/sandbox.ex` call it.
- `lib/tiny_ci/executor/env.ex` — `base/1` and `resolve/2` are the two env layering functions.
- `lib/tiny_ci/output.ex` — `run_cmd/2`, `collect_port/6`, `flush_line/2`, `print_lines/2`.
- `lib/tiny_ci/events/dispatcher.ex` — `start_link/1`, `handle_call({:emit, _}, ...)`, `deliver/3`.
- `lib/tiny_ci/executor.ex` — `run_pipeline/3` (where ctx is assembled), `run_step/5` (both
  clauses build `StepResult`), `build_sink_specs/3`.
- `lib/tiny_ci/hooks.ex` — how hooks build their env and run commands.
- `lib/tiny_ci/dry_run.ex`, `lib/mix/tasks/tiny_ci.run.ex` (`run_resolved/5`, `base_run_opts/2`).
- `lib/tiny_ci/results.ex` — `to_json/2` reads `StepResult.output` directly (so masking must
  happen at result creation, not only in events).
- `test/tiny_ci/dsl/spec_test.exs`, `validator_test.exs`, `interpreter_test.exs`,
  `test/tiny_ci/sandbox/redaction_test.exs`, `test/tiny_ci/output_test.exs`,
  `test/tiny_ci/events/dispatcher_test.exs`, `test/mix/tasks/tiny_ci_run_test.exs`.

## Design

### DSL

```elixir
secret :SLACK_WEBHOOK_URL
secret "DEPLOY_TOKEN"
```

- Spec entry: `name: :secret, kind: :directive, contexts: [:top_level], type: "atom or string",
  summary: "Declares a secret the pipeline needs. Resolved at run start; its value is masked everywhere."`.
- Validator: `{:secret, _, [name]}` with `is_atom(name) or is_binary(name)` is valid. Anything
  else (`secret 1`, `secret :A, foo: 1`, `secret` inside a stage) is a diagnostic:
  `"secret expects a single atom or string name"`. Add `secret` to the stage-body allowlist
  **rejections** so `secret` inside `stage do ... end` gets a specific message.
- Interpreter: collect in declaration order, convert atoms with `Atom.to_string/1`, dedupe
  with `Enum.uniq/1`, store on `%PipelineSpec{secrets: [...]}` (default `[]`).

### Resolution — `TinyCI.Secrets` (`lib/tiny_ci/secrets.ex`)

```elixir
@type provider :: %{optional(String.t()) => String.t()}

@spec resolve([String.t()], keyword()) ::
        {:ok, %{String.t() => String.t()}} | {:error, {:missing_secrets, [String.t()]}}
# opts: root: String.t() (for the file), provider: provider() (checked first), env: map (defaults to System.get_env/0)

@spec parse_file(String.t()) :: {:ok, %{String.t() => String.t()}} | {:error, {:line, pos_integer(), String.t()}}
```

Order per name: `provider` → `env` → file at `Path.join(root, ".tiny_ci/secrets")`. First hit
wins. The file format is one `KEY=value` per line; `#` starts a comment when it is the first
non-blank character; a leading `export ` is stripped; single or double quotes around the
value are stripped (no escapes, no interpolation); blank lines are ignored; a line without
`=` is a parse error. Missing file is not an error. A value is never logged, ever.

### Injection

`Executor.run_pipeline/3` accepts `secrets: %{name => value}`. It puts `ctx.secrets` (the map)
and `ctx.secret_values` (`Map.values/1`, deduplicated, blanks and values shorter than 4 bytes
removed). `Env.base/1` becomes `secrets ⊂ pipeline_env ⊂ stage_env` (declared env wins over a
secret of the same name; document this). Hooks build their env through `Env.base/1` too, or
merge `ctx.secrets` explicitly — check `hooks.ex` and use the same function.

The sandbox driver's `granted_env/2` reads `ctx.env`, which `run_step/5` sets from
`Env.base/1`, so a policy that grants `SLACK_WEBHOOK_URL` sees the secret without further
changes. The sandbox driver's own `secrets:` option remains; union both lists before redacting.

### Masking — `TinyCI.Redaction` (`lib/tiny_ci/redaction.ex`)

Move `TinyCI.Sandbox.Redaction` here unchanged in behaviour, plus one rule: values shorter
than 4 bytes are ignored (a 1–3 byte "secret" would mask ordinary text). Leave a one-line
`TinyCI.Sandbox.Redaction` module that `defdelegate`s `redact/2` with `@moduledoc false` and a
`@deprecated` attribute, so the rename is not a breaking change inside the same milestone.

Three choke points:

1. **Output.** `run_cmd/2` gains `redact: [values]`. Mask each complete line in
   `flush_line/2`/`print_lines/2` before printing, and mask the accumulated output before
   returning. Masking is per line, so a secret containing a newline is not masked (document).
2. **Results.** In both `run_step/5` clauses and in the M0-01 crash path, `output` is passed
   through `Redaction.redact(output, ctx.secret_values)` before the `StepResult` is built.
   This is what makes `Results.to_json/2` and the `Reporter` safe without touching them.
3. **Events.** `Dispatcher.start_link(sink_specs, redact: values)`; in `handle_call({:emit, e})`
   the event is `Redaction.redact(event, values)` once, before the sink loop. Structs survive
   the walk (`Redaction` already preserves shape; confirm with a test on a `%StepOutputLine{}`).
   `Executor.run_pipeline/3` passes `ctx.secret_values`; `with_ephemeral_dispatcher/4` passes
   whatever is on the context.

`Session.build/2` (breakpoint payloads) already redacts `env`, `store`, and `result` with the
sandbox secrets; change it to use `ctx.secret_values ++ sandbox_secrets`.

### CLI behaviour

In `Mix.Tasks.TinyCi.Run.run_resolved/5`, before `verify_actions/2`:

- `TinyCI.Secrets.resolve(spec.secrets, root: root)`.
- On `{:error, {:missing_secrets, names}}`: print to stderr
  `Missing secrets: A, B` and
  `Set them in the environment or in .tiny_ci/secrets (KEY=value, gitignored).` and return
  `{:error, :missing_secrets}` → exit 1. With `--dry-run`, print the same as a warning and
  continue.
- If `.tiny_ci/secrets` exists and `git check-ignore -q .tiny_ci/secrets` (run in `root`)
  exits non-zero, print a warning: `Warning: .tiny_ci/secrets is not gitignored.`
- Pass `secrets:` in `base_run_opts/2`.

`DryRun` prints a `Secrets: NAME, NAME` line after the branch/commit header when any are
declared. Names only.

## TDD plan

1. **`test/tiny_ci/dsl/spec_test.exs`** — `secret` is a top-level directive with the summary
   above. → add the entry.
2. **`test/tiny_ci/dsl/validator_test.exs`** — accepts `secret :A` and `secret "A"`; rejects
   `secret 1`, `secret :A, x: 1`, and `secret :A` inside a stage with the specific messages.
   → validator clauses.
3. **`test/tiny_ci/dsl/interpreter_test.exs`** — `spec.secrets == ["A", "B"]` for
   `secret :A\nsecret "B"\nsecret :A`. → interpreter + `PipelineSpec` field.
4. **`test/tiny_ci/redaction_test.exs`** — move the existing sandbox redaction tests here,
   rename the module under test, add "ignores values shorter than 4 bytes", and a test that a
   `%TinyCI.Events.StepOutputLine{line: "token=abcd1234"}` comes back as the same struct with
   `line: "token=***"`. Keep `test/tiny_ci/sandbox/redaction_test.exs` as a two-line test that
   the deprecated delegate still works. → promote the module.
5. **`test/tiny_ci/secrets_test.exs`** — `describe "parse_file/1"`: comments, blank lines,
   `export`, quotes, parse error with line number. `describe "resolve/2"`: provider wins over
   env; env wins over file (pass `env:` as a map so the test does not touch the real
   environment and stays `async: true`); missing names reported in declaration order; missing
   file is fine. → `TinyCI.Secrets`.
6. **`test/tiny_ci/executor/env_test.exs`** — `base/1` with `secrets: %{"T" => "s3cr3t"}` and
   `pipeline_env: %{"T" => "declared"}` yields `"declared"`; without the collision, the secret
   is present. → `Env.base/1`.
7. **`test/tiny_ci/output_test.exs`** — `run_cmd("echo token=abcd1234", mode: :streaming, redact: ["abcd1234"])`
   prints `token=***` (capture_io) and returns `{:passed, "token=***\n"}`; buffered mode masks
   the returned output. → `Output` option.
8. **`test/tiny_ci/events/dispatcher_test.exs`** — with `redact: ["abcd1234"]`, a `ForwardSink`
   receives a `StepOutputLine` whose `line` is masked; without the option it is untouched.
   → dispatcher option.
9. **`test/tiny_ci/executor_test.exs`** — `describe "secrets"`: a step
   `cmd: "echo $TOKEN"` run with `secrets: %{"TOKEN" => "abcd1234"}` yields
   `StepResult.output == "***\n"`; the `StepOutputLine` and `StepCompleted` events (via
   `TinyCI.TestSink`) are masked; `Results.to_json/2` on the results does not contain
   `abcd1234`. Also a module step returning `{:ok, %{leaked: "abcd1234"}}`: the
   `BreakpointHit` payload (run with `control: [breakpoints: ["after:s.m"], timeout: 10, timeout_action: :continue]`)
   has `store.leaked == "***"`. → executor wiring, session change.
10. **`test/tiny_ci/dry_run_test.exs`** — output contains `Secrets: A, B` and never a value.
11. **`test/mix/tasks/tiny_ci_run_test.exs`** — pipeline with `secret :TC_MISSING_X` and no such
    env var → `{:error, :missing_secrets}` and stderr lists it; with `--dry-run` the run
    proceeds and stderr carries a warning; a `.tiny_ci/secrets` file in the tmp project root
    supplies the value and the step output is masked; the "not gitignored" warning appears
    when the tmp root is a git repo without the ignore rule. (Use `System.put_env` only with a
    name unique to the test and `async: false` on that module if it is not already.)
12. Full suite, `mix tiny_ci.run`, then add `secret :EXAMPLE_TOKEN`? **No** — do not add a
    secret to the dogfood pipeline; it would make `mix tiny_ci.run` fail on every machine.

## Acceptance criteria

- [ ] `secret :NAME` / `secret "NAME"` are valid only at top level; misuse gives a clear message.
- [ ] A declared secret missing from provider, env, and file fails the run before any step
      starts, with every missing name listed; `--dry-run` warns instead.
- [ ] Secret values reach shell steps and hooks as environment variables.
- [ ] A secret value present in step output is `***` in: streaming console, buffered console,
      `StepResult.output`, `--output json`, NDJSON, the breakpoint payload, and the
      attestation (existing provenance tests extended with one masked case).
- [ ] Values shorter than 4 bytes are not masked, and this is documented.
- [ ] `.tiny_ci/secrets` is parsed per the documented grammar; a not-gitignored file warns.
- [ ] LSP completion offers `secret` at top level (it reads `Spec`; verify with
      `test/tiny_ci/dsl/spec_test.exs` rather than by running the LSP).

## Pitfalls

- `Redaction.redact/2` walks tuples and structs; event structs contain `DateTime` values,
  which are structs with integer fields — the walk must not choke on them (the existing
  implementation handles maps generically; keep a test).
- Do not mask inside `Dispatcher.deliver/3` per sink; mask once per emit.
- Masking in `Output` must happen on complete lines, after `line_buf` reassembly, or a secret
  split across two port chunks leaks.
- `System.get_env/0` returns all variables; do not log it, do not put it on the context.
- `capture_io` in tests interacts with `Process.group_leader/2` in streaming mode; existing
  `output_test.exs` shows the working pattern.

## Docs

- README: new "Secrets" section under the DSL Reference (directive, sources, file grammar,
  masking guarantees and limitations); flag table unchanged.
- `docs/events.md`: one paragraph "Masking" stating events are redacted before any sink.
- `docs/execution-control.md`: note that breakpoint payloads are redacted.
- `docs/provenance.md`: note that attestations inherit masking.

## Follow-ups

_(none yet)_
