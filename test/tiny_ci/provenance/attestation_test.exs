defmodule TinyCI.Provenance.AttestationTest do
  use ExUnit.Case, async: true

  alias TinyCI.Provenance.Attestation
  alias TinyCI.Provenance.Signer.LocalKey

  @statement %{
    "_type" => "https://in-toto.io/Statement/v1",
    "predicate" => %{"runId" => "run-1", "outcome" => "success"}
  }

  setup do
    {:ok, LocalKey.generate()}
  end

  describe "sign/2" do
    test "produces a DSSE-style envelope with a base64 payload and a signature",
         %{private: priv} do
      {:ok, envelope} = Attestation.sign(@statement, private: priv)

      assert envelope["payloadType"] =~ "tiny_ci"
      assert {:ok, decoded} = Base.decode64(envelope["payload"])
      assert Jason.decode!(decoded) == @statement
      assert [%{"sig" => _, "keyid" => _, "algo" => "ed25519"}] = envelope["signatures"]
    end
  end

  describe "verify/2" do
    test "verifies a freshly-signed envelope and returns the statement",
         %{private: priv, public: pub} do
      {:ok, envelope} = Attestation.sign(@statement, private: priv)
      assert {:ok, @statement} = Attestation.verify(envelope, public: pub)
    end

    test "fails when the payload is tampered", %{private: priv, public: pub} do
      {:ok, envelope} = Attestation.sign(@statement, private: priv)

      tampered =
        Map.put(
          envelope,
          "payload",
          Base.encode64(Jason.encode!(%{"_type" => "evil", "predicate" => %{}}))
        )

      assert {:error, _} = Attestation.verify(tampered, public: pub)
    end

    test "fails with the wrong public key", %{private: priv} do
      {:ok, envelope} = Attestation.sign(@statement, private: priv)
      other = LocalKey.generate()
      assert {:error, _} = Attestation.verify(envelope, public: other.public)
    end

    test "fails on a structurally invalid envelope", %{public: pub} do
      assert {:error, _} = Attestation.verify(%{"nope" => true}, public: pub)
    end
  end
end
