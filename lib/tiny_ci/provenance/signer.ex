defmodule TinyCI.Provenance.Signer do
  @moduledoc """
  Behaviour for provenance signers, keeping the signing backend pluggable.

  The default implementation, `TinyCI.Provenance.Signer.LocalKey`, uses a local
  Ed25519 keypair via `:crypto`. An organisation can supply an alternative
  (cosign/sigstore, a KMS, an HSM) by implementing this behaviour and passing the
  module to `TinyCI.Provenance.Attestation`.

  A signature is returned as a map with `"keyid"`, `"algo"`, and a base64 `"sig"`,
  so it round-trips cleanly through the JSON envelope.
  """

  @type signature :: %{required(String.t()) => String.t()}

  @doc "Signs `message` bytes, returning a signature map or an error."
  @callback sign(message :: binary(), opts :: keyword()) ::
              {:ok, signature()} | {:error, term()}

  @doc "Verifies `signature` over `message`; `:ok` when valid."
  @callback verify(message :: binary(), signature :: signature(), opts :: keyword()) ::
              :ok | {:error, term()}
end
