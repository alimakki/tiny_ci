defmodule TinyCI.Provenance.Attestation do
  @moduledoc """
  Wraps a provenance statement in a signed, DSSE-style envelope and verifies it.

  The envelope mirrors the [DSSE](https://github.com/secure-systems-lab/dsse)
  shape used by in-toto/SLSA:

      %{
        "payloadType" => "application/vnd.tiny_ci.provenance+json",
        "payload"     => Base.encode64(statement_json),
        "signatures"  => [%{"keyid" => …, "algo" => "ed25519", "sig" => …}]
      }

  The signature covers the **PAE** (pre-authentication encoding) of the payload
  type and bytes, not the raw JSON — so re-serialization can't change what was
  signed, and any modification to the stored payload fails verification.

  Signing is delegated to a `TinyCI.Provenance.Signer` (default:
  `TinyCI.Provenance.Signer.LocalKey`, Ed25519).
  """

  alias TinyCI.Provenance.Signer.LocalKey

  @payload_type "application/vnd.tiny_ci.provenance+json"

  @doc """
  Signs a statement map, returning a DSSE-style envelope.

  ## Options

    * `:private` — the signer's private key material (base64, for `LocalKey`)
    * `:signer`  — a `TinyCI.Provenance.Signer` module (default `LocalKey`)
  """
  @spec sign(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def sign(statement, opts) do
    signer = Keyword.get(opts, :signer, LocalKey)
    payload = Jason.encode!(statement)

    case signer.sign(pae(@payload_type, payload), opts) do
      {:ok, signature} ->
        {:ok,
         %{
           "payloadType" => @payload_type,
           "payload" => Base.encode64(payload),
           "signatures" => [signature]
         }}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Verifies an envelope and returns the enclosed statement.

  Fails if the envelope is malformed, the payload was modified, or no signature
  verifies against the given key.

  ## Options

    * `:public` — the verifying public key (base64, for `LocalKey`)
    * `:signer` — a `TinyCI.Provenance.Signer` module (default `LocalKey`)
  """
  @spec verify(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def verify(%{"payloadType" => type, "payload" => payload_b64, "signatures" => sigs}, opts)
      when is_list(sigs) do
    signer = Keyword.get(opts, :signer, LocalKey)

    with {:ok, payload} <- decode(payload_b64),
         message = pae(type, payload),
         :ok <- verify_any(signer, message, sigs, opts) do
      {:ok, Jason.decode!(payload)}
    end
  end

  def verify(_envelope, _opts), do: {:error, :malformed_envelope}

  # A signature list verifies when at least one entry is valid for the key.
  defp verify_any(signer, message, sigs, opts) do
    if Enum.any?(sigs, &(signer.verify(message, &1, opts) == :ok)) do
      :ok
    else
      {:error, :no_valid_signature}
    end
  end

  defp decode(payload_b64) do
    case Base.decode64(payload_b64) do
      {:ok, payload} -> {:ok, payload}
      :error -> {:error, :invalid_payload_encoding}
    end
  end

  # DSSE Pre-Authentication Encoding:
  #   "DSSEv1" SP LEN(type) SP type SP LEN(payload) SP payload
  defp pae(type, payload) do
    "DSSEv1 #{byte_size(type)} #{type} #{byte_size(payload)} #{payload}"
  end
end
