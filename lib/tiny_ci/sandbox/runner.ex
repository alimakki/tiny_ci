defmodule TinyCI.Sandbox.Runner do
  @moduledoc """
  The in-sandbox entrypoint: the code that runs *inside* the confined OS process.

  A sandbox backend starts a fresh BEAM (under `sandbox-exec`, a container, …)
  whose sole job is to run one action. `cli/0` reads the serialized request from
  the path in `TINY_CI_SANDBOX_REQUEST`, loads and invokes the action, and writes
  the serialized response to `TINY_CI_SANDBOX_RESPONSE`. Nothing crosses the
  boundary except the bytes in those files (see `TinyCI.Sandbox.Protocol`).

  The action's result is normalized to the driver contract, and any crash is
  caught and returned as an error rather than taking the process down — the
  runner must always produce a response file for the parent to read.
  """

  alias TinyCI.Context
  alias TinyCI.Sandbox.Protocol

  @request_env "TINY_CI_SANDBOX_REQUEST"
  @response_env "TINY_CI_SANDBOX_RESPONSE"

  @context_keys [:branch, :commit, :changed_files, :store, :timestamp]

  @doc "Reads the request/response paths from the environment and runs the action."
  @spec cli() :: :ok
  def cli do
    run(System.get_env(@request_env), System.get_env(@response_env))
  end

  @doc "Runs the request at `request_path`, writing the response to `response_path`."
  @spec run(String.t() | nil, String.t() | nil) :: :ok
  def run(request_path, response_path)
      when is_binary(request_path) and is_binary(response_path) do
    outcome =
      with {:ok, binary} <- File.read(request_path),
           {:ok, request} <- Protocol.decode_request(binary) do
        execute(request)
      end

    {:ok, encoded} = Protocol.encode_response(normalize(outcome))
    File.write!(response_path, encoded)
    :ok
  end

  defp execute(%{module: module, config: config, context: context}) do
    Code.ensure_loaded(module)
    apply(module, :execute, [config, rebuild_context(context)])
  rescue
    exception -> {:error, {:crashed, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, inspect(reason)}}
  end

  defp rebuild_context(map) when is_map(map) do
    Context
    |> struct(Map.take(map, @context_keys))
    |> Map.merge(Map.take(map, [:env]))
  end

  defp normalize(:ok), do: {:ok, %{}}
  defp normalize({:ok, data}) when is_map(data), do: {:ok, data}
  defp normalize({:error, reason}), do: {:error, reason}
  defp normalize(other), do: {:error, {:bad_return, other}}
end
