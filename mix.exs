defmodule TinyCi.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny_ci,
      version: "0.1.0",
      elixir: "~> 1.19",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps(),
      aliases: aliases()
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
      extra_applications: [:logger],
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
