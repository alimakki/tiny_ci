defmodule TinyCI.Executor.Driver.Inline do
  @moduledoc """
  Runs an action directly in the runner's BEAM.

  This is the original execution path and the fast one, but it provides **no
  isolation**: the action runs with the runner's full authority. It therefore
  refuses any module classified as third-party by `TinyCI.Sandbox.Trust`,
  returning `{:error, {:untrusted_action, module}}` — untrusted code must go
  through `TinyCI.Executor.Driver.Sandbox`, never inline.
  """

  @behaviour TinyCI.Executor.Driver

  alias TinyCI.Sandbox.Trust

  @impl TinyCI.Executor.Driver
  def run(module, config, context, opts) do
    if Trust.trusted?(module, opts) do
      invoke(module, config, context)
    else
      {:error, {:untrusted_action, module}}
    end
  end

  defp invoke(module, config, context) do
    case apply(module, :execute, [config, context]) do
      :ok -> {:ok, %{}}
      {:ok, data} when is_map(data) -> {:ok, data}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  end
end
