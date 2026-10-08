# M1-01 — `TinyCI.CLI` entrypoint; the Mix tasks become thin wrappers

**Milestone:** M1 · **Size:** M · **Depends on:** M0-06 · **Status:** ✅ Done (2026-10-07)
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

All user-facing behaviour lives in `Mix.Tasks.TinyCi.*` modules. That ties tiny_ci to a Mix
project and to an installed Elixir toolchain. This task moves the logic into a `TinyCI.CLI`
namespace with a single `main/1` entrypoint and subcommands, makes each Mix task a
three-line delegate, and builds an escript (`tiny_ci`) as the first toolchain-light
distribution. M1-03 wraps the same entrypoint into a standalone binary.

Nothing about the run semantics changes. Every existing Mix-task test must pass untouched.

## In scope

- `TinyCI.CLI` (`lib/tiny_ci/cli.ex`): `main/1`, `run/1 :: exit_code`, subcommand dispatch,
  help, version, `--no-color`.
- `TinyCI.CLI.Run` — the body of `Mix.Tasks.TinyCi.Run` moved verbatim (then tidied), returning
  `:ok | {:error, reason}` exactly as the Mix task does today.
- `TinyCI.CLI.Runs`, `TinyCI.CLI.Cache`, `TinyCI.CLI.Attest`, `TinyCI.CLI.Actions` — the same
  treatment for `tiny_ci.runs`, `tiny_ci.cache`, `tiny_ci.attest.*`, `tiny_ci.actions.*`.
- Mix tasks delegate; `Mix.Tasks.TinyCi.Gen.Action` stays Mix-only (it writes into `lib/`).
- `mix.exs`: `escript: [main_module: TinyCI.CLI, name: "tiny_ci"]` and
  `cli/0` with `preferred_envs: ["escript.build": :prod]` (the pattern `tiny_ci_lsp/mix.exs`
  already uses to keep dev-only deps out of the artifact).
- Tests for dispatch, exit codes, and dry-run parity between `tiny_ci run` and `mix tiny_ci.run`.

## Out of scope

- Running outside a Mix project (M1-02) and the Burrito binary (M1-03).
- New flags beyond `--no-color`, `--version`, `--help`.

## Read first

- `lib/mix/tasks/tiny_ci.run.ex` — all of it; note `maybe_halt/1` and `halt_unless_test/1`
  (`if Mix.env() != :test, do: System.halt(code)`), which is the only Mix-dependent line in
  the body.
- `lib/mix/tasks/tiny_ci.cache.ex`, `tiny_ci.actions.{audit,index,search}.ex`,
  `tiny_ci.attest.{gen_key,verify}.ex`, and (after M0-06) `tiny_ci.runs.ex`.
- `test/mix/tasks/*.exs` — these call `Mix.Tasks.TinyCi.X.run/1` directly and assert on return
  values and captured IO. They are the regression net for this task.
- `tiny_ci_lsp/mix.exs` — escript + `preferred_envs`.
- `AGENTS.md` → "CLI Application Specifics" (OptionParser, exit codes, separation of CLI
  from business logic).

## Design

### Entry and exit codes

```elixir
defmodule TinyCI.CLI do
  @spec main([String.t()]) :: no_return()
  def main(argv), do: argv |> run() |> System.halt()

  @spec run([String.t()]) :: 0 | 1 | 2
  def run(argv)
end
```

`run/1` never calls `System.halt/1`, so tests can call it. Exit codes: `0` success, `1` a
pipeline or command failed, `2` usage error (unknown subcommand, bad flag). Usage errors
print the relevant help to stderr.

### Subcommands

```
tiny_ci run [NAME] [flags…]          # == mix tiny_ci.run
tiny_ci runs [list|show ID|prune]     # == mix tiny_ci.runs
tiny_ci cache [clean|prune|stats]     # == mix tiny_ci.cache
tiny_ci attest gen-key|verify …       # == mix tiny_ci.attest.*
tiny_ci actions audit|index|search …  # == mix tiny_ci.actions.*
tiny_ci version | --version
tiny_ci help [SUBCOMMAND] | --help
```

`tiny_ci` with no arguments prints help and exits `2`. Global flags parsed before dispatch:
`--no-color` (calls `Application.put_env(:elixir, :ansi_enabled, false)`), `--version`, `--help`.

### Subcommand registry (for sibling apps)

Core must never depend on the server or web apps, yet the one binary has to offer `serve`
(M2-07) and `runner` (M4-01). Dispatch therefore consults a registry in application env:

```elixir
# built-in subcommands live in a module attribute; extras come from config
extras = Application.get_env(:tiny_ci, :cli_subcommands, [])   # [{"serve", TinyCI.Server.CLI.Serve}, ...]
```

Each registered module implements `TinyCI.CLI.Subcommand` (`@callback run([String.t()]) :: :ok | {:error, term()}`
and `@callback help() :: String.t()`). Built-ins implement it too. `tiny_ci help` lists extras
after built-ins. The release project (`tiny_ci_dist`, M1-03) sets the env in its
`config/config.exs`. Add a test that registers a fake subcommand via `Application.put_env/3`
and dispatches to it (`async: false`, restore in `on_exit`).

### Moving the bodies

For each Mix task `Mix.Tasks.TinyCi.X`:

```elixir
defmodule TinyCI.CLI.X do
  @moduledoc false   # user docs live on the Mix task and in `tiny_ci help x`
  @spec run([String.t()]) :: :ok | {:error, term()}
  def run(args), do: ...  # the former Mix task body, minus halting
end

defmodule Mix.Tasks.TinyCi.X do
  use Mix.Task
  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)
    result = TinyCI.CLI.X.run(args)
    if Mix.env() != :test, do: System.halt(TinyCI.CLI.exit_code(result))
    result
  end
end
```

`TinyCI.CLI.exit_code(:ok) == 0`, `exit_code({:error, _}) == 1`. Keep the `@moduledoc` and
`@shortdoc` on the Mix tasks; `tiny_ci help run` prints the same text (store it once in
`TinyCI.CLI.Run.@help` and have the Mix task's `@moduledoc` reference it, or duplicate and
add a test that they match — pick the first).

`TinyCI.CLI.Run.run/1` keeps the current `OptionParser` switches exactly. Add `strict:` parsing
so an unknown flag is a usage error (today `_invalid` is silently dropped; make this change
deliberately and add a test — it is the one behavioural change in this task, and it is in the
user's favour).

### Escript

`mix.exs`:

```elixir
def project, do: [..., escript: escript()]
def cli, do: [preferred_envs: ["escript.build": :prod]]
defp escript, do: [main_module: TinyCI.CLI, name: "tiny_ci"]
```

The escript starts the `:tiny_ci` application (it has `mod:`), so `TinyCI.TaskSupervisor` and
`TinyCI.Control.Registry` exist before `main/1` runs. Add `/tiny_ci` (the built escript) to
`.gitignore`.

## TDD plan

1. **`test/tiny_ci/cli_test.exs`** — `describe "run/1 dispatch"`:
   `run([])` returns `2` and stderr shows usage; `run(["nope"])` returns `2` and names the
   unknown subcommand; `run(["version"])` returns `0` and prints the version from
   `Application.spec(:tiny_ci, :vsn)`; `run(["help", "run"])` prints the run help;
   `run(["--no-color", "version"])` leaves `IO.ANSI.enabled?()` false afterwards (restore it
   in `on_exit`; this test is `async: false` with a comment). → implement `TinyCI.CLI` with a
   stub `run` subcommand.
2. **`test/tiny_ci/cli/run_test.exs`** — parity: for a fixture pipeline in `tmp_dir`,
   `capture_io(fn -> TinyCI.CLI.run(["run", "--file", path, "--dry-run"]) end)` equals
   `capture_io(fn -> Mix.Tasks.TinyCi.Run.run(["--file", path, "--dry-run"]) end)`; a failing
   pipeline returns `1`; a passing one `0`; `["run", "--bogus"]` returns `2` and mentions
   `--bogus`. → move the body into `TinyCI.CLI.Run`, delegate from the Mix task, add `strict:`.
3. Re-run **all** `test/mix/tasks/*.exs` unchanged — they must stay green.
4. Repeat step 2's pattern for `runs`, `cache`, `attest`, `actions` with one smoke test each
   (`tiny_ci cache stats` prints; `tiny_ci attest gen-key --out tmp` writes; `tiny_ci actions
   search x` runs). → move each body.
5. Build the escript (`mix escript.build`), run `./tiny_ci run --dry-run` at the repo root and
   `./tiny_ci version`; confirm output matches the Mix task and that no tidewave/bandit
   startup noise appears. Add these two commands as steps to `.tiny_ci/build.exs` (the dogfood
   build pipeline) so the escript is built and smoke-tested by tiny_ci itself.
6. Full suite; `mix tiny_ci.run`; `mix tiny_ci.run build`.

## Acceptance criteria

- [x] `TinyCI.CLI.run/1` returns `0 | 1 | 2` and never halts; `main/1` halts with that code.
      (`test/tiny_ci/cli_test.exs`, "run/1 dispatch" and "exit_code/1")
- [x] Every `mix tiny_ci.*` task (except `gen.action`) is a delegate of at most five lines.
      (each `run/1` body is 4 non-blank lines)
- [x] All pre-existing Mix task tests pass, and none of their assertions was changed. (`test/mix/tasks/*.exs`;
      only the wait deadlines in `tiny_ci_attest_test.exs` were raised, see Deviations)
- [x] `tiny_ci run --dry-run` and `mix tiny_ci.run --dry-run` produce identical output.
      (`test/tiny_ci/cli/run_test.exs`, "a dry run prints the same plan…"; also checked on the
      built escript at the repo root, ANSI stripped)
- [x] Unknown flags are usage errors with exit code `2` (tested).
      (`run_test.exs`, "an unknown flag is a usage error naming the flag, and exits 2")
- [x] `mix escript.build` produces `./tiny_ci`; it is gitignored; the dogfood build pipeline
      builds and smoke-tests it. (`.tiny_ci/build.exs`, stage `:cli`)
- [x] `lib/tiny_ci/cli/**` contains no `Mix.` reference. (also asserted by a test in `cli_test.exs`)
- [x] A subcommand registered via `:cli_subcommands` is dispatched and listed in help.
      (`cli_test.exs`, "subcommand registry")

## Pitfalls

- `Mix.env/0` is only available under Mix. The CLI modules must not call it; the halting
  decision stays in the Mix task delegates.
- `System.halt/1` inside `capture_io` kills the test VM; the tests call `run/1`, never `main/1`.
- `OptionParser` `strict:` rejects `--break` unless it is declared `:keep`; the current
  `switches:` list already does that — carry it over exactly.
- `IO.ANSI.enabled?/0` in an escript depends on how the VM was started; M1-03 verifies it in a
  real terminal. Do not assert on colour in the parity test — compare with ANSI stripped, or
  run both sides with `--no-color`/`ansi_enabled: false`.

## Docs

- README: a "Installation" section listing `mix escript.build` (and the upcoming binary), and
  the `tiny_ci <subcommand>` forms next to the `mix tiny_ci.*` forms in the Usage section.
- Each Mix task's `@moduledoc` mentions its `tiny_ci` equivalent.

## Deviations

Written against `b9496e7`; implemented on `cfc4b06` (after M0-06). Where the spec and the code
disagreed, the intent won.

- **Failure contracts differ per Mix task, so the spec's uniform `result -> halt(exit_code)` wrapper
  would have broken tests.** `run` and `runs` raise `Mix.Error`; `actions.{audit,index,search}` and
  `attest.verify` return `{:error, :<x>_failed}` and halt outside `:test`; `cache` halts 1 on an unknown
  command; `attest.gen_key` returns `:ok`. The CLI bodies instead return `:ok | {:error, term}` and
  never raise or halt, and `TinyCI.MixDelegate` (`lib/mix/tiny_ci/mix_delegate.ex`) restores each task's
  existing contract: `raise_on_error/2` and `halt_unless_test/3`.
- **`Mix.` was not confined to the halt line.** `Run` also called `Mix.raise` and
  `Mix.Project.config()`; `Runs` called `Mix.raise` six times; `Audit` called `Mix.Project.config()`. These
  became result tuples and `TinyCI.Project.root_app/0` / `version/0` (the only guarded `Mix.` lines, and
  they live outside `lib/tiny_ci/cli/`).
- **Error channel.** The spec gave subcommands only `:ok | {:error, term}` but wanted exit `2` for usage
  errors. `{:error, {:usage, msg}}` exits 2 with `msg` and a `tiny_ci help <cmd>` hint on stderr;
  `{:error, {:failed, msg}}` exits 1 with `msg` on stderr; any other `{:error, _}` exits 1 and the
  subcommand has already printed its diagnostics. `exit_code/1` encodes this (spec: only 0/1).
- **Usage errors print a hint, not the whole help**, for flag-level mistakes (`run` help is ~100 lines).
  An unknown or missing *command* prints the top-level help.
- **`halt_unless_test/3` always uses status 1, not `exit_code/1`.** The Mix tasks never used 2. It prints a
  `:usage`/`:failed` message itself (the dispatcher does that for the standalone command), and takes
  `halt_on_ok: false` for `tiny_ci.cache`, which never halted on success.
- **`mix tiny_ci.cache` with an unknown command** now returns `{:error, :cache_failed}` under `MIX_ENV=test`
  (it used to return `nil`); outside tests it still prints the usage and halts 1.
- **`mix tiny_ci.run` is strict too.** Both front ends share `TinyCI.CLI.Run`, so `mix tiny_ci.run --bogus`
  now raises `Mix.Error` ("Invalid option(s): --bogus") instead of silently ignoring the flag.
- **`tiny_ci attest gen-key` reports write failures** as `{:error, {:failed, "Could not write …"}}` (exit 1)
  where the task used `File.write!` and crashed (it now creates the files with `File.open` `[:write,
  :exclusive]` and writes with `:file.write/2`; see the "safe by default" entry below). Missing `FILE` / `--key` for `attest verify` are
  usage errors (2 standalone, still 1 from the Mix task).
- **`tool_version` in attestations** is now tiny_ci's own version (`TinyCI.Project.version/0`); under Mix it
  used to be the host project's version.
- **Help is written once.** `TinyCI.CLI.{Run,Runs,Cache}.help/1` takes the command name; the Mix tasks set
  `@moduledoc TinyCI.CLI.Run.help("mix tiny_ci.run") <> …` (plus a "Standalone" section), and the
  standalone help says `tiny_ci run`. `run`'s help now also documents `--no-cache`, `--artifacts-dir`,
  `--list-artifacts`, `--attest` and `--signing-key`, which the moduledoc used to omit. `attest` and `actions`
  have a concise group help in the CLI module; the individual Mix tasks keep their longer moduledocs and gain a
  "Standalone" section.
- **`--no-color` is only as strong as the spec's mechanism, and is documented as such.** It sets
  `:elixir, :ansi_enabled` to `false`, but the reporter, dry-run printer, and other existing output call
  `IO.ANSI.green()` and friends directly, which always emit escape codes. So `tiny_ci run --no-color` still
  prints colour codes. What changes is `IO.ANSI.enabled?/0`: output falls back to buffered and the breakpoint
  console is not started (the terminal is treated as non-interactive), plus the dispatcher's own messages.
  The help text, moduledoc, and README say exactly that (a test pins the help wording against "disable
  colours"). Console output had to stay byte-identical, so stripping is a follow-up.
- **CLI-module messages are front-end neutral.** They are shared by `tiny_ci <cmd>` and `mix tiny_ci.<cmd>`,
  so usage errors and hints name the subcommand, not an executable: "Usage: runs show RUN_ID …",
  "Usage: cache clean … | stats", "Usage: attest verify FILE --key PATH.pub", "generate an index with
  `actions index`", "Generate one with `attest gen-key`", "Run `actions audit` to inspect …". This changes the
  Mix tasks' text (they used to say `mix tiny_ci.runs show …`, etc.). The `help` text still names the front end
  because `help/1` takes the command prefix. `TinyCI.CLI.print_error/1` colours only the first line of a
  message (restoring the cache usage message's original span) and is shared with `TinyCI.MixDelegate`.
  Pinned by `test/tiny_ci/cli/messages_test.exs`.
- **`Run.parse/1` is exposed (`@doc false`)** so the switch table can be tested for types; an invalid value is
  reported with the flag (`--break-timeout abc`).
- **`help --help` / `help -h`** print the top-level help (exit 0), and `help version` / `help help` print a
  short description of those meta commands (exit 0). Tests: `cli_test.exs`, "run/1 dispatch".
- **`TinyCI.Project.root_app/0` also requires `Mix.ProjectStack` to be alive**, so it returns `nil` instead of
  exiting when Mix's modules are loadable but Mix is not running. Pinned by a subprocess test
  (`test/tiny_ci/project_test.exs`: a bare `erl -noshell` with `ERL_LIBS` pointing at Elixir's libraries; it is
  skipped with a message if `erl` is not on the PATH). Verified to fail with `{noproc, …}` when the guard is
  removed. `Sandbox.Trust` was left alone (M1-02).
- **`runs`, `cache`, `attest.gen_key` and `attest.verify` Mix tasks now call
  `Application.ensure_all_started(:tiny_ci)`**, which they did not before. Harmless.
- **`--no-color` is accepted by `run` itself, so `mix tiny_ci.run --no-color` works** (it was rejected by the
  strict parser; HEAD ignored it). `TinyCI.CLI.disable_color/0` is the one place the flag takes effect, used by
  the dispatcher and by `TinyCI.CLI.Run`. It is a `run` switch only and is listed in the run help. The other
  Mix tasks do not accept it. Tests: `test/tiny_ci/cli/run_test.exs`, "--no-color".
- **`attest gen-key` is safe by default and strict about its arguments.** The default `--out` is
  `tiny_ci.key` (it was `tiny_ci`, which overwrote the escript when run next to it); `/tiny_ci.key` is
  gitignored (not the `.pub`, which is meant to be distributed). Both paths are checked with `File.lstat/1`
  first, so a dangling symlink counts as existing. Then both files are created exclusively (`[:write,
  :exclusive]`; the private one gets mode `0600` before any secret is written) and only then written; if any
  step fails, only the files this invocation created are removed. If a path already exists nothing is written
  and the command exits 1 naming it. No `--force` flag (no new flags in this task). `--out` with no value or
  an empty value, an unknown flag, or a stray positional argument is a usage error (exit 2) rather than a
  silent fallback to the default. The help, Mix task moduledoc, README and `docs/provenance.md` say the
  private key must be kept out of version control or stored as a CI secret. Tests:
  `test/tiny_ci/cli/attest_test.exs` ("gen-key hardening"), including `create_exclusive/2` on an existing
  file, which fails if `:exclusive` is removed (verified).
- **A malformed `:cli_subcommands` cannot affect the built-ins.** Names must be non-empty binaries that do not
  start with `-`; the module must be loadable; a built-in (or `version` / `help`) wins over an extra of the
  same name, which is dropped silently; of two extras with one name the first wins; the value must be a
  proper list. Everything else is dropped with **one** stderr warning per invocation. An extra whose
  `help/0` raises or is not a string is listed as "(no description)", and an extra whose `run/1` returns
  anything but `:ok` / `{:error, _}` is reported on stderr and exits 1. An extra whose `run/1` itself raises
  is left to crash. Documented in the `TinyCI.CLI.Subcommand` moduledoc. Tests: `test/tiny_ci/cli_test.exs`,
  "registry rules" and "a malformed :cli_subcommands never affects the built-ins".
- **Help layout and exit codes.** The `--no-color` bullet of the `run` help was mis-indented (rendering the
  options after it as nested bullets); every bullet of the `run`, `runs` and `cache` help now has one
  indentation, in both command forms (`test/tiny_ci/cli/help_test.exs`). The `run` help documents exit code 2,
  worded per front end: the standalone help says "usage error"; the Mix form adds that the task raises a Mix
  error (exit 1) while the standalone command exits 2 (checked against both).
- **`--help` / `-h` are only flags before a `--`.** `tiny_ci run -- --help` passes `--help` through as an
  argument. A `-h` that is the *value* of a string switch (`--filter -h`) still prints help: telling it apart
  needs each subcommand's switch table, so it is a known limitation, not solved.
- **The suite is hermetic with respect to the terminal and to machine load (edits to pre-existing tests).**
  The earlier acceptance criterion "all pre-existing tests pass unmodified" is superseded for exactly these
  edits, made so that `mix test` passes in a terminal, without one, and under CPU load:
  - `test/test_helper.exs`: pins `:elixir, :ansi_enabled` to `false` for the suite (the runner keeps its own
    colours: the terminal state is read first and passed to ExUnit as `colors: [enabled: …]`); raises
    `assert_receive_timeout` from 100 ms to 3 s and the per-test `timeout` from 60 s to 180 s. In a terminal,
    `IO.ANSI.enabled?/0` was true, so `--break` started the interactive console in five Mix-task tests (four in
    `Mix.Tasks.TinyCi.RunTest`, the divergent `--attest` one in `Mix.Tasks.TinyCi.AttestTest`) that expect the
    headless path.
  - `test/tiny_ci/control/console_test.exs`: the "several boundaries paused at once" test pre-loaded its input,
    so the first command could be answered before the second pause arrived and "also paused" was never
    written (a real race, seen on a quiet machine). It now uses `TinyCI.ControllableIO` (new, in
    `test/support/`), which only answers a read when told: the test waits until the driver is provably blocked
    reading A, pauses B, and only then releases A. The other tests there sync with the server and the driver
    instead of `Process.sleep(20)`, and their 2 s / 3 s deadlines are 10 s / 15 s.
  - `test/tiny_ci/cache/lock_test.exs`: the waiter's critical section now reads a flag the holder sets at the end
    of its own, so "blocks until the first releases" is proven by ordering, not by a 50 ms window.
  - `test/tiny_ci/cache_test.exs`, `test/tiny_ci/control_integration_test.exs`: `Task.await` deadlines 5 s to
    30 s.
  - `test/tiny_ci/execution_regression_test.exs`: the module/hook timeout stimulus is 250 ms rather than 30 ms
    (under load the callback could be killed before it reported that it had started), and the wait deadlines
    are 10-15 s.
  - `test/tiny_ci/executor_test.exs`: the orphaned-process check polls `pgrep` with a 10 s deadline instead of
    sleeping 300 ms.
  - `test/mix/tasks/tiny_ci_attest_test.exs`: the divergent-run driver waits up to about 30 s (was 2 s) for the
    run to start and pause, and the run's `--break-timeout` is 30 s (was 5 s).
  New tests that assert plain text set ANSI off themselves (`TinyCI.AnsiFixtures.set_ansi/1`) and restore it.
- **Message rendering and the registry warning, round 5.** A bare binary that is not valid UTF-8 is `inspect`ed
  like other non-text messages (it used to crash `CLI.run/1` in `String.split`). The malformed-registry warning
  gives a reason for every dropped entry ("not a {name, module} tuple", "invalid name", "unloadable module",
  "duplicate name", "not a list", "not a proper list"), prints up to 8 entries of at most 120 characters each
  (small entries whole), and says "(and N more)" for the rest, so it stays well under 2 KB.
- **Registry is read once per invocation.** `TinyCI.CLI.run/1` validates `:cli_subcommands` exactly once and
  hands the result to dispatch, help and the unknown-command path (it used to re-read it up to three times,
  re-running `Code.ensure_loaded?` each time); the one-warning-per-call behaviour is unchanged. Verified in
  `cli_test.exs` by call-tracing `Code.ensure_loaded?/1` from a helper tracer process: exactly one call for the
  extra's module for `version`, `help`, `run --bogus`, an unknown command and a dispatched extra.
- **Shadowed extras are dropped silently, whatever their module.** The reserved-name check (built-ins,
  `version`, `help`) now runs before the well-formedness check, so `{"run", NoSuchModule}` no longer warns.
- **Messages from extras are rendered totally.** `{:error, {:failed | :usage, message}}` may carry any term:
  binaries print as is, other chardata is flattened with `IO.chardata_to_string/1`, and anything else (atom,
  tuple, nil, invalid chardata) is `inspect`ed, so `CLI.run/1` never raises over a returned message. Exit codes
  are unchanged (1 for `:failed`, 2 for `:usage`). An extra that raises inside its own `run/1` still crashes.
- **`help` columns are computed from what is listed**: summaries start two spaces after the longest name
  (built-ins and extras together), so a long extra name no longer runs into its summary. With only the
  built-ins the output is unchanged.
- **The registry warning is bounded**: the offending terms are `inspect`ed with `limit: 5, printable_limit:
  80`, so a config of huge bad entries produces a warning well under 2 KB (tested).
- **`--no-color` only counts before a `--`.** Like the `--help` scan, the global flag is only recognised before
  the first `--`; `run -- --no-color` looks for a pipeline named `--no-color`, and a subcommand receives
  everything after `--` untouched. README, the moduledoc and this file say "before a `--`".
- **`attest gen-key -o` / `--out` with no value** give the same "--out requires a non-empty path" usage error
  as an empty value (it used to say "Invalid option(s): -o").
- **The `run` help's exit-2 text names exactly what exits 2.** Standalone: an unknown flag, a value of the wrong
  type (`--break-timeout abc`), or `--events -` with `--output json`; other invalid values (`--output xml`, a
  bad `--break` spec or `--break-timeout-action`, an unknown `--filter` stage) are failed runs and exit 1.
  The Mix form says every one of them is a Mix error with exit 1. Pinned by `help_test.exs` and by
  `run_test.exs` ("exit code 2 is for unknown flags and wrong types…"); checked on the built escript.
- **The `root_app/0` subprocess test sets `ERL_CRASH_DUMP=/dev/null`**, so a broken guard cannot write an
  `erl_crash.dump` into the repo (verified: with the guard removed the test fails and the existing dump's mtime
  and size are unchanged).
- **README flag table** has a `--no-color` row, and says both `tiny_ci run` and `mix tiny_ci.run` accept it.
- **`CONVENTIONS.md`** baseline test count and suite time updated to the measured values.
- **`TinyCI.CLI.print_error/1` uses `IO.ANSI.format`**, so red is omitted when ANSI is disabled (for example
  stderr is not a terminal), whereas the moved bodies and HEAD always emitted raw escapes.
- **`main/1` does not call `Application.ensure_all_started/1`.** The escript starts `:tiny_ci` itself
  (verified: a real run uses `TinyCI.TaskSupervisor`, and is recorded).

## Follow-ups

Everything else raised during review was fixed in this task (see Deviations). These 13 remain, each out of
M1-01's scope:

- **Real ANSI colour stripping.** `--no-color` only changes `IO.ANSI.enabled?/0` (buffered output, no
  breakpoint console); the reporter, dry-run printer and other output call `IO.ANSI.green()` and friends
  directly, and changing that alters console output the tests pin byte-for-byte. M1-03 step 3 expects colour in
  a TTY and none when piped, which cannot hold until this is done. Related: `--break` with `--no-color` in a
  TTY prints the misleading "no interactive terminal is attached" refusal.
- **`:epipe` trace and exit 1** when piping into `head` (`tiny_ci runs | head -1`), and no top-level rescue in
  `main/1`, so an unexpected crash is indistinguishable from a pipeline failure (exit 1). Needs a design for
  what `main/1` should do with crashes.
- **`run --output xml` exits 1 while `runs --output xml` exits 2.** Changing `run` would alter the Mix-path
  stderr contract that the untouched `test/mix/tasks/*.exs` pin.
- **`Sandbox.Trust.root_app/0` duplicates `TinyCI.Project.root_app/0`**, and after `Project.root_app()` has
  loaded `Mix.Project`, `Trust.classify(Kernel)` can exit with `{:noproc, GenServer.call…}` when Mix is not
  running. M1-02 (run outside Mix) owns the dedupe and must cover this interaction.
- **`Audit.verify` with `root_app: nil`** reports app-less modules as `[local]`, so the lock gate is effectively
  open for them on the escript. M1-02 should review it (a `module:` step was not exercised on the escript).
- **SIGTERM during a run** exits 0 and leaves the step's child process running. Same under Mix; pre-existing.
- **Minimum supported OTP version for the escript.** The README says it is developed on OTP 29 (`.mise.toml`);
  the real minimum is not established.
- **`TinyCI.CLI.Run` is ~830 lines** after the move; splitting it (secrets / control / attest) is a refactor.
- **`-h` as a switch value** (`--filter -h`) is treated as a help request; see Deviations.
- **Other subcommands still parse leniently** (`runs` is strict already; `cache`, `actions` and `attest verify`
  drop unknown flags). Only `run` and `attest gen-key` were tightened, as the spec said for `run`.
- **Core module docs still name the Mix forms** (`lib/tiny_ci/{cache,control,provenance,executor}.ex`,
  `action/audit.ex`, `control/breakpoint.ex`, `provenance/signer/local_key.ex`). They are moduledocs, not text
  printed to users; all printed messages are front-end neutral.
- **`actions index` still uses `File.write!`**, so an unwritable `--out` crashes instead of exiting 1.
- **`IO.ANSI.enabled?/0` inside the escript** depends on how the VM was started; M1-03 should check it in a
  real terminal.
