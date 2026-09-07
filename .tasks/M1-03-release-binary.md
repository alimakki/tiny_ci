# M1-03 — Standalone binary: Burrito release, release workflow, install docs

**Milestone:** M1 · **Size:** M · **Depends on:** M1-02 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08)

## Summary

The escript from M1-01 still needs Erlang on the machine. This task wraps a `mix release` with
[Burrito](https://github.com/burrito-elixir/burrito) into one self-contained executable per
OS/arch (bundled ERTS), builds them in a release workflow on tags, publishes checksums, and
documents installation with a single download. After this, "install tiny_ci" is a `curl` and a
`chmod`.

This is the last task before M2 because the server ships as the *same* binary
(`tiny_ci serve`), so the packaging has to exist first.

## In scope

- A new sibling Mix project **`tiny_ci_dist/`** whose only job is packaging: it depends on
  `{:tiny_ci, path: ".."}` (and, from M2 on, the server and web apps), owns the Burrito
  `releases:` config (targets: macOS arm64/x86_64, Linux x86_64/arm64), and holds the
  `config/config.exs` that registers extra CLI subcommands. The root project stays a library.
- `TinyCI.Application.start/2` runs `TinyCI.CLI.main/1` with the Burrito argv when started as
  a standalone binary, and behaves exactly as today otherwise.
- `.github/workflows/release.yml`: build all targets on tag `v*`, smoke-test each on its
  native runner, attach binaries and `SHA256SUMS` to a GitHub release.
- `.tiny_ci/release.exs`: the same build steps expressed as a tiny_ci pipeline for local use
  and for the day M2's server takes over from GitHub Actions.
- `docs/install.md` and README "Installation".

## Out of scope

- Windows (roadmap: not before M2).
- Code signing / notarisation on macOS. Document the Gatekeeper workaround
  (`xattr -d com.apple.quarantine`) and open a follow-up.
- Homebrew tap, apt repository. Follow-ups once the download path is proven.

## Read first

- `mix.exs`, `lib/tiny_ci/application.ex`.
- Burrito's README and the `Burrito.Util.Args` / `Burrito.Util` module docs of the version you
  install — the argv accessor and the "am I running standalone?" predicate have changed names
  between versions; **do not guess**, read the installed source under `deps/burrito/`.
- `tiny_ci_lsp/mix.exs` — how the LSP escript forces `MIX_ENV=prod`.
- `.tiny_ci/build.exs` — the dogfood build pipeline you will extend.
- `.mise.toml` — pinned Erlang/Elixir versions; the workflow must use the same.
- `.tasks/M1-01-cli-entrypoint.md` → "Subcommand registry" — why `tiny_ci_dist` owns a config file.

## Design

### `tiny_ci_dist/mix.exs`

```elixir
defmodule TinyCI.Dist.MixProject do
  use Mix.Project

  def project do
    [app: :tiny_ci_dist, version: "0.1.0", elixir: "~> 1.19",
     start_permanent: true, deps: deps(), releases: releases()]
  end

  def application, do: [extra_applications: [:logger]]   # no code of its own

  defp deps, do: [{:tiny_ci, path: ".."}, {:burrito, "~> 1.0", runtime: false}]  # pin after `mix hex.info burrito`

defp releases do
  [
    tiny_ci: [
      steps: [:assemble, &Burrito.wrap/1],
      burrito: [
        targets: [
          macos_arm64: [os: :darwin, cpu: :aarch64],
          macos_x86_64: [os: :darwin, cpu: :x86_64],
          linux_x86_64: [os: :linux, cpu: :x86_64],
          linux_arm64: [os: :linux, cpu: :aarch64]
        ]
      ]
    ]
  ]
end

end
```

`tiny_ci_dist/config/config.exs` is where `config :tiny_ci, cli_subcommands: [...]` will be set
by M2-07 and M4-01; create it now with an empty list and a comment.

Burrito needs Zig (a specific version, printed by Burrito when missing), `xz`, and `7z` on the
*build* host only. tiny_ci has no NIFs, so all four targets can be cross-built from one
Linux host. Dev-only deps are `only: :dev` and are excluded from a `MIX_ENV=prod` release.

### Application start

```elixir
def start(_type, _args) do
  children = [...]
  {:ok, sup} = Supervisor.start_link(children, strategy: :one_for_one, name: TinyCI.Supervisor)
  maybe_run_cli()
  {:ok, sup}
end

defp maybe_run_cli do
  if standalone?() do
    args = Burrito.Util.Args.argv()     # verify the exact function in the installed version
    Task.start(fn -> TinyCI.CLI.main(args) end)   # main/1 halts with the exit code
  end
end
```

`standalone?/0` uses Burrito's own predicate (verify name) **or** the presence of the env var
Burrito sets for wrapped binaries; add a fallback `Application.get_env(:tiny_ci, :standalone_cli, false)`
so a test can exercise the branch. Under Mix and in the escript, `standalone?/0` is false and
the application behaves exactly as today. `Burrito.Util.Args` is only referenced inside the
branch, and Burrito is `runtime: false` — reference it via `apply/3` or `Code.ensure_loaded?/1`
so `mix compile --warnings-as-errors` does not complain in non-release builds.

### Release workflow (`.github/workflows/release.yml`)

- Trigger: `push: tags: ['v*']` and `workflow_dispatch`.
- Job `build` (ubuntu-24.04): `erlef/setup-beam` with the versions from `.mise.toml`; install
  Zig (the version Burrito requires), `xz-utils`, `p7zip-full`; `mix deps.get`;
  `cd tiny_ci_dist && MIX_ENV=prod mix release`; upload `tiny_ci_dist/burrito_out/*` as artifacts.
- Job `smoke` (matrix: `macos-14` arm64, `macos-13` x86_64, `ubuntu-24.04` x86_64,
  `ubuntu-24.04-arm` arm64): download the matching binary, `chmod +x`, run `tiny_ci version`
  and `tiny_ci run --dry-run --no-color` in `test/fixtures/non_elixir_project/` (create it:
  `go.mod` + `tiny_ci.exs` with two echo steps). Fail the job if either exits non-zero.
- Job `publish` (needs smoke): `sha256sum` → `SHA256SUMS`; `softprops/action-gh-release` with
  all binaries and the checksums.

Yes, this uses GitHub Actions to build a CI system. It is the honest choice until M2 exists;
the `.tiny_ci/release.exs` pipeline below is the same steps in tiny_ci's own language so the
switch later is a config change.

### `.tiny_ci/release.exs`

```elixir
name :release
env "MIX_ENV": "prod"
stage :deps do
  step :get, cmd: "mix deps.get"
end
stage :release, needs: [:deps] do
  step :burrito, cmd: "mix release --overwrite", working_dir: "tiny_ci_dist", timeout: 1_200_000
end
stage :smoke, needs: [:release] do
  step :version, cmd: "../tiny_ci_dist/burrito_out/tiny_ci_$TINY_CI_TARGET version", working_dir: "test"
  step :dry_run, cmd: "../../../tiny_ci_dist/burrito_out/tiny_ci_$TINY_CI_TARGET run --dry-run --no-color", working_dir: "test/fixtures/non_elixir_project"
end
```

(`TINY_CI_TARGET` is set by the caller; document `macos_arm64` etc. Adjust to the exact
output file names Burrito produces.)

### Install docs (`docs/install.md`)

- Download table by OS/arch with the release URL pattern.
- `chmod +x tiny_ci && mv tiny_ci /usr/local/bin/`.
- `sha256sum -c SHA256SUMS --ignore-missing`.
- macOS Gatekeeper note.
- First-run note: Burrito extracts the payload to a cache dir on first launch (~1 s), later
  launches are fast; `tiny_ci maintenance uninstall` removes it (verify the maintenance
  subcommand name in the installed Burrito version).
- Alternatives: `mix escript.install github <repo>` for Elixir users; `mix tiny_ci.run` inside
  an Elixir project.

## TDD plan

Most of this task is build configuration, verified by running it. The unit-testable part is
the application branch.

1. **`test/tiny_ci/application_test.exs`** — with `Application.put_env(:tiny_ci, :standalone_cli, true)`
   and a stubbed argv provider (make the argv accessor a private function that reads
   `Application.get_env(:tiny_ci, :standalone_argv)` first, then Burrito), restarting the
   application runs `TinyCI.CLI.run/1` with those args — assert via a message the stub sends,
   **not** by halting. `async: false`, restore env in `on_exit`. → implement `maybe_run_cli/0`.
2. Create `tiny_ci_dist/`, add the Burrito dep and release config; run
   `cd tiny_ci_dist && MIX_ENV=prod mix release`; confirm `burrito_out/` contains four files. If Zig is not installed locally, install the version
   Burrito names, or build only the host target for the local check by temporarily reducing
   `targets` (do not commit that).
3. Run the host binary: `./burrito_out/tiny_ci_<host> version`, then `run --dry-run` in
   `test/fixtures/non_elixir_project/`, then a real `run` there. Confirm `IO.ANSI.enabled?`
   behaves (colour in a TTY, none when piped) and that `--no-color` works.
4. Write the workflow; push a `v0.2.0-rc1` tag on a branch (or use `workflow_dispatch`) and
   iterate until `smoke` passes on all four runners.
5. Write `.tiny_ci/release.exs`; run `TINY_CI_TARGET=macos_arm64 mix tiny_ci.run release`
   (or the host target) locally.
6. Docs. Full suite. `mix tiny_ci.run`.

## Acceptance criteria

- [ ] `tiny_ci_dist`'s `MIX_ENV=prod mix release` produces one executable per target with no Elixir deps
      leaking from `:dev`.
- [ ] A downloaded binary runs a shell-only pipeline green in a directory with no `mix.exs` on
      a machine with no Erlang or Elixir installed (verified by the `smoke` job on all four).
- [ ] `tiny_ci run --dry-run` from the binary matches `mix tiny_ci.run --dry-run`.
- [ ] Under Mix and in the escript, `TinyCI.Application` behaves exactly as before (all tests
      green, no CLI auto-run).
- [ ] Tagging `v*` publishes binaries and `SHA256SUMS` to a GitHub release.
- [ ] `docs/install.md` exists; README Installation links it and lists the one-line install.

## Pitfalls

- Burrito's API for argv and for detecting standalone mode has been renamed across versions.
  Read `deps/burrito/lib/burrito/util/args.ex` in the version you installed.
- `Task.start/1` for the CLI: if `main/1` raises before halting, the supervisor stays up and
  the binary hangs. Wrap `main/1`'s body so any raise prints and halts with `1`.
- Cross-building for macOS from Linux is supported by Burrito because it downloads prebuilt
  ERTS; if a target's ERTS for the pinned OTP is not available yet, pin OTP to the newest
  version Burrito offers rather than the one in `.mise.toml`, and note the deviation.
- Release size: expect 20–40 MB per binary. Fine.

## Docs

- `docs/install.md` (new), README Installation.

## Follow-ups

- macOS notarisation.
- Homebrew tap / apt repo.
