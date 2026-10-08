defmodule TinyCI.CLI.AttestTest do
  # async: false because the tests capture stderr (one global device), and one test
  # changes the working directory (restored in on_exit) to exercise the default path.
  use ExUnit.Case, async: false

  # The ANSI flag is global; assert plain text regardless of the suite default.
  setup do
    TinyCI.AnsiFixtures.set_ansi(false)
  end

  import ExUnit.CaptureIO

  alias TinyCI.CLI
  alias TinyCI.CLI.Attest
  alias TinyCI.Provenance.Signer.LocalKey

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    %{private: private, public: public} = LocalKey.generate()
    key = Path.join(tmp, "signing.key")
    pub = Path.join(tmp, "signing.pub")
    File.write!(key, private)
    File.write!(pub, public)

    pipeline = Path.join(tmp, "tiny_ci.exs")
    File.write!(pipeline, "stage :build do\n  step :compile, cmd: \"echo compiling\"\nend\n")

    {:ok, key: key, pub: pub, pipeline: pipeline}
  end

  defp invoke(argv) do
    parent = self()

    stderr =
      capture_io(:stderr, fn ->
        stdout = capture_io(fn -> send(parent, {:code, CLI.run(argv)}) end)
        send(parent, {:stdout, stdout})
      end)

    assert_received {:code, code}
    assert_received {:stdout, stdout}
    {code, stdout, stderr}
  end

  describe "gen-key hardening" do
    test "with no --out, the pair is written to tiny_ci.key and tiny_ci.key.pub in the cwd",
         %{tmp_dir: tmp} do
      previous = File.cwd!()
      on_exit(fn -> File.cd!(previous) end)
      work = Path.join(tmp, "cwd")
      File.mkdir_p!(work)
      File.cd!(work)

      assert {0, _stdout, _stderr} = invoke(["attest", "gen-key"])
      assert File.regular?(Path.join(work, "tiny_ci.key"))
      assert File.regular?(Path.join(work, "tiny_ci.key.pub"))
    end

    test "a dangling symlink at the public path counts as existing", %{tmp_dir: tmp} do
      out = Path.join(tmp, "k")
      File.ln_s!(Path.join(tmp, "nowhere"), out <> ".pub")

      assert {1, "", stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stderr =~ "#{out}.pub already exists"
      refute File.exists?(out)
      assert {:ok, %{type: :symlink}} = File.lstat(out <> ".pub")
    end

    test "a dangling symlink at the private path counts as existing", %{tmp_dir: tmp} do
      out = Path.join(tmp, "k")
      File.ln_s!(Path.join(tmp, "nowhere"), out)

      assert {1, "", stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stderr =~ "#{out} already exists"
      assert {:error, :enoent} = File.lstat(out <> ".pub")
    end

    test "a failure creating the public file leaves no private key behind", %{tmp_dir: tmp} do
      out = Path.join(tmp, String.duplicate("a", 253))

      assert {1, "", stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stderr =~ "Could not write"
      assert {:error, :enoent} = File.lstat(out)
    end

    test "a public file appearing after the check leaves no private key behind",
         %{tmp_dir: tmp} do
      out = Path.join(tmp, "raced")
      File.write!(out <> ".pub", "someone else's")

      assert {:error, {:failed, message}} = Attest.write_pair(out, out <> ".pub", "sk", "pk")
      assert message =~ "#{out}.pub already exists"
      assert File.read!(out <> ".pub") == "someone else's"
      assert {:error, :enoent} = File.lstat(out)
    end

    test "write_pair writes both files, the private one with mode 0600", %{tmp_dir: tmp} do
      out = Path.join(tmp, "pair")

      assert :ok = Attest.write_pair(out, out <> ".pub", "sk", "pk")
      assert File.read!(out) == "sk"
      assert File.read!(out <> ".pub") == "pk"
      assert Bitwise.band(File.stat!(out).mode, 0o777) == 0o600
    end

    test "create_exclusive never touches an existing file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "existing")
      File.write!(path, "precious")

      assert {:error, :eexist} = Attest.create_exclusive(path, 0o600)
      assert File.read!(path) == "precious"
    end

    test "a failed write removes what was created: bad private contents, then bad public ones",
         %{tmp_dir: tmp} do
      out = Path.join(tmp, "cleanup")

      assert {:error, {:failed, _}} = Attest.write_pair(out, out <> ".pub", :not_binary, "pk")

      assert File.ls!(tmp) |> Enum.reject(&(&1 in ["signing.key", "signing.pub", "tiny_ci.exs"])) ==
               []

      assert {:error, {:failed, _}} = Attest.write_pair(out, out <> ".pub", "sk", :not_binary)

      assert File.ls!(tmp) |> Enum.reject(&(&1 in ["signing.key", "signing.pub", "tiny_ci.exs"])) ==
               []
    end

    test "--out with an empty value or no value is a usage error, not the default" do
      for argv <- [["--out", ""], ["--out"], ["-o", ""], ["-o"]] do
        assert {2, "", stderr} = invoke(["attest", "gen-key" | argv])
        assert stderr =~ "--out requires a non-empty path"
      end
    end

    test "an unknown flag or a stray argument is a usage error", %{tmp_dir: tmp} do
      out = Path.join(tmp, "k")

      assert {2, "", stderr} = invoke(["attest", "gen-key", "--out", out, "--bogus"])
      assert stderr =~ "Invalid option(s): --bogus"

      assert {2, "", stderr} = invoke(["attest", "gen-key", "stray"])
      assert stderr =~ "Unexpected argument: stray"

      refute File.exists?(out)
    end

    test "the -o alias still works", %{tmp_dir: tmp} do
      out = Path.join(tmp, "aliased")

      assert {0, _stdout, _stderr} = invoke(["attest", "gen-key", "-o", out])
      assert File.exists?(out <> ".pub")
    end
  end

  describe "tiny_ci attest gen-key" do
    test "writes a private and public key pair", %{tmp_dir: tmp} do
      out = Path.join(tmp, "generated")

      assert {0, stdout, stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stdout =~ "Wrote private key: #{out}"
      assert stderr =~ "Keep #{out} secret"
      assert LocalKey.public_from_private(File.read!(out)) == File.read!(out <> ".pub")
    end

    test "the default path is tiny_ci.key, never the name of the executable" do
      assert Attest.default_out() == "tiny_ci.key"
      assert Attest.help() =~ "defaults to `tiny_ci.key`"
    end

    test "the private key is created with mode 0600", %{tmp_dir: tmp} do
      out = Path.join(tmp, "secret")

      assert {0, _stdout, _stderr} = invoke(["attest", "gen-key", "--out", out])
      assert Bitwise.band(File.stat!(out).mode, 0o777) == 0o600
    end

    test "an existing private key is not overwritten, and no public key is written",
         %{tmp_dir: tmp} do
      out = Path.join(tmp, "existing")
      File.write!(out, "precious")

      assert {1, "", stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stderr =~ "#{out} already exists"
      assert stderr =~ "--out"
      assert File.read!(out) == "precious"
      refute File.exists?(out <> ".pub")
    end

    test "an existing public key is not overwritten, and no private key is written",
         %{tmp_dir: tmp} do
      out = Path.join(tmp, "existing")
      File.write!(out <> ".pub", "precious")

      assert {1, "", stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stderr =~ "#{out}.pub already exists"
      assert File.read!(out <> ".pub") == "precious"
      refute File.exists?(out)
    end

    test "the Mix task still succeeds on a fresh path", %{tmp_dir: tmp} do
      out = Path.join(tmp, "via-mix")

      capture_io(:stderr, fn ->
        capture_io(fn -> assert Mix.Tasks.TinyCi.Attest.GenKey.run(["--out", out]) == :ok end)
      end)

      assert File.exists?(out <> ".pub")
    end

    test "an unwritable path is a failure (1), not a crash", %{tmp_dir: tmp} do
      out = Path.join([tmp, "missing-dir", "key"])

      assert {1, _stdout, stderr} = invoke(["attest", "gen-key", "--out", out])
      assert stderr =~ "Could not write"
      assert stderr =~ out
    end
  end

  describe "tiny_ci attest verify" do
    test "verifies an attestation written by `tiny_ci run --attest`", ctx do
      out = Path.join(ctx.tmp_dir, "attestation.json")

      assert {0, _stdout, _stderr} =
               invoke(["run", "--file", ctx.pipeline, "--attest", out, "--signing-key", ctx.key])

      assert {0, stdout, ""} = invoke(["attest", "verify", out, "--key", ctx.pub])
      assert stdout =~ "attestation verified"
      assert stdout =~ "outcome:  success"
    end

    test "a modified attestation fails verification (1)", ctx do
      out = Path.join(ctx.tmp_dir, "attestation.json")
      invoke(["run", "--file", ctx.pipeline, "--attest", out, "--signing-key", ctx.key])

      envelope = out |> File.read!() |> Jason.decode!()
      forged = Base.encode64(Jason.encode!(%{"_type" => "evil"}))
      File.write!(out, Jason.encode!(Map.put(envelope, "payload", forged)))

      assert {1, "", stderr} = invoke(["attest", "verify", out, "--key", ctx.pub])
      assert stderr =~ "signature" or stderr =~ "verif"
    end

    test "an unreadable file is a failure (1)", ctx do
      missing = Path.join(ctx.tmp_dir, "nope.json")

      assert {1, "", stderr} = invoke(["attest", "verify", missing, "--key", ctx.pub])
      assert stderr =~ "Could not read"
    end

    test "a missing file or key is a usage error (2)", ctx do
      assert {2, "", stderr} = invoke(["attest", "verify", "--key", ctx.pub])
      assert stderr =~ "Usage: attest verify FILE --key PATH.pub"

      assert {2, "", stderr} = invoke(["attest", "verify", "file.json"])
      assert stderr =~ "Missing --key"
    end
  end

  test "an unknown or missing attest command is a usage error (2)" do
    for argv <- [["attest"], ["attest", "bogus"]] do
      assert {2, "", stderr} = invoke(argv)
      assert stderr =~ "gen-key"
      assert stderr =~ "verify"
    end
  end
end
