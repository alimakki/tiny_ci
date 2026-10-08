defmodule Mix.Tasks.TinyCi.Attest.GenKey do
  @shortdoc "Generates an Ed25519 keypair for signing provenance attestations"

  @moduledoc """
  Generates a local Ed25519 keypair used to sign and verify run attestations
  (see `mix tiny_ci.run --attest` and `mix tiny_ci.attest.verify`).

  ## Usage

      mix tiny_ci.attest.gen_key [--out PATH]

  Writes two base64 files:

    * `PATH`      — the **private** key (keep secret; used with `--signing-key`)
    * `PATH.pub`  — the **public** key (distribute; used with `--key` to verify)

  `PATH` defaults to `tiny_ci.key`. The private key is created with mode `0600` and
  must be kept out of version control (or stored as a CI secret). If `PATH` or `PATH.pub`
  already exists (a symlink counts), nothing is written and the task fails; if a write fails
  part-way, the files it created are removed.

  ## Standalone

  The same command is available without Mix as `tiny_ci attest gen-key`
  (see `TinyCI.CLI`).
  """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)
    ["gen-key" | args] |> TinyCI.CLI.Attest.run() |> MixDelegate.raise_on_error()
  end
end
