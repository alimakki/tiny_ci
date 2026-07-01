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

  `PATH` defaults to `tiny_ci`.
  """

  use Mix.Task

  alias TinyCI.Provenance.Signer.LocalKey

  @impl Mix.Task
  def run(args) do
    {opts, _positional, _invalid} =
      OptionParser.parse(args, switches: [out: :string], aliases: [o: :out])

    out = opts[:out] || "tiny_ci"
    pub_path = out <> ".pub"

    %{private: private, public: public} = LocalKey.generate()

    File.write!(out, private)
    File.write!(pub_path, public)

    IO.puts("Wrote private key: #{out}")
    IO.puts("Wrote public key:  #{pub_path}")
    IO.puts(:stderr, "Keep #{out} secret; distribute #{pub_path} for verification.")

    :ok
  end
end
