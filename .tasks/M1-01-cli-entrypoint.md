# M1-01 — `TinyCI.CLI` entrypoint; the Mix tasks become thin wrappers

**Milestone:** M1 · **Size:** M · **Depends on:** M0-06 · **Status:** ⬜ Not started
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

- [ ] `TinyCI.CLI.run/1` returns `0 | 1 | 2` and never halts; `main/1` halts with that code.
- [ ] Every `mix tiny_ci.*` task (except `gen.action`) is a delegate of at most five lines.
- [ ] All pre-existing Mix task tests pass without modification.
- [ ] `tiny_ci run --dry-run` and `mix tiny_ci.run --dry-run` produce identical output.
- [ ] Unknown flags are usage errors with exit code `2` (tested).
- [ ] `mix escript.build` produces `./tiny_ci`; it is gitignored; the dogfood build pipeline
      builds and smoke-tests it.
- [ ] `lib/tiny_ci/cli/**` contains no `Mix.` reference.
- [ ] A subcommand registered via `:cli_subcommands` is dispatched and listed in help.

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

## Follow-ups

_(none yet)_
