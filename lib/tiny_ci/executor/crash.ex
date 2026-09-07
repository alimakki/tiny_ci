defmodule TinyCI.Executor.Crash do
  @moduledoc """
  Turns a caught crash (raise, exit, or throw) into the text a failed step carries.

  A crash inside user code is a *failed step*, never a crashed run. Every rescue
  boundary in the executor, the inline driver, and the hooks runner formats what
  it caught through this module so the author sees the same shape everywhere:
  the exception class, its message, and the stack trace that led there.
  """

  @doc """
  Formats a caught `kind`/`reason`/`stacktrace` triple as step output.

  `:error` reasons are normalized first, so an Erlang error term such as
  `:badarg` reads as the exception it represents. The stack trace is kept
  because it is the only clue the action's author gets.

  ## Examples

      iex> TinyCI.Executor.Crash.format(:error, %RuntimeError{message: "kaboom"}, [])
      "Step crashed: ** (RuntimeError) kaboom"

      iex> TinyCI.Executor.Crash.format(:throw, :ball, [])
      "Step crashed: ** (throw) :ball"

      iex> TinyCI.Executor.Crash.format(:exit, :shutdown, [])
      "Step crashed: ** (exit) shutdown"
  """
  @spec format(kind :: :error | :exit | :throw, reason :: term(), Exception.stacktrace()) ::
          String.t()
  def format(:error, reason, stacktrace) do
    exception = Exception.normalize(:error, reason, stacktrace)
    "Step crashed: " <> Exception.format(:error, exception, stacktrace)
  end

  def format(kind, reason, stacktrace) when kind in [:exit, :throw] do
    "Step crashed: " <> Exception.format(kind, reason, stacktrace)
  end
end
