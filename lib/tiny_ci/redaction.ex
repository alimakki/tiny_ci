defmodule TinyCI.Redaction do
  @moduledoc """
  Masks secret values in any term before it reaches a console, a sink, or a result.

  This is the single masking function in tiny_ci. Three choke points call it:
  `TinyCI.Output` (each printed line and the returned output), the executor
  (a `StepResult.output` before it is built), and `TinyCI.Events.Dispatcher`
  (every event, once, before any sink). `TinyCI.Control.Session` and the sandbox
  driver use it too, so a breakpoint payload or a sandboxed action's result
  cannot leak a granted secret.

  Redaction walks arbitrary terms — strings, lists, tuples, maps, and structs —
  and rewrites only string occurrences; the shape of the data is preserved.

  ## Limitations

    * Values shorter than 4 bytes are ignored: masking a 1–3 byte "secret" would
      rewrite ordinary text.
    * Only literal occurrences are masked. A secret that appears transformed
      (base64, URL-encoded, split across lines) is not recognised.
  """

  @marker "***"
  @min_bytes 4

  @doc """
  Replaces every occurrence of each secret value in `term` with `"#{@marker}"`.

  Empty, `nil`, non-string, and shorter-than-#{@min_bytes}-byte secrets are ignored.
  Non-string data is traversed so secrets hiding inside nested maps, lists,
  tuples, or structs are still masked; struct types survive the walk.

  ## Examples

      iex> TinyCI.Redaction.redact("token=abcd1234", ["abcd1234"])
      "token=***"

      iex> TinyCI.Redaction.redact(%{out: ["abcd1234", 1]}, ["abcd1234"])
      %{out: ["***", 1]}

      iex> TinyCI.Redaction.redact("a ab abc", ["a", "ab", "abc"])
      "a ab abc"
  """
  @spec redact(term(), [String.t()]) :: term()
  def redact(term, secrets) when is_list(secrets) do
    case Enum.filter(secrets, &maskable?/1) do
      [] -> term
      values -> walk(term, values)
    end
  end

  defp walk(term, values) when is_binary(term), do: mask(term, values)
  defp walk(term, values) when is_list(term), do: Enum.map(term, &walk(&1, values))

  defp walk(term, values) when is_tuple(term) do
    term |> Tuple.to_list() |> walk(values) |> List.to_tuple()
  end

  # A struct keeps its `__struct__` tag; only its field values are walked.
  defp walk(%{__struct__: mod} = term, values) do
    term
    |> Map.from_struct()
    |> Map.new(fn {k, v} -> {k, walk(v, values)} end)
    |> Map.put(:__struct__, mod)
  end

  defp walk(term, values) when is_map(term) do
    Map.new(term, fn {k, v} -> {walk(k, values), walk(v, values)} end)
  end

  defp walk(term, _values), do: term

  defp mask(string, values) do
    Enum.reduce(values, string, fn secret, acc ->
      String.replace(acc, secret, @marker)
    end)
  end

  defp maskable?(value) when is_binary(value), do: byte_size(value) >= @min_bytes
  defp maskable?(_), do: false
end
