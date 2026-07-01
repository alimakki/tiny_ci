defmodule Mix.Tasks.TinyCi.AttestTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  alias TinyCI.Provenance.Signer.LocalKey

  @tmp_dir "test/tmp/attest"

  setup do
    File.rm_rf!(@tmp_dir)
    File.mkdir_p!(@tmp_dir)
    on_exit(fn -> File.rm_rf!(@tmp_dir) end)

    %{private: private, public: public} = LocalKey.generate()
    key = Path.join(@tmp_dir, "signing.key")
    pub = Path.join(@tmp_dir, "signing.pub")
    File.write!(key, private)
    File.write!(pub, public)

    {:ok, key: key, pub: pub}
  end

  defp write_pipeline do
    path = Path.join(@tmp_dir, "tiny_ci.exs")

    File.write!(path, """
    stage :build, mode: :serial do
      step :compile, cmd: "echo compiling"
    end
    """)

    path
  end

  describe "gen_key task" do
    test "writes a private and public key pair" do
      out = Path.join(@tmp_dir, "generated")

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Attest.GenKey.run(["--out", out]) == :ok
        end)
      end)

      assert File.exists?(out)
      assert File.exists?(out <> ".pub")
      assert LocalKey.public_from_private(File.read!(out)) == File.read!(out <> ".pub")
    end
  end

  describe "run --attest + verify" do
    test "produces an attestation that verifies", %{key: key, pub: pub} do
      path = write_pipeline()
      out = Path.join(@tmp_dir, "attestation.json")

      capture_io(:stderr, fn ->
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Run.run(["--file", path, "--attest", out, "--signing-key", key]) ==
                   :ok
        end)
      end)

      assert File.exists?(out)
      envelope = out |> File.read!() |> Jason.decode!()
      assert envelope["payloadType"] =~ "tiny_ci"

      verify_out =
        capture_io(fn ->
          assert Mix.Tasks.TinyCi.Attest.Verify.run([out, "--key", pub]) == :ok
        end)

      assert verify_out =~ "attestation verified"
      assert verify_out =~ "outcome:  success"
    end

    test "verification fails when the attestation is modified", %{key: key, pub: pub} do
      path = write_pipeline()
      out = Path.join(@tmp_dir, "attestation.json")

      capture_io(:stderr, fn ->
        capture_io(fn ->
          Mix.Tasks.TinyCi.Run.run(["--file", path, "--attest", out, "--signing-key", key])
        end)
      end)

      # Tamper: swap the payload for a different statement.
      envelope = out |> File.read!() |> Jason.decode!()
      forged = Base.encode64(Jason.encode!(%{"_type" => "evil"}))
      File.write!(out, Jason.encode!(Map.put(envelope, "payload", forged)))

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert Mix.Tasks.TinyCi.Attest.Verify.run([out, "--key", pub]) ==
                     {:error, :verify_failed}
          end)
        end)

      assert stderr =~ "signature" or stderr =~ "verif"
    end

    test "run --attest without a signing key fails with a clear message" do
      path = write_pipeline()
      out = Path.join(@tmp_dir, "attestation.json")

      System.delete_env("TINY_CI_SIGNING_KEY")

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert Mix.Tasks.TinyCi.Run.run(["--file", path, "--attest", out]) ==
                     {:error, :attestation_failed}
          end)
        end)

      assert stderr =~ "no signing key"
      refute File.exists?(out)
    end
  end
end
