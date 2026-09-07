defmodule TinyCI.Executor.Driver.Inline do
  @moduledoc """
  Runs an action directly in the runner's BEAM.

  This is the original execution path and the fast one, but it provides **no
  isolation**: the action runs with the runner's full authority. It therefore
  refuses any module classified as third-party by `TinyCI.Sandbox.Trust`,
  returning `{:error, {:untrusted_action, module}}` — untrusted code must go
  through `TinyCI.Executor.Driver.Sandbox`, never inline.

  A raise, exit, or throw inside the action is caught and returned as
  `{:error, {:crashed, text}}`, where `text` is the formatted exception and stack
  trace (see `TinyCI.Executor.Crash`). The executor records it as a failed step.
  """

  @behaviour TinyCI.Executor.Driver

  alias TinyCI.Executor.Crash
  alias TinyCI.Sandbox.Trust

  @impl TinyCI.Executor.Driver
  def run(module, config, context, opts) do
    if Trust.trusted?(module, opts) do
      invoke(module, config, context)
    else
      {:error, {:untrusted_action, module}}
    end
  end

  # A crash inside `execute/2` is the action's failure, not the runner's: it is
  # caught here and reported as `{:error, {:crashed, text}}` so the executor
  # records a failed step and the run carries on.
  defp invoke(module, config, context) do
    case apply(module, :execute, [config, context]) do
      :ok -> {:ok, %{}}
      {:ok, data} when is_map(data) -> {:ok, data}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:bad_return, other}}
    end
  rescue
    e -> {:error, {:crashed, Crash.format(:error, e, __STACKTRACE__)}}
  catch
    kind, reason -> {:error, {:crashed, Crash.format(kind, reason, __STACKTRACE__)}}
  end
end
