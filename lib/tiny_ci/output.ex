defmodule TinyCI.Output do
  @moduledoc """
  Manages output strategy for pipeline step execution.

  Supports two modes:

    * `:streaming` — prints output line-by-line as it arrives using a
      `Port` directly backed by the OS process. Ideal for TTY environments
      where real-time feedback is expected.

    * `:buffered` — captures the full output and returns it after the command
      finishes using `System.cmd/3`. Used in non-TTY environments or when
      output interleaving must be prevented.

  In streaming mode an optional prefix can be provided. When set, each printed
  line is prefixed with `  [prefix] ` to disambiguate output from concurrent
  steps in parallel execution.

  Both modes return `{status, output}` where `status` is `:passed`, `:failed`,
  or `:timeout` and `output` is the captured output string (partial on timeout).
  Streaming mode prints output to stdout as a side-effect *and* returns it.

  ## Timeouts and process cleanup

  Both modes run the command through an OS `Port` so the underlying process is
  addressable. When a `:timeout` is given and elapses, the command's entire
  process subtree (the shell and every descendant it spawned) is killed — first
  with `SIGTERM`, then `SIGKILL` after a short grace period — so a timed-out
  step never leaves orphaned processes chewing CPU in the background. Descendants
  are enumerated via `ps` rather than a process-group kill so the same code works
  on both Linux and macOS (which has no `setsid`).
  """

  # Grace period between SIGTERM and SIGKILL when reaping a timed-out subtree.
  @kill_grace_ms 100

  @doc """
  Returns the output mode for the current environment.

  Returns `:streaming` when the terminal supports ANSI escape codes
  (typically a TTY), `:buffered` otherwise.
  """
  @spec mode() :: :streaming | :buffered
  def mode do
    if IO.ANSI.enabled?(), do: :streaming, else: :buffered
  end

  @doc """
  Resolves an output mode option to a concrete mode.

  `:auto` delegates to `mode/0`. Explicit `:streaming` or `:buffered`
  values pass through unchanged.
  """
  @spec resolve_mode(:auto | :streaming | :buffered) :: :streaming | :buffered
  def resolve_mode(:auto), do: mode()
  def resolve_mode(:streaming), do: :streaming
  def resolve_mode(:buffered), do: :buffered

  @doc """
  Runs a shell command and returns `{status, output}`.

  In streaming mode, output is printed line-by-line to stdout as it arrives.
  In buffered mode, output is captured silently. Both modes return the full
  output string.

  ## Options

    * `:mode` — `:streaming`, `:buffered`, or `:auto` (default `:auto`)
    * `:prefix` — string to prepend to each output line (streaming only)
    * `:env` — map of environment variables for the command
    * `:working_dir` — directory to run the command in
    * `:timeout` — milliseconds after which the command's process subtree is
      killed (default: no timeout)

  ## Returns

    * `{:passed, output}` — command exited with status 0
    * `{:failed, output}` — command exited with non-zero status
    * `{:timeout, output}` — command was killed after exceeding `:timeout`;
      `output` is whatever was captured before the kill
  """
  @spec run_cmd(String.t(), keyword()) :: {:passed | :failed | :timeout, String.t()}
  def run_cmd(cmd, opts \\ []) do
    output_mode = resolve_mode(opts[:mode] || :auto)
    env = opts[:env] || %{}
    prefix = if output_mode == :streaming, do: opts[:prefix], else: :buffered
    working_dir = opts[:working_dir]
    timeout = opts[:timeout]

    run_port(cmd, env, working_dir, prefix, timeout)
  end

  # `prefix` is a string/nil for streaming, or the `:buffered` atom to suppress printing.
  defp run_port(cmd, env, working_dir, prefix, timeout) do
    sh = System.find_executable("sh") || "/bin/sh"
    port_opts = [:stderr_to_stdout, :binary, :exit_status, {:env, charlist_env(env)}]

    port_opts =
      if working_dir, do: [{:cd, String.to_charlist(working_dir)} | port_opts], else: port_opts

    port = Port.open({:spawn_executable, sh}, [{:args, [~c"-c", cmd]} | port_opts])
    os_pid = port_os_pid(port)
    deadline = if timeout, do: System.monotonic_time(:millisecond) + timeout, else: nil
    {status, chunks} = collect_port(port, os_pid, deadline, prefix, [], "")
    {status, IO.iodata_to_binary(chunks)}
  end

  defp collect_port(port, os_pid, deadline, prefix, chunks, line_buf) do
    receive do
      {^port, {:data, data}} ->
        {lines, remaining} = split_lines(line_buf <> data)
        print_lines(lines, prefix)
        collect_port(port, os_pid, deadline, prefix, [chunks, data], remaining)

      {^port, {:exit_status, exit_code}} ->
        flush_line(line_buf, prefix)
        status = if exit_code == 0, do: :passed, else: :failed
        {status, chunks}
    after
      remaining_ms(deadline) ->
        kill_subtree(os_pid)
        close_port(port)
        flush_line(line_buf, prefix)
        {:timeout, chunks}
    end
  end

  defp remaining_ms(nil), do: :infinity
  defp remaining_ms(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)

  defp port_os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp close_port(port) do
    if Port.info(port), do: Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  # Kills the process rooted at `os_pid` and every descendant it spawned.
  # Descendants are enumerated *before* any signal is sent, since killing the
  # parent reparents survivors and would otherwise lose them.
  defp kill_subtree(nil), do: :ok

  defp kill_subtree(os_pid) do
    pids = [os_pid | descendants(os_pid)]
    signal(pids, "TERM")
    Process.sleep(@kill_grace_ms)
    signal(pids, "KILL")
    :ok
  end

  defp descendants(os_pid) do
    case System.cmd("ps", ["-ax", "-o", "pid=,ppid="], stderr_to_stdout: true) do
      {out, 0} -> collect_descendants([os_pid], parse_ps(out), [])
      _ -> []
    end
  end

  defp parse_ps(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case line |> String.split() |> Enum.map(&Integer.parse/1) do
        [{child, ""}, {parent, ""}] -> [{child, parent}]
        _ -> []
      end
    end)
  end

  defp collect_descendants([], _pairs, acc), do: acc

  defp collect_descendants([pid | rest], pairs, acc) do
    children = for {child, parent} <- pairs, parent == pid, child not in acc, do: child
    collect_descendants(rest ++ children, pairs, acc ++ children)
  end

  defp signal(pids, sig) do
    args = ["-#{sig}" | Enum.map(pids, &Integer.to_string/1)]
    # Already-dead pids make `kill` complain; that is expected and ignored.
    System.cmd("kill", args, stderr_to_stdout: true)
    :ok
  end

  defp flush_line("", _prefix), do: :ok
  defp flush_line(line, prefix), do: print_lines([line], prefix)

  defp split_lines(text) do
    parts = String.split(text, "\n", parts: :infinity)
    {complete, [remaining]} = Enum.split(parts, -1)
    {complete, remaining}
  end

  defp print_lines([], _prefix), do: :ok

  defp print_lines(_lines, :buffered), do: :ok

  defp print_lines(lines, nil) do
    Enum.each(lines, &IO.puts/1)
  end

  defp print_lines(lines, prefix) do
    Enum.each(lines, fn line ->
      IO.puts("  [#{prefix}] #{line}")
    end)
  end

  defp charlist_env(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end
end
