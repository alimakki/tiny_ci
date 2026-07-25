defmodule TinyCI.Executor.Driver.Sandbox do
  @moduledoc """
  Runs an action inside an OS sandbox with only its declared capabilities.

  It derives a `TinyCI.Sandbox.Policy` from the action's
  `TinyCI.Action.Metadata`, serializes a request (config + a sanitized context)
  with `TinyCI.Sandbox.Protocol`, hands it to a `TinyCI.Sandbox.Backend`
  (Seatbelt by default), and decodes the response — masking any granted secrets
  on the way out (`TinyCI.Sandbox.Redaction`).

  Only the documented action-facing context fields cross the boundary; executor
  handles (`:events`, `:run_id`, …) never leave the runner. If no backend is
  available the driver **fails closed** rather than falling back to inline.
  """

  @behaviour TinyCI.Executor.Driver

  alias TinyCI.Action
  alias TinyCI.Sandbox.{Policy, Protocol, Redaction}
  alias TinyCI.Sandbox.Backend.Seatbelt

  @context_keys [:branch, :commit, :changed_files, :store, :timestamp]

  @impl TinyCI.Executor.Driver
  def run(module, config, context, opts) do
    backend = Keyword.get(opts, :backend, Seatbelt)

    if backend.available?() do
      confine(backend, module, config, context, opts)
    else
      {:error, {:sandbox_unavailable, backend}}
    end
  end

  defp confine(backend, module, config, context, opts) do
    policy = Policy.from_metadata(Action.metadata(module), Keyword.get(opts, :grants, []))
    secrets = Keyword.get(opts, :secrets, [])

    request = %{
      module: module,
      config: config,
      context: sanitize(context, policy),
      policy: policy
    }

    with {:ok, encoded} <- Protocol.encode_request(request),
         {:ok, response} <- backend.run(encoded, policy, opts),
         {:ok, delta} <- Protocol.decode_response(response) do
      {:ok, Redaction.redact(delta, secrets)}
    else
      {:error, reason} -> {:error, Redaction.redact(reason, secrets)}
    end
  end

  # Only the action-facing context surface crosses the boundary, and the env map
  # is filtered to the vars the policy grants.
  defp sanitize(context, policy) do
    context
    |> Map.take(@context_keys)
    |> Map.put(:env, granted_env(context, policy))
  end

  defp granted_env(context, policy) do
    allowed = MapSet.new(policy.env)

    context
    |> Map.get(:env, %{})
    |> Enum.filter(fn {key, _value} -> to_string(key) in allowed end)
    |> Map.new()
  end
end
