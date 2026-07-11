defmodule TinyCI.Registry.Entry do
  @moduledoc """
  One indexed action: a self-identified `TinyCI.Action` module, the Hex package
  and version that ships it, its declared capabilities and inputs, and a review
  tier.

  Entries are produced by scanning locally-installed packages
  (`TinyCI.Registry.scan/1`) and serialized into the static JSON index. `to_map/1`
  and `from_map/1` are the JSON boundary; both are pure.
  """

  alias TinyCI.Action.Metadata

  @tiers [:verified, :community, :unreviewed]

  @type tier :: :verified | :community | :unreviewed

  @type t :: %__MODULE__{
          package: atom() | nil,
          version: String.t() | nil,
          module: module() | nil,
          name: String.t() | nil,
          summary: String.t() | nil,
          capabilities: [Metadata.capability()],
          inputs: [Metadata.input()],
          tier: tier()
        }

  defstruct package: nil,
            version: nil,
            module: nil,
            name: nil,
            summary: nil,
            capabilities: [],
            inputs: [],
            tier: :unreviewed

  @doc "The recognized review tiers, best-reviewed first."
  @spec tiers() :: [tier()]
  def tiers, do: @tiers

  @doc "Serializes an entry to a JSON-ready map with string keys."
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = entry) do
    %{
      "package" => nil_or(entry.package, &to_string/1),
      "version" => entry.version,
      "module" => nil_or(entry.module, &inspect/1),
      "name" => entry.name,
      "summary" => entry.summary,
      "capabilities" => Enum.map(entry.capabilities, &to_string/1),
      "inputs" => Enum.map(entry.inputs, &input_to_map/1),
      "tier" => to_string(entry.tier)
    }
  end

  @doc "Rebuilds an entry from a decoded JSON map (inverse of `to_map/1`)."
  @spec from_map(map()) :: t()
  def from_map(map) when is_map(map) do
    %__MODULE__{
      package: nil_or(map["package"], &String.to_atom/1),
      version: map["version"],
      module: nil_or(map["module"], &Module.concat([&1])),
      name: map["name"],
      summary: map["summary"],
      capabilities: map |> Map.get("capabilities", []) |> Enum.map(&String.to_atom/1),
      inputs: map |> Map.get("inputs", []) |> Enum.map(&input_from_map/1),
      tier: tier(map["tier"])
    }
  end

  defp tier(value) when is_binary(value) do
    Enum.find(@tiers, :unreviewed, &(to_string(&1) == value))
  end

  defp tier(_), do: :unreviewed

  defp input_to_map(%{name: name, type: type, required: required}) do
    %{"name" => to_string(name), "type" => to_string(type), "required" => required}
  end

  defp input_from_map(map) do
    %{
      name: String.to_atom(map["name"]),
      type: String.to_atom(map["type"]),
      required: Map.get(map, "required", false)
    }
  end

  defp nil_or(nil, _fun), do: nil
  defp nil_or(value, fun), do: fun.(value)
end
