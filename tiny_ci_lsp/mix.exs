defmodule TinyCI.LSP.MixProject do
  use Mix.Project

  def project do
    [
      app: :tiny_ci_lsp,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # The language server is delivered as an escript that editors launch over
  # stdio. See `docs/lsp.md` in the core repo for client configuration.
  defp escript do
    [main_module: TinyCI.LSP.CLI, name: "tiny_ci_lsp"]
  end

  defp deps do
    [
      {:tiny_ci, path: ".."},
      {:gen_lsp, "~> 0.11.3"},
      {:credo, "~> 1.7.19", only: [:dev, :test], runtime: false}
    ]
  end
end
