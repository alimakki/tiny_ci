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

  describe "run --attest on a divergent run" do
    test "refuses to sign a run that execution control altered", %{key: key} do
      path = write_pipeline()
      out = Path.join(@tmp_dir, "attestation.json")
      events = Path.join(@tmp_dir, "run.ndjson")

      # Stand in for an external control driver (a DAP adapter, a web UI): attach to
      # the live run, edit a store key, and let it continue. That edit is what makes
      # the run divergent.
      start_divergent_driver(events)

      stderr =
        capture_io(:stderr, fn ->
          capture_io(fn ->
            assert Mix.Tasks.TinyCi.Run.run([
                     "--file",
                     path,
                     "--attest",
                     out,
                     "--signing-key",
                     key,
                     "--events",
                     events,
                     "--break",
                     "before:build.compile",
                     "--break-timeout",
                     "5000",
                     "--break-timeout-action",
                     "continue"
                   ]) == {:error, :attestation_failed}
          end)
        end)

      assert stderr =~ "Refusing to attest a divergent run"
      assert stderr =~ "set_store"
      refute File.exists?(out)

      # The divergence itself is recorded in the stream, so the refusal is auditable.
      types =
        events
        |> File.read!()
        |> String.split("\n", trim: true)
        |> Enum.map(&Jason.decode!(&1)["type"])

      assert "run_diverged" in types
    end
  end

  # Polls for the run's control plane, then issues set_store + continue. Polling
  # rather than subscribing up front because the control server does not exist until
  # the run starts, and this driver is deliberately outside the run.
  defp start_divergent_driver(events_path) do
    spawn_link(fn ->
      with {:ok, run_id} <- await_run_id(events_path, 200),
           {:ok, session} <- await_pause(run_id, 200) do
        TinyCI.Control.resume(run_id, session.pause_id, {:set_store, :tag, "v2"})
        TinyCI.Control.resume(run_id, session.pause_id, :continue)
      end
    end)
  end

  defp await_run_id(_path, 0), do: :timeout

  defp await_run_id(path, attempts) do
    case File.read(path) do
      {:ok, contents} -> first_run_id(contents) || retry_run_id(path, attempts)
      {:error, _} -> retry_run_id(path, attempts)
    end
  end

  defp retry_run_id(path, attempts) do
    Process.sleep(10)
    await_run_id(path, attempts - 1)
  end

  defp first_run_id(contents) do
    contents
    |> String.split("\n", trim: true)
    |> Enum.find_value(fn line ->
      case Jason.decode(line) do
        {:ok, %{"type" => "run_started", "run_id" => run_id}} -> {:ok, run_id}
        _ -> nil
      end
    end)
  end

  defp await_pause(_run_id, 0), do: :timeout

  defp await_pause(run_id, attempts) do
    case TinyCI.Control.paused(run_id) do
      [session | _] ->
        {:ok, session}

      _none ->
        Process.sleep(10)
        await_pause(run_id, attempts - 1)
    end
  end
end
