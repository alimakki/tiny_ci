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
