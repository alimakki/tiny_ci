defmodule TinyCI.Output do
  @moduledoc """
  Manages output strategy for pipeline step execution.

  Supports two modes:

    * `:streaming` — prints output line-by-line as it arrives using
      `Porcelain.spawn_shell/2`. Ideal for TTY environments where real-time
      feedback is expected.

    * `:buffered` — captures the full output and returns it after the command
      finishes using `Porcelain.shell/2`. Used in non-TTY environments or when
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

  ## Returns

    * `{:passed, output}` — command exited with status 0
    * `{:failed, output}` — command exited with non-zero status
  """
  @spec run_cmd(String.t(), keyword()) :: {:passed | :failed, String.t()}
  def run_cmd(cmd, opts \\ []) do
    output_mode = resolve_mode(opts[:mode] || :auto)
    env = opts[:env] || %{}
    prefix = opts[:prefix]

    case output_mode do
      :streaming -> run_streaming(cmd, env, prefix)
      :buffered -> run_buffered(cmd, env)
    end
  end

  defp run_buffered(cmd, env) do
    case Porcelain.shell(cmd, env: env) do
      %Porcelain.Result{status: 0, out: out} -> {:passed, out}
      %Porcelain.Result{out: out} -> {:failed, out}
    end
  end

  defp run_streaming(cmd, env, prefix) do
    proc =
      Porcelain.spawn_shell(cmd, out: {:send, self()}, err: :out, result: :keep, env: env)

    {status, output} = receive_output(proc.pid, prefix, [], "")
    {status, IO.iodata_to_binary(output)}
  end

  defp receive_output(from_pid, prefix, acc, line_buf) do
    receive do
      {^from_pid, :data, :out, data} ->
        chunk = IO.iodata_to_binary(data)
        {complete_lines, remaining} = split_lines(line_buf <> chunk)
        print_lines(complete_lines, prefix)
        receive_output(from_pid, prefix, [acc, chunk], remaining)

      {^from_pid, :result, %Porcelain.Result{status: exit_status}} ->
        if line_buf != "", do: print_lines([line_buf], prefix)
        status = if exit_status == 0, do: :passed, else: :failed
        {status, [acc | if(line_buf != "", do: "", else: "")]}
    end
  end

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
end
