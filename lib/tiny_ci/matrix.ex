defmodule TinyCI.Matrix do
  @moduledoc """
  Computes cartesian-product combinations from a matrix spec and provides
  helpers for labelling and environment variable injection.

  A matrix spec is a keyword list mapping variable names to lists of values:

      [elixir: ["1.17", "1.18"], otp: ["26", "27"]]

  `combinations/1` returns every combination as a keyword list:

      [
        [elixir: "1.17", otp: "26"],
        [elixir: "1.17", otp: "27"],
        [elixir: "1.18", otp: "26"],
        [elixir: "1.18", otp: "27"]
      ]
  """

  @doc """
  Computes the cartesian product of all values in the matrix spec.

  Returns a list of keyword lists, each representing one combination.
  Order is deterministic (iterates the first key's values outermost).
  """
  @spec combinations(keyword([String.t()])) :: [keyword(String.t())]
  def combinations([]), do: [[]]

  def combinations([{key, values} | rest]) do
    for value <- values, combo <- combinations(rest) do
      [{key, value} | combo]
    end
  end

  @doc """
  Converts a combination keyword list to a map of uppercased environment
  variable names to their string values.

      iex> TinyCI.Matrix.env_vars([elixir: "1.17", otp: "26"])
      %{"ELIXIR" => "1.17", "OTP" => "26"}
  """
  @spec env_vars(keyword(String.t())) :: %{String.t() => String.t()}
  def env_vars(combination) do
    Map.new(combination, fn {k, v} -> {k |> Atom.to_string() |> String.upcase(), v} end)
  end

  @doc """
  Formats a combination as a human-readable label.

      iex> TinyCI.Matrix.label([elixir: "1.17", otp: "26"])
      "elixir=1.17, otp=26"
  """
  @spec label(keyword(String.t())) :: String.t()
  def label(combination) do
    Enum.map_join(combination, ", ", fn {k, v} -> "#{k}=#{v}" end)
  end
end
