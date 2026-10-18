defmodule TinyCI.Execution.Backend do
  @moduledoc """
  Behaviour for *where a process runs*.

  A backend spawns processes and reports output lines to its `on_line` callback.
  It never writes to stdout, never renders or prefixes output, and never redacts:
  rendering belongs to the event sinks and masking to the run's dispatcher (see
  `TinyCI.Execution` and `docs/execution-model.md`).

  The contract is session-shaped so the container backend can share state across
  the steps of a stage without changing callers. `open/1` returns an opaque
  session; `exec/3` runs one command in it; `close/1` is idempotent and is always
  called from an `after` path.

  `exec/3` owns the deadline. On `:timeout` the backend must already have killed
  the command's whole process tree (Local: the shell's descendants; Container: the
  process group inside the container).
  """

  alias TinyCI.Execution.{Command, SessionSpec}

  @typedoc "An opaque, backend-owned session reference."
  @type session :: term()

  @typedoc "The command's status and captured output (partial on timeout)."
  @type outcome :: {:passed | :failed | :timeout, String.t()}

  @callback name() :: atom()
  @callback available?() :: boolean()
  @callback open(SessionSpec.t()) :: {:ok, session} | {:error, term()}
  @callback exec(session, Command.t(), (String.t() -> any())) :: outcome
  @callback close(session) :: :ok
end
