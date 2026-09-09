defmodule TinyCI.Executor.Callback do
  @moduledoc """
  Captures ordinary callback IO and bounds execution when a timeout is supplied.

  The caller owns redaction and reporting. This is not an OS sandbox: direct
  writes to named devices, Logger handlers, and independently spawned processes
  are outside the callback's group-leader IO channel.
  """

  alias TinyCI.Executor.Crash

  @doc """
  Returns `{outcome, captured_output}` for a callback. Crashes become
  `{:error, {:crashed, text}}`; a deadline becomes `{:error, :timeout}`.

  Without a deadline, the callback stays in the calling process. With a deadline,
  it runs in an unlinked supervised task that is terminated before returning.
  """
  @spec run((-> term()), pos_integer() | nil) :: {term(), String.t()}
  def run(fun, timeout \\ nil) do
    {:ok, device} = StringIO.open("")

    try do
      outcome = invoke_with_timeout(fn -> capture(fun, device) end, timeout)
      {_input, output} = StringIO.contents(device)
      {outcome, output}
    after
      StringIO.close(device)
    end
  end

  defp invoke_with_timeout(fun, nil), do: fun.()

  defp invoke_with_timeout(fun, timeout) do
    task = Task.Supervisor.async_nolink(TinyCI.TaskSupervisor, fun)

    case Task.yield(task, timeout) do
      {:ok, outcome} ->
        outcome

      {:exit, reason} ->
        {:error, {:crashed, Crash.format(:exit, reason, [])}}

      nil ->
        Task.shutdown(task, :brutal_kill)
        {:error, :timeout}
    end
  end

  defp capture(fun, device) do
    previous = Process.group_leader()
    Process.group_leader(self(), device)

    try do
      fun.()
    rescue
      error -> {:error, {:crashed, Crash.format(:error, error, __STACKTRACE__)}}
    catch
      kind, reason -> {:error, {:crashed, Crash.format(kind, reason, __STACKTRACE__)}}
    after
      Process.group_leader(self(), previous)
    end
  end
end
