defmodule TinyCi.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny_ci,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases()
    ]
  end

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
      {:tidewave, "~> 0.6.1"},
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
