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

  Both modes return `{status, output}` where `status` is `:passed` or
  `:failed` and `output` is the full captured output string. Streaming mode
  prints output to stdout as a side-effect *and* returns it.
  """

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

  ## Returns

    * `{:passed, output}` — command exited with status 0
    * `{:failed, output}` — command exited with non-zero status
  """
  @spec run_cmd(String.t(), keyword()) :: {:passed | :failed, String.t()}
  def run_cmd(cmd, opts \\ []) do
    output_mode = resolve_mode(opts[:mode] || :auto)
    env = opts[:env] || %{}
    prefix = opts[:prefix]
    working_dir = opts[:working_dir]

    case output_mode do
      :streaming -> run_streaming(cmd, env, prefix, working_dir)
      :buffered -> run_buffered(cmd, env, working_dir)
    end
  end

  defp run_buffered(cmd, env, working_dir) do
    cmd_opts = [stderr_to_stdout: true, env: string_env(env)]
    cmd_opts = if working_dir, do: [{:cd, working_dir} | cmd_opts], else: cmd_opts
    {output, exit_code} = System.cmd("sh", ["-c", cmd], cmd_opts)
    status = if exit_code == 0, do: :passed, else: :failed
    {status, output}
  end

  defp run_streaming(cmd, env, prefix, working_dir) do
    sh = System.find_executable("sh") || "/bin/sh"
    port_opts = [:stderr_to_stdout, :binary, :exit_status, {:env, charlist_env(env)}]

    port_opts =
      if working_dir, do: [{:cd, String.to_charlist(working_dir)} | port_opts], else: port_opts

    port = Port.open({:spawn_executable, sh}, [{:args, [~c"-c", cmd]} | port_opts])
    {status, chunks} = collect_port(port, prefix, [], "")
    {status, IO.iodata_to_binary(chunks)}
  end

  defp collect_port(port, prefix, chunks, line_buf) do
    receive do
      {^port, {:data, data}} ->
        {lines, remaining} = split_lines(line_buf <> data)
        print_lines(lines, prefix)
        collect_port(port, prefix, [chunks, data], remaining)

      {^port, {:exit_status, exit_code}} ->
        flush_line(line_buf, prefix)
        status = if exit_code == 0, do: :passed, else: :failed
        {status, chunks}
    end
  end

  defp flush_line("", _prefix), do: :ok
  defp flush_line(line, prefix), do: print_lines([line], prefix)

  defp split_lines(text) do
    parts = String.split(text, "\n", parts: :infinity)
    {complete, [remaining]} = Enum.split(parts, -1)
    {complete, remaining}
  end

  defp print_lines([], _prefix), do: :ok

  defp print_lines(lines, nil) do
    Enum.each(lines, &IO.puts/1)
  end

  defp print_lines(lines, prefix) do
    Enum.each(lines, fn line ->
      IO.puts("  [#{prefix}] #{line}")
    end)
  end

  defp string_env(env) do
    Enum.map(env, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  defp charlist_env(env) do
    Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
  end
end
