defmodule TinyCI.DSL.Value do
  @moduledoc """
  Keeps action and hook configuration inert while allowing runtime store reads.

  The interpreter normalizes literal AST without evaluating Elixir code. Store
  reads become `%TinyCI.DSL.Value.StoreRef{}` values, distinct from literal tuples.
  Call `resolve/2` with the current store immediately before invoking an action
  or hook, not while loading its pipeline.
  """

  defmodule StoreRef do
    @moduledoc "A required store read in normalized DSL configuration."
    @enforce_keys [:key]
    defstruct [:key]
  end

  @doc false
  @spec normalize(Macro.t()) :: {:ok, term()} | {:error, Macro.t()}
  def normalize(value) when is_atom(value) or is_binary(value) or is_number(value),
    do: {:ok, value}

  def normalize({:store, _, [key]}) when is_atom(key), do: {:ok, %StoreRef{key: key}}
  def normalize({:-, _, [value]}) when is_number(value), do: {:ok, -value}
  def normalize({:+, _, [value]}) when is_number(value), do: {:ok, value}

  def normalize({:__aliases__, _, parts} = node) do
    if Enum.all?(parts, &is_atom/1), do: {:ok, Module.concat(parts)}, else: {:error, node}
  end

  def normalize({:%{}, _, pairs} = node) do
    if Enum.all?(pairs, &match?({_, _}, &1)) do
      with {:ok, pairs} <- normalize(pairs), do: {:ok, Map.new(pairs)}
    else
      {:error, node}
    end
  end

  def normalize({:{}, _, items}) do
    with {:ok, items} <- normalize(items), do: {:ok, List.to_tuple(items)}
  end

  def normalize({left, right}) do
    with {:ok, left} <- normalize(left),
         {:ok, right} <- normalize(right) do
      {:ok, {left, right}}
    end
  end

  def normalize(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case normalize(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  def normalize(node), do: {:error, node}

  @doc """
  Resolves normalized store references inside maps (keys and values), lists and
  tuples. Other values, including values fetched from the store, remain data.

  Raises `ArgumentError` for a missing required key without printing the store.
  A present `nil` or `false` is a valid value, not a missing key.

  ## Examples

      iex> ref = %TinyCI.DSL.Value.StoreRef{key: :release}
      iex> TinyCI.DSL.Value.resolve([options: %{source: ref}], %{release: "build.tar"})
      [options: %{source: "build.tar"}]

      iex> TinyCI.DSL.Value.resolve({:store, :literal}, %{})
      {:store, :literal}
  """
  @spec resolve(term(), map()) :: term()
  def resolve(%StoreRef{key: key}, store) do
    case Map.fetch(store, key) do
      {:ok, value} -> value
      :error -> raise ArgumentError, "Required store key #{inspect(key)} is not available"
    end
  end

  def resolve(value, store) when is_map(value) do
    Map.new(Map.to_list(value), fn {key, item} -> {resolve(key, store), resolve(item, store)} end)
  end

  def resolve(value, store) when is_list(value), do: Enum.map(value, &resolve(&1, store))

  def resolve(value, store) when is_tuple(value) do
    value |> Tuple.to_list() |> Enum.map(&resolve(&1, store)) |> List.to_tuple()
  end

  def resolve(value, _store), do: value
end
