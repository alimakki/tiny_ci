# TinyCI Custom DSL: Security Design & Implementation Plan

## Background

TinyCI pipeline files are currently full Elixir `.exs` files compiled via
`Code.compile_file/1`. This works well for local developer use, but it creates
a meaningful attack surface when TinyCI runs on **shared CI infrastructure**
(runners with deploy keys, cloud credentials, or elevated OS permissions).

This document captures the design for a restricted DSL parser/interpreter that
replaces `Code.compile_file/1` as the execution mechanism for pipeline files,
enabling TinyCI to be used safely in both contexts.

---

## Problem Statement

### Two deployment scenarios

| Scenario | Pipeline author | Threat level |
|---|---|---|
| Local dev tool | The developer themselves | Low — equivalent to a Makefile |
| Shared CI runner | Anyone who can commit to the repo | High — compromise pipeline → compromise runner |

### Current attack surfaces

1. **`Code.compile_file/1` — unrestricted Elixir execution.** A pipeline `.exs`
   file can call `System.halt/1`, `File.rm_rf!/1`, `Node.connect/1`,
   `:httpc` for exfiltration, or `Code.eval_string/1` to bypass any future
   analysis layer. The entire BEAM VM is available.

2. **`--dry-run` is not truly safe.** `Code.compile_file/1` executes top-level
   module code as a side effect of loading. A pipeline file can run arbitrary
   code before `__pipeline__/0` is even called.

3. **Path traversal in `find_pipeline_by_name`.** The `name` CLI argument is
   interpolated into a path without canonicalization, allowing `../../` escapes.

4. **`--file PATH` accepts any filesystem path.** No restriction to project root.

### What a custom DSL solves

| Vector | Custom DSL fixes it? | Notes |
|---|---|---|
| Arbitrary Elixir in pipeline file | **Yes** | Core goal |
| Truly safe `--dry-run` | **Yes** | No compilation side effects |
| Shell command execution (`cmd:`) | **No** | Intentional — that's what CI does |
| `module:` step type | **Partially** | Becomes an explicit opt-in |

The shell command vector is irreducible without OS-level sandboxing (containers,
`sandbox-exec`, Linux namespaces). This design eliminates the Elixir injection
vector; OS sandboxing is a separate, complementary concern.

---

## Chosen Approach: `string_to_quoted` + Restricted AST Interpreter

Rather than writing a full parser from scratch or switching to YAML, the most
pragmatic approach reuses Elixir's tokenizer and parser via
`Code.string_to_quoted/1`, then walks the resulting AST through a strict
allowlist, and finally **interprets** the restricted AST directly — never
calling `Code.compile_file/1` or `Code.eval_quoted/1`.

```
pipeline.exs  →  string_to_quoted  →  AST validation  →  AST interpreter  →  %PipelineSpec{}
                 (Elixir parser,        (allowlist,          (TinyCI-owned,
                  no execution)          reject unknown        no BEAM access)
                                         constructs)
```

### Why not YAML/TOML?

YAML/TOML is pure data — no conditions, no logic, no familiar Elixir syntax.
Users lose `when_branch`, `when_env`, `when_file_changed`, and any future
computed conditions. The Elixir-like syntax is a deliberate UX feature worth
preserving.

### Why not a full custom parser (NimbleParsec)?

Writing a full parser is significant work and produces a surface area that must
be maintained indefinitely. `string_to_quoted/1` gives us a battle-tested
tokenizer and parser for free. We only need to write the AST walker and
interpreter for ~10 DSL constructs.

### Why not compile then restrict?

`Code.compile_file/1` executes code as a side effect of compilation (top-level
module expressions, `@before_compile` hooks, etc.). Restricting after
compilation provides no guarantee of safe loading. The restriction must happen
**before** any execution.

---

## Design

### File format

Pipeline files drop the `defmodule` wrapper and `use TinyCI.DSL` declaration
entirely. The runtime provides that context implicitly. The file becomes a flat
script — a sequence of top-level DSL calls.

An optional `name` directive at the top identifies the pipeline. If omitted,
the name is derived from the filename (e.g. `deploy.exs` → `:deploy`).

```elixir
# tiny_ci.exs — before (current format)
defmodule MyPipeline do
  use TinyCI.DSL

  stage :test, mode: :parallel do
    step :unit, cmd: "mix test"
    step :lint, cmd: "mix credo"
  end

  stage :deploy, when: when_branch("main") do
    step :release, cmd: "make release"
  end

  on_failure :alert, cmd: "curl -X POST $SLACK_WEBHOOK"
end
```

```elixir
# tiny_ci.exs — after (new format)
name :my_pipeline

stage :test, mode: :parallel do
  step :unit, cmd: "mix test"
  step :lint, cmd: "mix credo"
end

stage :deploy, when: branch() == "main" do
  step :release, cmd: "make release"
end

on_failure :alert, cmd: "curl -X POST $SLACK_WEBHOOK"
```

The `defmodule` and `use TinyCI.DSL` constructs are **not in the allowlist**.
A file using the old format will fail at the validation stage with a clear
migration error rather than silently passing through.

### Implicit runtime wrapping

The runtime conceptually treats the pipeline file as if it were:

```elixir
defmodule __implicit__ do
  use TinyCI.DSL
  # ... file contents injected here ...
end
```

But this module is never generated. The interpreter walks the flat AST
directly and produces a `%TinyCI.PipelineSpec{}` struct. No BEAM module is
created, no bytecode is compiled, no code is executed during loading.

### Pipeline naming

The `name` directive is **optional**. Resolution order:

1. `name :my_pipeline` in the file — used as-is
2. No directive — derived from the filename stem (`deploy.exs` → `:deploy`,
   `jobs/release.exs` → `:release`)

`name` accepts an atom only (snake_case). Future versions may support metadata:

```elixir
# possible future extension
name :my_pipeline, description: "Main build pipeline", version: "2"
```

### `%TinyCI.PipelineSpec{}` — the new return type

The interpreter produces a `%TinyCI.PipelineSpec{}` struct instead of a
compiled module. This replaces the `module.__pipeline__()` / `module.__hooks__()`
interface throughout the codebase.

```elixir
defmodule TinyCI.PipelineSpec do
  @enforce_keys [:name, :stages, :hooks]
  defstruct [:name, :stages, :hooks]

  # name:   atom — pipeline identifier
  # stages: [%TinyCI.Stage{}]
  # hooks:  %{on_success: [...], on_failure: [...]}
end
```

### Allowlisted AST constructs

The file-level AST is a `{:__block__, _, [expr...]}` (or a single expression
for single-statement files). The validator walks every top-level expression and
every nested expression within permitted blocks.

**Top-level (file scope):**

| Construct | AST node pattern | Notes |
|---|---|---|
| `name/1` | `{:name, _, [atom]}` | Optional; must be first if present |
| `stage/2,3` | `{:stage, _, [atom, opts]}` or `{:stage, _, [atom, opts, [do: block]]}` | |
| `on_success/2,3` | `{:on_success, _, [atom, opts, block?]}` | |
| `on_failure/2,3` | `{:on_failure, _, [atom, opts, block?]}` | |

**Inside a `stage` block:**

| Construct | AST node pattern | Notes |
|---|---|---|
| `step/2,3` | `{:step, _, [atom, opts, block?]}` | |

**Inside a `step` block:**

| Construct | AST node pattern | Notes |
|---|---|---|
| `set/2` | `{:set, _, [atom, value]}` | |

**As option values for non-`:when` options (`:cmd`, `:env`, `:timeout`, etc.):**

| Construct | Notes |
|---|---|
| String literals | `"..."` |
| Atom literals | `:foo` |
| Integer literals | `5000` |
| Boolean literals | `true` / `false` |
| Map literals | `%{"KEY" => "val"}` — string keys and values only |
| Keyword lists | `[key: value]` — atom keys, literal values only |

**As the value of the `:when` option — condition expression grammar:**

The `:when` value is evaluated by a dedicated condition evaluator against the
runtime context. It accepts a strict sub-grammar:

| Construct | Example | Notes |
|---|---|---|
| `branch/0` | `branch() == "main"` | Returns current git branch string |
| `env/1` | `env("CI") != nil` | Returns env var value or `nil` |
| `file_changed?/1` | `file_changed?("lib/**/*.ex")` | Returns boolean; glob pattern |
| `==`, `!=` | `branch() != "main"` | Comparison; operands must be condition exprs or literals |
| `and`, `or`, `not` | `branch() == "main" and env("CI") != nil` | Boolean combinators |
| `if` | `if branch() == "main", do: true, else: false` | Rarely needed; `and`/`or` is preferred |
| String / atom / boolean / nil literals | `"main"`, `nil`, `true` | As operands only |

`branch()`, `env/1`, and `file_changed?/1` are the only callable functions
permitted in a condition expression. All other function calls — including
`System.get_env/1`, `File.exists?/1`, or any module-qualified call — are
rejected at validation time.

**Explicitly rejected** (non-exhaustive): `defmodule`, `use`, `import`,
`require`, `alias`, `def`, `defp`, `System`, `File`, `Node`, `Code`, `:os`,
`Process`, `spawn`, `apply`, `send`, `receive`, `case`, `cond`, `with`,
`for`, variable bindings, anonymous functions, any non-whitelisted function call.

### Condition expressions

The current macro-based DSL turns `when_branch("main")` into an Elixir function
that runs arbitrary code at load time. The new design replaces both the `when_*`
macros and the "opaque data tuple" interim approach with **condition expressions**
— a restricted expression grammar evaluated at runtime by a dedicated evaluator.

**Why not `when_*` macros:**
- `:when` and `when_branch` — "when" is redundant in both the key and the function name
- Not composable — `when_branch("main") and when_env("CI")` requires a separate
  combinator macro; standard `and` cannot be used
- Opaque data tuples (`{:when_branch, "main"}`) mean adding a new condition type
  requires changes to both the DSL and the executor pattern-match arms
- Custom vocabulary users must learn just for conditions

**The replacement — utility functions + standard operators:**

```elixir
# Before — custom macros, not composable
stage :deploy, when: when_branch("main") do ...

# After — natural boolean expressions, composable
stage :deploy, when: branch() == "main" do ...
stage :deploy, when: branch() == "main" and env("CI") != nil do ...
stage :deploy, when: file_changed?("lib/**") or file_changed?("config/**") do ...
```

`branch/0`, `env/1`, and `file_changed?/1` are whitelisted utility functions
that read from the pipeline context. Standard comparison and boolean operators
are permitted as combinators. `if` is also allowed for readability, though
`and`/`or` is almost always cleaner for boolean conditions.

The condition expression grammar (what the validator permits):

```
condition :=
  | branch()                         -- current git branch string
  | env(string_literal)              -- env var value or nil
  | file_changed?(string_literal)    -- boolean glob match
  | literal                          -- string, atom, boolean, nil
  | condition == condition
  | condition != condition
  | condition and condition
  | condition or condition
  | not condition
  | if condition, do: condition, else: condition
```

Anything outside this grammar — including `System.get_env/1`, `File.exists?/1`,
or any non-whitelisted call — is a validation error.

The `:when` value is stored in `%TinyCI.Stage{}` as the raw quoted AST node.
The executor passes it to `TinyCI.DSL.ConditionEval.eval/2` at runtime:

```elixir
# Before — calling a compiled function closure
def __stage_when_deploy__(var!(tiny_ci_ctx)),
  do: var!(tiny_ci_ctx).branch == "main"

# After — interpreting a stored AST node against the context
# Stored in stage struct as quoted AST: {:==, _, [{:branch, _, []}, "main"]}
TinyCI.DSL.ConditionEval.eval(stage.when_condition, ctx)
```

For `--dry-run` display, condition expressions are rendered back to source via
`Macro.to_string/1` on the stored AST node — no special pretty-printing needed.

### The `module:` step type

Module-based steps (`step :deploy, module: MyDeployer`) require pre-compiled
Elixir modules. Two consequences of the new format apply here:

**Inline module definitions are no longer possible.** Because `defmodule` is not
in the allowlist, users cannot define step modules inside the pipeline file.
Module-based steps must live in the main application code (or a separate
compiled library). This is a positive constraint — it enforces a clean
separation between pipeline configuration and business logic.

**Modules require explicit allowlisting in safe mode.** Two options:

- **Option A — Drop for safe mode, keep for local mode.** In `--safe` mode,
  `module:` steps are rejected at parse time with a clear error.

- **Option B — Explicit opt-in allowlist.** A config file
  (`.tiny_ci/modules.exs`) or CLI flag (`--allow-modules Mod1,Mod2`) declares
  which modules are permitted. The interpreter checks against this allowlist
  before calling `apply/3`.

Option B is recommended: it preserves the feature while making the permission
explicit and auditable.

### Discovery changes

`TinyCI.Discovery` currently identifies a valid pipeline file by checking
`function_exported?(mod, :__pipeline__, 0)` on the compiled module. With the
new format, no module is produced. Discovery is simplified:

```elixir
# Before — compile file, then check for __pipeline__/0
defp compile_and_find(path) do
  modules = Code.compile_file(path)
  Enum.find(modules, &pipeline_module?/1)
end

# After — interpret file, which either succeeds or returns an error
defp interpret_and_load(path) do
  TinyCI.DSL.Interpreter.interpret_file(path)
  # returns {:ok, %PipelineSpec{}} | {:error, reason}
end
```

The mix task is updated accordingly:

```elixir
# Before
stages = module.__pipeline__()
hooks  = module.__hooks__()

# After
%TinyCI.PipelineSpec{stages: stages, hooks: hooks} = spec
```

### Migration from old format

Old-format files (`defmodule` + `use TinyCI.DSL`) are **not supported by the
interpreter**. When the validator encounters a top-level `defmodule` node it
produces a descriptive error:

```
Error: pipeline file uses the legacy module format.
Remove the `defmodule MyPipeline do` wrapper and the `use TinyCI.DSL` line.
See docs/migrating-pipeline-format.md for details.
```

During the transition period, the mix task may detect the old format and fall
back to `Code.compile_file/1` in non-safe local mode only, emitting a
deprecation warning. In `--safe` mode, old-format files always hard-fail.

---

## Implementation Steps

### Phase 1 — Fix existing vulnerabilities (do first, independent of DSL rewrite)

- [ ] **Fix path traversal in `find_pipeline_by_name`.**
  Use `Path.expand/1` on the resolved path and assert it starts with the
  expanded `.tiny_ci/` base directory. Reject anything that escapes.

- [ ] **Restrict `--file` to project root by default.**
  Add a `--allow-external-file` flag to explicitly permit paths outside the
  project root. Default behavior: reject if path does not start with project root.

- [ ] **Add compiler warning for dangerous module usage in current pipeline files.**
  Walk the AST via `string_to_quoted/1` before `compile_file/1` and emit
  `IO.warn/1` if `System`, `File`, `Node`, etc. are referenced. Lightweight
  lint pass compatible with the current architecture.

### Phase 2 — AST validator (non-breaking, additive)

Introduce `TinyCI.DSL.Validator` — a module that takes a quoted AST and returns
`:ok` or `{:error, [violation]}`. Wire it into `Discovery.load_pipeline/1`
before compilation as a warning layer initially, then as a hard rejection.

```
TinyCI.DSL.Validator
├── validate/1              — entry point; returns :ok | {:error, violations}
├── walk_top_level/1        — iterates file-scope expressions
├── validate_top_level/1    — name, stage, on_success, on_failure only
├── validate_stage_body/1   — step calls only
├── validate_step_body/1    — set calls only
├── validate_opts/1         — keyword list; :when value goes to validate_condition/1,
│                             all other values must be literals
├── validate_condition/1    — recursive condition expression grammar:
│                             branch/0, env/1, file_changed?/1,
│                             ==, !=, and, or, not, if, literals
└── validate_literal/1      — string, atom, integer, bool, nil, map, kwlist
```

`validate_condition/1` recursively walks the `:when` value AST. It permits only
the condition grammar defined above and rejects any node that falls outside it,
including calls to `System`, `File`, or any non-whitelisted function.

This phase keeps `Code.compile_file/1` but gates it behind AST validation.
Existing pipelines that pass validation are unaffected. Old-format files
(containing `defmodule`) emit a deprecation warning at this stage.

### Phase 3 — AST interpreter + `%PipelineSpec{}`

Define `TinyCI.PipelineSpec` and replace `Code.compile_file/1` with a pure
interpreter. The interpreter walks the validated flat AST and produces a
`%PipelineSpec{}` directly, without compilation.

```
TinyCI.PipelineSpec
└── defstruct [:name, :stages, :hooks]

TinyCI.DSL.Interpreter
├── interpret_file/1        — reads file, calls string_to_quoted, validate, interpret
├── interpret/1             — takes validated AST, returns {:ok, %PipelineSpec{}}
├── interpret_name/1        — extracts name atom, or nil
├── interpret_stage/1       — produces %TinyCI.Stage{}
├── interpret_step/1        — produces %TinyCI.Step{} (or keyword list)
└── interpret_hook/1        — produces %TinyCI.Hook{}

TinyCI.DSL.ConditionEval
├── eval/2                  — evaluates a condition AST node against a context map
├── eval_call/3             — handles branch/0, env/1, file_changed?/1
├── eval_op/3               — handles ==, !=, and, or, not
└── eval_if/3               — handles if/then/else nodes
```

Update `TinyCI.Discovery`:
- Replace `compile_and_find/1` with `interpret_and_load/1`
- Remove `pipeline_module?/1` — no longer needed
- Return `{:ok, %PipelineSpec{}}` instead of `{:ok, module}`

Update `Mix.Tasks.TinyCi.Run`:
- Replace `module.__pipeline__()` with `spec.stages`
- Replace `module.__hooks__()` with `spec.hooks`
- Derive display name from `spec.name`

Update `TinyCI.Executor.skip_stage?/2` to delegate to `ConditionEval`:

```elixir
# Before — calling a compiled function closure
defp skip_stage?(%{when_condition: f}, ctx) when is_function(f, 1), do: not f.(ctx)

# After — evaluating the stored condition AST node
defp skip_stage?(%{when_condition: nil}, _ctx), do: false
defp skip_stage?(%{when_condition: ast}, ctx),
  do: not TinyCI.DSL.ConditionEval.eval(ast, ctx)
```

The executor itself shrinks — all condition logic lives in `ConditionEval`.
Adding a new utility function (e.g. `tag/1`, `commit_message_contains/1`) only
requires changes to `ConditionEval` and `Validator`, not the executor.

### Phase 4 — Module step allowlisting

Introduce `TinyCI.DSL.ModulePolicy`:

```elixir
defmodule TinyCI.DSL.ModulePolicy do
  # Returns :ok or {:error, :not_allowed}
  def check(module, allowed_modules)

  # Load allowed modules from .tiny_ci/modules.exs or --allow-modules flag
  def load(opts)
end
```

The interpreter checks `ModulePolicy.check/2` when encountering a `module:`
option. In `--safe` mode (default for CI runners), an empty allowlist rejects
all module steps with a clear error. Users explicitly declare trusted modules.

### Phase 5 — Mode flags, migration tooling, and documentation

- Add `--safe` flag (or env var `TINY_CI_SAFE=1`) that enforces:
  - Interpreter-only mode (no `Code.compile_file/1` fallback)
  - Rejects old `defmodule`-based pipeline files (no deprecation fallback)
  - Empty module allowlist unless explicitly configured
  - `--file` restricted to project root
- Add `--allow-modules ModA,ModB` to extend the module allowlist
- Add migration tooling: `mix tiny_ci.migrate` that rewrites old-format pipeline
  files to the new flat format in-place
- Document the trust model: local use (permissive defaults), CI runners (`--safe`)
- Add OS sandboxing documentation (Docker, macOS `sandbox-exec`) as the
  complementary layer for `cmd:` shell security

---

## Security Boundary Summary

After full implementation:

| Threat | Mitigation |
|---|---|
| Arbitrary Elixir in pipeline file | AST validator + interpreter (Phase 2–3) |
| Arbitrary code in `:when` conditions | `ConditionEval` grammar — only `branch/0`, `env/1`, `file_changed?/1`, comparison and boolean operators permitted (Phase 3) |
| Inline `defmodule` in pipeline | Not in allowlist — hard rejected (Phase 2) |
| Path traversal via pipeline name | Path canonicalization (Phase 1) |
| Loading arbitrary files via `--file` | Root restriction (Phase 1) |
| `module:` step executing arbitrary code | Explicit allowlist (Phase 4) |
| `cmd:` running arbitrary shell commands | OS-level sandboxing (out of scope, documented) |
| Side effects during `--dry-run` | Eliminated — no compilation occurs (Phase 3) |

The custom DSL approach does not eliminate the shell command vector — that
requires OS-level isolation (containers, namespaces, `sandbox-exec`). It does
eliminate the Elixir code injection vector entirely and makes the tool safe for
shared CI infrastructure use when combined with `--safe` mode.
