defmodule TinyCI.Action.Metadata do
  @moduledoc """
  Declarative metadata describing a `TinyCI.Action`.

  An action may optionally implement `c:TinyCI.Action.metadata/0` to advertise
  its identity, inputs, and the capabilities it needs. This information powers
  the action marketplace, lockfile resolution, and — from T8 onward — sandbox
  policy enforcement.

  ## Fields

    * `:name`         — human/marketplace identifier (e.g. `"my_app.deploy"`)
    * `:version`      — semantic version string (e.g. `"1.2.0"`)
    * `:inputs`       — list of input descriptors, each a map with `:name`,
      `:type`, and `:required` keys (see `input/3`)
    * `:capabilities` — list of capability atoms the action requires (see
      `known_capabilities/0`)

  ## Capabilities

  Capabilities are **declared** here and treated as advisory until T8, where
  they become the basis for sandbox enforcement. Declaring them now keeps the
  contract stable and avoids a breaking change later.

  ## Examples

      iex> alias TinyCI.Action.Metadata
      iex> Metadata.new(name: "deploy", version: "1.0.0", capabilities: [:network])
      %TinyCI.Action.Metadata{
        name: "deploy",
        version: "1.0.0",
        inputs: [],
        capabilities: [:network]
      }
  """

  @type capability ::
          :network
          | :filesystem_read
          | :filesystem_write
          | :env_read
          | :env_write
          | :process_spawn

  @type input :: %{name: atom(), type: atom(), required: boolean()}

  @type t :: %__MODULE__{
          name: String.t() | nil,
          version: String.t() | nil,
          inputs: [input()],
          capabilities: [capability()]
        }

  defstruct name: nil, version: nil, inputs: [], capabilities: []

  @known_capabilities [
    :network,
    :filesystem_read,
    :filesystem_write,
    :env_read,
    :env_write,
    :process_spawn
  ]

  @doc """
  Returns the list of recognized capability atoms.

  ## Examples

      iex> :network in TinyCI.Action.Metadata.known_capabilities()
      true
  """
  @spec known_capabilities() :: [capability()]
  def known_capabilities, do: @known_capabilities

  @doc """
  Builds a `%TinyCI.Action.Metadata{}` from a keyword list or map.

  Declared `:capabilities` are validated against `known_capabilities/0`;
  any unknown capability raises an `ArgumentError` so typos surface at the
  point of declaration rather than silently disabling sandbox policy later.

  ## Examples

      iex> TinyCI.Action.Metadata.new(name: "x", version: "0.1.0").name
      "x"
  """
  @spec new(keyword() | map()) :: t()
  def new(attrs) do
    attrs = Map.new(attrs)
    capabilities = Map.get(attrs, :capabilities, [])
    validate_capabilities!(capabilities)

    %__MODULE__{
      name: Map.get(attrs, :name),
      version: Map.get(attrs, :version),
      inputs: Map.get(attrs, :inputs, []),
      capabilities: capabilities
    }
  end

  @doc """
  Builds an input descriptor.

  ## Examples

      iex> TinyCI.Action.Metadata.input(:app, :string, true)
      %{name: :app, type: :string, required: true}
  """
  @spec input(atom(), atom(), boolean()) :: input()
  def input(name, type, required \\ false)
      when is_atom(name) and is_atom(type) and is_boolean(required) do
    %{name: name, type: type, required: required}
  end

  defp validate_capabilities!(capabilities) do
    case Enum.reject(capabilities, &(&1 in @known_capabilities)) do
      [] ->
        :ok

      unknown ->
        raise ArgumentError,
              "unknown capabilities: #{inspect(unknown)}. " <>
                "Known capabilities: #{inspect(@known_capabilities)}"
    end
  end
end
