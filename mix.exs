defmodule TinyCi.MixProject do
  use Mix.Project

  # The release workflow sets RELEASE_VERSION from the git tag so the shipped
  # binary reports the tag (`tiny_ci version`); dev and test builds keep 0.1.0.
  @version System.get_env("RELEASE_VERSION") || "0.1.0"

  def project do
    [
      app: :tiny_ci,
      version: @version,
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps(),
      aliases: aliases(),
      # `test/fixtures/` holds example projects (pipelines in the tiny_ci DSL) that
      # integration tests and the release smoke job read; they are not test files.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  # Always build the escript in :prod so dev-only deps (tidewave, bandit) stay out
  # of the binary. Those apps emit startup output that would pollute the output
  # of `tiny_ci run`, and `--output json` / `--events -` own stdout.
  def cli do
    [preferred_envs: ["escript.build": :prod]]
  end

  # The standalone `tiny_ci` command. M1-03 wraps the same entrypoint in a
  # self-contained binary.
  defp escript do
    [main_module: TinyCI.CLI, name: "tiny_ci"]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      # `:crypto` backs run ids, cache keys, artifact ids, and Ed25519 provenance
      # signing. It is a NIF-based OTP app, so it must be declared to be included
      # in a release (Burrito recompiles its NIF per target).
      extra_applications: [:logger, :crypto],
      mod: {TinyCI.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:tidewave, "~> 0.6.1", only: :dev},
      {:bandit, "~> 1.12", only: :dev},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false}
    ]
  end

  defp aliases() do
    [
      tidewave:
        "run --no-halt -e 'Agent.start(fn -> Bandit.start_link(plug: Tidewave, port: 4000) end)'"
    ]
  end
end
