# Dogfooding: tiny_ci builds tiny_ci.
#
# Compiles the core app and produces the language-server escript that editors
# launch (tiny_ci_lsp/tiny_ci_lsp). Driven by the `enter` hook in .mise.toml,
# and runnable directly with `mix tiny_ci.run build`.
name :build

on_success :built, cmd: "echo '[tiny_ci] build complete'"
on_failure :built, cmd: "echo '[tiny_ci] build FAILED' 1>&2"

# Fetch deps for both mix projects. Independent dirs, so run them together.
stage :deps, mode: :parallel do
  step :core, cmd: "mix deps.get"
  step :lsp, cmd: "mix deps.get", working_dir: "tiny_ci_lsp"
end

# Build the core app.
stage :compile, needs: [:deps], mode: :serial do
  step :core, cmd: "mix compile"
end

# Build the language-server escript. mix.exs forces MIX_ENV=prod so dev-only
# deps (tidewave, bandit) stay out of the binary and can't corrupt the LSP
# stdio stream.
stage :escript, needs: [:compile], mode: :serial do
  step :lsp, cmd: "mix escript.build", working_dir: "tiny_ci_lsp"
end

# Build the standalone `tiny_ci` escript for the core app (./tiny_ci, gitignored) and
# smoke-test it: it must start, report a version, and plan this repo's own pipeline.
# Like the LSP escript, mix.exs forces MIX_ENV=prod so tidewave/bandit stay out.
stage :cli, needs: [:compile], mode: :serial do
  step :build, cmd: "mix escript.build"
  step :version, cmd: "./tiny_ci version"
  step :dry_run, cmd: "./tiny_ci run --dry-run --no-color"
end

# Prove the freshly built escript runs a shell-only pipeline in a directory with
# no mix.exs (M1-02). Rebuilds the escript in :prod inside the test's setup_all.
stage :smoke, needs: [:cli], mode: :serial do
  step :non_elixir_dir, cmd: "TINY_CI_ESCRIPT=1 mix test --only escript"
end
