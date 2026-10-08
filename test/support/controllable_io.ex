defmodule TinyCI.ControllableIO do
  @moduledoc """
  An IO device a test drives by hand, for code that reads lines from an IO device.

  `StringIO` answers a read the moment it is asked, which makes the interleaving of
  several readers and writers a race. This device does not answer `get_line` until
  the test sends the line, and tells the test when a reader is waiting:

    * `{:reading, prompt}` is sent to the owner when a process blocks in `IO.gets/2`
    * `{:wrote, chunk}` is sent to the owner for everything written
    * `send_line/2` answers the pending (or the next) read
    * `output/1` is everything written so far

  So a test can wait for "the driver is provably blocked reading" before it causes the
  next event, instead of sleeping.
  """

  @doc "Starts a device that reports to `owner` (linked to the caller)."
  @spec start_link(pid()) :: {:ok, pid()}
  def start_link(owner), do: {:ok, spawn_link(fn -> loop(owner, [], nil, []) end)}

  @doc "Answers the pending `IO.gets/2`, or the next one, with `line` (include the newline)."
  @spec send_line(pid(), String.t()) :: :ok
  def send_line(io, line) do
    send(io, {:line, line})
    :ok
  end

  @doc "Everything written to the device so far."
  @spec output(pid()) :: String.t()
  def output(io) do
    ref = make_ref()
    send(io, {:output, self(), ref})

    receive do
      {^ref, output} -> output
    after
      5_000 -> raise "ControllableIO did not answer"
    end
  end

  # `reader` is the `{from, reply_as}` of a blocked get_line; `lines` are lines sent
  # before anyone asked for them.
  defp loop(owner, output, reader, lines) do
    receive do
      {:io_request, from, reply_as, request} ->
        handle_request(request, from, reply_as, owner, output, reader, lines)

      {:line, line} ->
        case reader do
          {from, reply_as} ->
            reply(from, reply_as, line)
            loop(owner, output, nil, lines)

          nil ->
            loop(owner, output, nil, lines ++ [line])
        end

      {:output, from, ref} ->
        send(from, {ref, output |> Enum.reverse() |> IO.iodata_to_binary()})
        loop(owner, output, reader, lines)
    end
  end

  defp handle_request({:put_chars, _enc, chars}, from, reply_as, owner, output, reader, lines),
    do: write(chars, from, reply_as, owner, output, reader, lines)

  defp handle_request({:put_chars, chars}, from, reply_as, owner, output, reader, lines),
    do: write(chars, from, reply_as, owner, output, reader, lines)

  defp handle_request({:put_chars, enc, m, f, a}, from, reply_as, owner, output, reader, lines),
    do:
      handle_request(
        {:put_chars, enc, apply(m, f, a)},
        from,
        reply_as,
        owner,
        output,
        reader,
        lines
      )

  defp handle_request({:get_line, _enc, prompt}, from, reply_as, owner, output, _reader, lines),
    do: read(prompt, from, reply_as, owner, output, lines)

  defp handle_request({:get_line, prompt}, from, reply_as, owner, output, _reader, lines),
    do: read(prompt, from, reply_as, owner, output, lines)

  defp handle_request(_unknown, from, reply_as, owner, output, reader, lines) do
    send(from, {:io_reply, reply_as, {:error, :request}})
    loop(owner, output, reader, lines)
  end

  defp write(chars, from, reply_as, owner, output, reader, lines) do
    chunk = IO.chardata_to_string(chars)
    send(owner, {:wrote, chunk})
    reply(from, reply_as, :ok)
    loop(owner, [chunk | output], reader, lines)
  end

  defp read(prompt, from, reply_as, owner, output, lines) do
    send(owner, {:reading, IO.chardata_to_string(prompt)})

    case lines do
      [line | rest] ->
        reply(from, reply_as, line)
        loop(owner, output, nil, rest)

      [] ->
        loop(owner, output, {from, reply_as}, [])
    end
  end

  defp reply(from, reply_as, value), do: send(from, {:io_reply, reply_as, value})
end
