defmodule TinyCI.Provenance.Signer.LocalKey do
  @moduledoc """
  Default provenance signer: a local **Ed25519** keypair via `:crypto`.

  Keys are handled as base64-encoded raw bytes (a 32-byte private seed and a
  32-byte public key), which is what `mix tiny_ci.attest.gen_key` writes to disk.
  The public key is derivable from the private seed, so the private key file is
  sufficient to sign. Signatures are base64 in the JSON envelope.

  This is the v1 backend; see `TinyCI.Provenance.Signer` for the pluggable seam
  (cosign/sigstore/KMS).
  """

  @behaviour TinyCI.Provenance.Signer

  @algo "ed25519"

  @doc "Generates a fresh keypair: `%{private: base64, public: base64}`."
  @spec generate() :: %{private: String.t(), public: String.t()}
  def generate do
    {pub, priv} = :crypto.generate_key(:eddsa, :ed25519)
    %{private: Base.encode64(priv), public: Base.encode64(pub)}
  end

  @doc "Derives the base64 public key from a base64 private seed."
  @spec public_from_private(String.t()) :: String.t()
  def public_from_private(private_b64) do
    priv = Base.decode64!(private_b64)
    {pub, _priv} = :crypto.generate_key(:eddsa, :ed25519, priv)
    Base.encode64(pub)
  end

  @doc "A stable key identifier: the lowercase hex SHA-256 of the public key bytes."
  @spec keyid(String.t()) :: String.t()
  def keyid(public_b64) do
    public_b64
    |> Base.decode64!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @impl true
  def sign(message, opts) do
    private_b64 = Keyword.fetch!(opts, :private)
    priv = Base.decode64!(private_b64)
    public_b64 = public_from_private(private_b64)
    signature = :crypto.sign(:eddsa, :none, message, [priv, :ed25519])

    {:ok, %{"keyid" => keyid(public_b64), "algo" => @algo, "sig" => Base.encode64(signature)}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @impl true
  def verify(message, %{"sig" => sig_b64}, opts) do
    public_b64 = Keyword.fetch!(opts, :public)
    pub = Base.decode64!(public_b64)
    sig = Base.decode64!(sig_b64)

    if :crypto.verify(:eddsa, :none, message, sig, [pub, :ed25519]) do
      :ok
    else
      {:error, :invalid_signature}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def verify(_message, _signature, _opts), do: {:error, :malformed_signature}
end
