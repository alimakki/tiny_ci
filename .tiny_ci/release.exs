# Build the standalone Burrito binaries and smoke-test one of them.
#
# Run per target: `BURRITO_TARGET=linux_x86_64 mix tiny_ci.run release`
# (`macos_arm64`, `macos_x86_64`, `linux_x86_64`, `linux_arm64`). Unset,
# `mix release` builds all four, but the smoke stage needs `BURRITO_TARGET` to
# know which binary to run, so always set it here.
#
# Same steps as `.github/workflows/release.yml`, expressed in tiny_ci's own
# language so M2's server can take over from GitHub Actions by changing where
# this runs, not what it does.
name :release

env "MIX_ENV": "prod"

stage :deps do
  step :get, cmd: "mix deps.get", working_dir: "tiny_ci_dist"
end

# Burrito downloads a prebuilt ERTS per target and cross-builds with Zig, so this
# is slow the first time (several hundred MB of ERTS for four targets).
stage :release, needs: [:deps] do
  step :burrito, cmd: "mix release --overwrite", working_dir: "tiny_ci_dist", timeout: 1_800_000
end

# Prove the binary runs in a directory with no mix.exs. Serial: on a cold cache
# the first invocation unpacks the payload into the data dir, and concurrent
# first-runs race on that (`erlexec: Error 26`). `--no-record` keeps the run out
# of the developer's run history.
stage :smoke, needs: [:release], mode: :serial do
  # Burrito skips unpacking when a payload of the same version is already
  # installed, and local builds all share the dev version, so without this the
  # steps below would test the previous build's code. `uninstall` asks for
  # confirmation on stdin, and exits 0 when nothing is installed.
  step :uninstall_previous,
    cmd: "echo y | ../../../tiny_ci_dist/burrito_out/tiny_ci_$BURRITO_TARGET maintenance uninstall",
    working_dir: "test/fixtures/non_elixir_project"

  step :version,
    cmd: "../../../tiny_ci_dist/burrito_out/tiny_ci_$BURRITO_TARGET version",
    working_dir: "test/fixtures/non_elixir_project"

  step :dry_run,
    cmd: "../../../tiny_ci_dist/burrito_out/tiny_ci_$BURRITO_TARGET run --dry-run --no-color",
    working_dir: "test/fixtures/non_elixir_project"

  step :run,
    cmd: "../../../tiny_ci_dist/burrito_out/tiny_ci_$BURRITO_TARGET run --no-color --no-record",
    working_dir: "test/fixtures/non_elixir_project"
end
