defmodule Mix.Tasks.TinyCi.Attest.Verify do
  @shortdoc "Verifies a signed provenance attestation"

  @moduledoc """
  Verifies a run attestation produced by `mix tiny_ci.run --attest`.

  Checks the signature against the given public key and that the payload has not
  been modified, then prints the run's identity and outcome.

  ## Usage

      mix tiny_ci.attest.verify FILE --key PATH.pub

  ## Exit codes

    * `0` — the attestation is authentic and unmodified
    * `1` — verification failed (bad signature, tampered payload, or bad input)
  """

  use Mix.Task

  alias TinyCI.Provenance.Attestation

  @impl Mix.Task
  def run(args) do
    {opts, positional, _invalid} =
      OptionParser.parse(args, switches: [key: :string], aliases: [k: :key])

    result =
      with {:ok, file} <- fetch(List.first(positional), :missing_file),
           {:ok, key_path} <- fetch(opts[:key], :missing_key),
           {:ok, envelope} <- read_json(file),
           {:ok, public} <- read_key(key_path),
           {:ok, statement} <- Attestation.verify(envelope, public: public) do
        print_verified(statement)
        :ok
      end

    finish(result)
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

  defp finish(:ok), do: halt(0)

  defp finish({:error, reason}) do
    print_error(reason)
    halt(1)
  end

  defp print_error(:missing_file),
    do: error("Usage: mix tiny_ci.attest.verify FILE --key PATH.pub")

  defp print_error(:missing_key), do: error("Missing --key PATH.pub")
  defp print_error(:invalid_json), do: error("Attestation file is not valid JSON")
  defp print_error(:invalid_signature), do: error("✗ signature does not verify")
  defp print_error(:no_valid_signature), do: error("✗ no signature verifies against this key")
  defp print_error(:malformed_envelope), do: error("✗ file is not a valid attestation envelope")
  defp print_error({:unreadable, path}), do: error("Could not read: #{path}")
  defp print_error(other), do: error("Verification failed: #{inspect(other)}")

  defp error(message), do: IO.puts(:stderr, [IO.ANSI.red(), message, IO.ANSI.reset()])

  defp halt(code) do
    if Mix.env() != :test, do: System.halt(code)
    if code == 0, do: :ok, else: {:error, :verify_failed}
  end
end
