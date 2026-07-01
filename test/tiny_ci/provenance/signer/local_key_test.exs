defmodule TinyCI.Provenance.Signer.LocalKeyTest do
  use ExUnit.Case, async: true

  alias TinyCI.Provenance.Signer.LocalKey

  describe "keypair generation and encoding" do
    test "generates a base64 keypair whose public key derives from the private key" do
      %{private: priv, public: pub} = LocalKey.generate()

      assert is_binary(priv) and is_binary(pub)
      assert {:ok, _} = Base.decode64(priv)
      assert LocalKey.public_from_private(priv) == pub
    end

    test "keyid is stable for a keypair" do
      %{private: priv, public: pub} = LocalKey.generate()
      assert LocalKey.keyid(pub) == LocalKey.keyid(LocalKey.public_from_private(priv))
      assert String.length(LocalKey.keyid(pub)) == 64
    end
  end

  describe "sign/verify roundtrip" do
    setup do
      {:ok, LocalKey.generate()}
    end

    test "a signature verifies against the public key", %{private: priv, public: pub} do
      {:ok, sig} = LocalKey.sign("the payload", private: priv)
      assert LocalKey.verify("the payload", sig, public: pub) == :ok
    end

    test "verification fails on tampered content", %{private: priv, public: pub} do
      {:ok, sig} = LocalKey.sign("the payload", private: priv)
      assert {:error, _} = LocalKey.verify("TAMPERED", sig, public: pub)
    end

    test "verification fails with the wrong public key", %{private: priv} do
      {:ok, sig} = LocalKey.sign("the payload", private: priv)
      other = LocalKey.generate()
      assert {:error, _} = LocalKey.verify("the payload", sig, public: other.public)
    end
  end
end
