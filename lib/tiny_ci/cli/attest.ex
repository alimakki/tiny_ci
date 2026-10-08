defmodule TinyCI.CLI.Attest do
  @moduledoc false
  # `tiny_ci attest gen-key | verify`, the bodies of `mix tiny_ci.attest.gen_key` and
  # `mix tiny_ci.attest.verify`. The Mix tasks keep their own, longer documentation;
  # `help/0` is the concise group help for the standalone command.

  @behaviour TinyCI.CLI.Subcommand

  alias TinyCI.Provenance.Attestation
  alias TinyCI.Provenance.Signer.LocalKey

  @default_out "tiny_ci.key"

  @doc false
  @spec default_out() :: String.t()
  def default_out, do: @default_out

  @impl TinyCI.CLI.Subcommand
  def help do
    """
    Generates signing keys and verifies signed run attestations.

    Usage:

        tiny_ci attest gen-key [--out PATH]
        tiny_ci attest verify FILE --key PATH.pub

    Commands:

      * `gen-key` — writes an Ed25519 keypair: `PATH` (the private key, used with
        `tiny_ci run --signing-key`) and `PATH.pub` (the public key, used with
        `verify --key`). `PATH` defaults to `tiny_ci.key`. The private key is created
        with mode 0600 and must be kept out of version control (or stored as a CI secret).
        If `PATH` or `PATH.pub` already exists (a symlink counts), nothing is written and
        the command fails; if a write fails part-way, the files it created are removed.
      * `verify` — checks the signature and that the payload is unmodified, then
        prints the run's identity and outcome. Exit code 1 if it does not verify.

    Attestations are written by `tiny_ci run --attest PATH --signing-key KEY`.
    """
  end

  @impl TinyCI.CLI.Subcommand
  def run(["gen-key" | args]), do: gen_key(args)
  def run(["verify" | args]), do: verify(args)

  def run(_args),
    do: {:error, {:usage, "Unknown or missing command. Use gen-key or verify."}}

  # ---------------------------------------------------------------------------
  # gen-key
  # ---------------------------------------------------------------------------

  defp gen_key(args) do
    with {:ok, out} <- parse_gen_key(args),
         pub_path = out <> ".pub",
         :ok <- ensure_absent([out, pub_path]),
         %{private: private, public: public} = LocalKey.generate(),
         :ok <- write_pair(out, pub_path, private, public) do
      IO.puts("Wrote private key: #{out}")
      IO.puts("Wrote public key:  #{pub_path}")
      IO.puts(:stderr, "Keep #{out} secret; distribute #{pub_path} for verification.")
      :ok
    end
  end

  defp parse_gen_key(args) do
    case OptionParser.parse(args, strict: [out: :string], aliases: [o: :out]) do
      {opts, [], []} -> out_path(Keyword.fetch(opts, :out))
      {_opts, [], invalid} -> invalid_gen_key(invalid)
      {_opts, [arg | _], _invalid} -> {:error, {:usage, "Unexpected argument: #{arg}"}}
    end
  end

  # `--out` / `-o` with no value is reported as such, not as an invalid option.
  defp invalid_gen_key(invalid) do
    if Enum.any?(invalid, fn {flag, _value} -> flag in ["--out", "-o"] end) do
      out_required()
    else
      {:error, {:usage, invalid_message(invalid)}}
    end
  end

  defp out_path(:error), do: {:ok, @default_out}
  defp out_path({:ok, ""}), do: out_required()
  defp out_path({:ok, path}), do: {:ok, path}

  defp out_required, do: {:error, {:usage, "--out requires a non-empty path"}}

  defp invalid_message(invalid) do
    "Invalid option(s): " <> Enum.map_join(invalid, ", ", fn {flag, _value} -> flag end)
  end

  # `lstat`, not `exists?`: a dangling symlink is "absent" to `exists?` but is still in
  # the way. Both paths are checked before either is created.
  defp ensure_absent(paths) do
    case Enum.find(paths, &match?({:ok, _}, File.lstat(&1))) do
      nil -> :ok
      path -> {:error, exists_error(path)}
    end
  end

  defp exists_error(path) do
    {:failed, "#{path} already exists. Remove it, or pass a different --out."}
  end

  @doc false
  # Creates both files exclusively before writing either, so that a failure to create
  # the second cannot leave the first behind with a key in it. Anything this call
  # created is removed again if any step fails; nothing else is ever removed.
  @spec write_pair(String.t(), String.t(), binary(), binary()) :: :ok | {:error, term()}
  def write_pair(private_path, public_path, private, public) do
    case create_exclusive(private_path, 0o600) do
      {:ok, private_io} ->
        write_public(private_io, private_path, public_path, private, public)

      {:error, reason} ->
        {:error, create_error(private_path, reason)}
    end
  end

  defp write_public(private_io, private_path, public_path, private, public) do
    case create_exclusive(public_path, 0o644) do
      {:ok, public_io} ->
        result = write_both(private_io, private, public_io, public)
        File.close(private_io)
        File.close(public_io)
        finish_pair(result, [private_path, public_path])

      {:error, reason} ->
        File.close(private_io)
        File.rm(private_path)
        {:error, create_error(public_path, reason)}
    end
  end

  defp write_both(private_io, private, public_io, public) do
    with :ok <- :file.write(private_io, private) do
      :file.write(public_io, public)
    end
  end

  defp create_error(path, :eexist), do: exists_error(path)
  defp create_error(path, reason), do: write_error(path, reason)

  defp finish_pair(:ok, _paths), do: :ok

  defp finish_pair({:error, reason}, paths) do
    Enum.each(paths, &File.rm/1)
    {:error, {:failed, "Could not write #{Enum.join(paths, " and ")}: #{format(reason)}"}}
  end

  @doc false
  # Creates `path` exclusively (it never replaces an existing file or symlink) and
  # sets its mode before the caller writes anything, so a private key is never
  # readable by others, even briefly. The file is removed again if the chmod fails.
  @spec create_exclusive(String.t(), non_neg_integer()) ::
          {:ok, File.io_device()} | {:error, term()}
  def create_exclusive(path, mode) do
    case File.open(path, [:write, :exclusive]) do
      {:ok, io} -> chmod_or_undo(io, path, mode)
      {:error, reason} -> {:error, reason}
    end
  end

  defp chmod_or_undo(io, path, mode) do
    case File.chmod(path, mode) do
      :ok ->
        {:ok, io}

      {:error, reason} ->
        File.close(io)
        File.rm(path)
        {:error, reason}
    end
  end

  defp write_error(path, reason), do: {:failed, "Could not write #{path}: #{format(reason)}"}

  defp format(reason), do: :file.format_error(reason)

  # ---------------------------------------------------------------------------
  # verify
  # ---------------------------------------------------------------------------

  defp verify(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [key: :string], aliases: [k: :key])

    with {:ok, file} <- fetch(List.first(positional), :missing_file),
         {:ok, key_path} <- fetch(opts[:key], :missing_key),
         {:ok, envelope} <- read_json(file),
         {:ok, public} <- read_key(key_path),
         {:ok, statement} <- Attestation.verify(envelope, public: public) do
      print_verified(statement)
    else
      {:error, reason} -> error_result(reason)
    end
  end

  defp fetch(nil, reason), do: {:error, reason}
  defp fetch(value, _reason), do: {:ok, value}

  defp read_json(path) do
    with {:ok, content} <- File.read(path),
         {:ok, json} <- Jason.decode(content) do
      {:ok, json}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_json}
      {:error, _} -> {:error, {:unreadable, path}}
    end
  end

  defp read_key(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, String.trim(content)}
      {:error, _} -> {:error, {:unreadable, path}}
    end
  end

  defp print_verified(statement) do
    predicate = Map.get(statement, "predicate", %{})

    IO.puts([IO.ANSI.green(), "✓ attestation verified", IO.ANSI.reset()])
    IO.puts("  pipeline: #{predicate["pipeline"]}")
    IO.puts("  run:      #{predicate["runId"]}")
    IO.puts("  commit:   #{predicate["commit"]}")
    IO.puts("  outcome:  #{predicate["outcome"]}")
  end

  # Missing arguments are usage errors; every other reason is a failed verification,
  # reported here so the dispatcher has nothing further to print.
  defp error_result(:missing_file),
    do: {:error, {:usage, "Usage: attest verify FILE --key PATH.pub"}}

  defp error_result(:missing_key), do: {:error, {:usage, "Missing --key PATH.pub"}}

  defp error_result(reason) do
    IO.puts(:stderr, [IO.ANSI.red(), failure_message(reason), IO.ANSI.reset()])
    {:error, :verify_failed}
  end

  defp failure_message(:invalid_json), do: "Attestation file is not valid JSON"
  defp failure_message(:invalid_signature), do: "✗ signature does not verify"
  defp failure_message(:no_valid_signature), do: "✗ no signature verifies against this key"
  defp failure_message(:malformed_envelope), do: "✗ file is not a valid attestation envelope"
  defp failure_message({:unreadable, path}), do: "Could not read: #{path}"
  defp failure_message(other), do: "Verification failed: #{inspect(other)}"
end
