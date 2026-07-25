defmodule TinyCI.Sandbox.Redaction do
  @moduledoc """
  Masks secret values in data leaving the sandbox boundary.

  A sandboxed action may be granted a secret (an API token, a deploy key) and
  then echo it — deliberately or by accident — into its output, an error reason,
  or a store value. Before any of that reaches the event stream (T1) or the
  console, known secret values are replaced with a fixed marker so they are not
  logged or persisted.

  Redaction walks arbitrary terms and rewrites only the string occurrences; the
  shape of the data is preserved.
  """

  @marker "***"

  @doc """
  Replaces every occurrence of each secret value in `term` with `"#{@marker}"`.

  Empty and `nil` secrets are ignored. Non-string data is traversed so secrets
  hiding inside nested maps, lists, or tuples are still masked.
  """
  @spec redact(term(), [String.t()]) :: term()
  def redact(term, secrets) when is_list(secrets) do
    case Enum.reject(secrets, &blank?/1) do
      [] -> term
      values -> walk(term, values)
    end
  end

  defp walk(term, values) when is_binary(term), do: mask(term, values)
  defp walk(term, values) when is_list(term), do: Enum.map(term, &walk(&1, values))

  defp walk(term, values) when is_tuple(term) do
    term |> Tuple.to_list() |> walk(values) |> List.to_tuple()
  end

  defp walk(term, values) when is_map(term) and not is_struct(term) do
    Map.new(term, fn {k, v} -> {walk(k, values), walk(v, values)} end)
  end

  defp walk(term, _values), do: term

  defp mask(string, values) do
    Enum.reduce(values, string, fn secret, acc ->
      String.replace(acc, secret, @marker)
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(value) when is_binary(value), do: false
  defp blank?(_), do: true
end
