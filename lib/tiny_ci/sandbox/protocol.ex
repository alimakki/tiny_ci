defmodule TinyCI.Sandbox.Protocol do
  @moduledoc """
  The serialized wire format crossing the sandbox boundary.

  An action runs in a separate OS process (and later, on a separate host), so
  its inputs and outputs must cross as **plain data** — never a PID, reference,
  port, or closure that would tie the sandboxed process back to the runner's
  BEAM. This module encodes a request (`module`, `config`, `context`, `policy`)
  going in and a response (`{:ok, store_delta}` or `{:error, reason}`) coming
  out, and refuses to encode anything containing a non-serializable term.

  Terms are carried with the External Term Format; responses (which come from
  the *untrusted* sandbox) are decoded with the `:safe` flag so a malicious
  payload cannot fabricate atoms or executable terms in the runner.

  This is the same envelope the orchestrator/runner split (T16) sends over the
  wire; keeping it here keeps both boundaries honest.
  """

  @type request :: %{module: module(), config: map(), context: map(), policy: struct()}
  @type response :: {:ok, map()} | {:error, term()}

  @doc "Encodes a request to binary, or errors if any part is not serializable."
  @spec encode_request(request()) :: {:ok, binary()} | {:error, term()}
  def encode_request(%{module: module, config: config, context: context} = request)
      when is_atom(module) do
    with :ok <- ensure_serializable(config),
         :ok <- ensure_serializable(context) do
      payload = %{
        module: module,
        config: config,
        context: context,
        policy: Map.get(request, :policy)
      }

      {:ok, :erlang.term_to_binary(payload)}
    end
  end

  @doc """
  Decodes a request produced by `encode_request/1`.

  The request originates from the trusted runner, so it is decoded without the
  `:safe` flag — it must be able to carry the action's module atom before that
  module has been loaded in the sandbox.
  """
  @spec decode_request(binary()) :: {:ok, request()} | {:error, term()}
  def decode_request(binary) when is_binary(binary) do
    with {:ok, term} <- from_binary(binary, []) do
      case term do
        %{module: module} = request when is_atom(module) -> {:ok, request}
        _ -> {:error, :malformed_request}
      end
    end
  end

  @doc "Encodes an action result (normalized to `{:ok, map}` / `{:error, reason}`)."
  @spec encode_response(response()) :: {:ok, binary()} | {:error, term()}
  def encode_response({:ok, delta}) when is_map(delta) do
    with :ok <- ensure_serializable(delta) do
      {:ok, :erlang.term_to_binary({:ok, delta})}
    end
  end

  def encode_response({:error, reason}) do
    {:ok, :erlang.term_to_binary({:error, safe_reason(reason)})}
  end

  @doc "Decodes a response; the payload is treated as untrusted (`:safe`)."
  @spec decode_response(binary()) :: {:ok, map()} | {:error, term()}
  def decode_response(binary) when is_binary(binary) do
    with {:ok, term} <- from_binary(binary, [:safe]) do
      case term do
        {:ok, delta} when is_map(delta) -> {:ok, delta}
        {:error, reason} -> {:error, reason}
        _ -> {:error, :malformed_response}
      end
    end
  end

  @doc """
  Returns `:ok` if `term` contains only serializable data, or
  `{:error, {:not_serializable, kind}}` for the first offending term.
  """
  @spec ensure_serializable(term()) :: :ok | {:error, {:not_serializable, atom()}}
  def ensure_serializable(term) do
    case offending(term) do
      nil -> :ok
      kind -> {:error, {:not_serializable, kind}}
    end
  end

  defp offending(term) when is_pid(term), do: :pid
  defp offending(term) when is_reference(term), do: :reference
  defp offending(term) when is_port(term), do: :port
  defp offending(term) when is_function(term), do: :function
  defp offending(term) when is_list(term), do: Enum.find_value(term, &offending/1)

  defp offending(term) when is_tuple(term) do
    term |> Tuple.to_list() |> offending()
  end

  defp offending(term) when is_map(term) do
    term
    |> Map.to_list()
    |> Enum.find_value(fn {k, v} -> offending(k) || offending(v) end)
  end

  defp offending(_term), do: nil

  defp from_binary(binary, opts) do
    {:ok, :erlang.binary_to_term(binary, opts)}
  rescue
    ArgumentError -> {:error, :undecodable}
  end

  # An error reason from a crashing action may carry non-serializable terms
  # (e.g. a stacktrace with funs); reduce it to a printable form.
  defp safe_reason(reason) do
    case ensure_serializable(reason) do
      :ok -> reason
      {:error, _} -> inspect(reason)
    end
  end
end
