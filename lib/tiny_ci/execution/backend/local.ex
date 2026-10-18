defmodule TinyCI.Execution.Backend.Local do
  @moduledoc """
  The host execution backend.

  Every command runs as a direct child of the runner on the host, through
  `TinyCI.Output` (which reports lines and never prints). `open/1` and `close/1`
  are no-ops: a local session has no lifecycle beyond the process that runs it.

  This backend deliberately receives neither an output mode nor secret values.
  Streaming vs buffered is the console sink's concern and masking happens once in
  the run's dispatcher; passing `redact:` here would put policy inside the
  execution boundary (decision D4 in `M1.5-00`).

  The session carries `:run_id` even though nothing reads it yet. M1.5-04 uses it
  to register each OS pid with `TinyCI.OSProcesses` so a run can be cancelled.
  """

  @behaviour TinyCI.Execution.Backend

  alias TinyCI.Execution.{Command, SessionSpec}
  alias TinyCI.Output

  @impl true
  def name, do: :local

  @impl true
  def available?, do: true

  @impl true
  def open(%SessionSpec{run_id: run_id}), do: {:ok, %{run_id: run_id}}

  @impl true
  def exec(_session, %Command{run: {:shell, cmd}} = command, on_line) do
    Output.run_cmd(cmd, output_opts(command, on_line))
  end

  def exec(_session, %Command{run: {:argv, executable, args}} = command, on_line) do
    case Output.run_executable(executable, args, output_opts(command, on_line)) do
      {output, 0} -> {:passed, output}
      {output, :timeout} -> {:timeout, output}
      {output, _exit_status} -> {:failed, output}
    end
  end

  @impl true
  def close(_session), do: :ok

  defp output_opts(%Command{} = command, on_line) do
    [
      env: command.env,
      working_dir: command.working_dir,
      timeout: command.timeout,
      on_line: on_line
    ]
  end
end
