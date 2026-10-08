defmodule Mix.Tasks.TinyCi.Attest.Verify do
  @shortdoc "Verifies a signed provenance attestation"

  @moduledoc """
  Verifies a run attestation produced by `mix tiny_ci.run --attest`.

  Checks the signature against the given public key and that the payload has not
  been modified, then prints the run's identity and outcome.

  ## Usage

      mix tiny_ci.attest.verify FILE --key PATH.pub

  ## Exit codes

    * `0` — the attestation is authentic and unmodified
    * `1` — verification failed (bad signature, tampered payload, or bad input)

  ## Standalone

  The same command is available without Mix as `tiny_ci attest verify`
  (see `TinyCI.CLI`).
  """

  use Mix.Task

  alias TinyCI.MixDelegate

  @impl Mix.Task
  def run(args) do
    Application.ensure_all_started(:tiny_ci)
    ["verify" | args] |> TinyCI.CLI.Attest.run() |> MixDelegate.halt_unless_test(:verify_failed)
  end
end
