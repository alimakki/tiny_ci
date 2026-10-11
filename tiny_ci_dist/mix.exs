defmodule TinyCI.Dist.MixProject do
  use Mix.Project

  # Set by the release workflow from the git tag (minus the leading `v`), so the
  # shipped binary reports the tag; falls back to the dev version.
  @version System.get_env("RELEASE_VERSION") || "0.1.0"

  def project do
    [
      app: :tiny_ci_dist,
      version: @version,
      elixir: "~> 1.19",
      start_permanent: true,
      deps: deps(),
      releases: releases()
    ]
  end

  # No application of its own: the release starts `:tiny_ci`, whose
  # `TinyCI.Application` owns the CLI entrypoint (`maybe_run_cli/0`).
  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:tiny_ci, path: ".."},
      {:burrito, "~> 1.6", runtime: false}
    ]
  end

  # One self-contained executable per target, each with a bundled ERTS. Burrito is
  # a build-time step only and is not part of the release. All four targets
  # cross-build from Linux because Burrito downloads prebuilt ERTS.
  defp releases do
    [
      tiny_ci: [
        version: @version,
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
