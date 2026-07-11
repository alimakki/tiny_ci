defmodule TinyCI.Registry.Index do
  @moduledoc """
  A searchable collection of `TinyCI.Registry.Entry` structs — the in-memory
  form of the action registry.

  Pure: `new/1`, `search/3`, and `merge/2` do no I/O. `merge/2` layers a curated
  overlay (which assigns review tiers) onto a freshly-scanned base so live
  version/capability data stays authoritative while tiers come from review.
  `to_json/1` and `from_json/1` are the static-index boundary.
  """

  alias TinyCI.Registry.Entry

  @type t :: %__MODULE__{entries: [Entry.t()]}

  defstruct entries: []

  @doc "Builds an index from a list of entries, sorted by name."
  @spec new([Entry.t()]) :: t()
  def new(entries) when is_list(entries) do
    %__MODULE__{entries: Enum.sort_by(entries, &sort_key/1)}
  end

  @doc """
  Returns entries matching `term`, filtered by the given options.

  A `nil` or empty `term` matches everything; otherwise the term is matched
  case-insensitively against the entry's name, package, module, and summary.

  ## Options

    * `:capability` — keep only entries declaring this capability atom
    * `:tier`       — keep only entries at this review tier
  """
  @spec search(t(), String.t() | nil, keyword()) :: [Entry.t()]
  def search(%__MODULE__{entries: entries}, term, opts \\ []) do
    entries
    |> Enum.filter(&matches_term?(&1, normalize(term)))
    |> filter_capability(opts[:capability])
    |> filter_tier(opts[:tier])
  end

  @doc """
  Merges a curated `overlay` onto a scanned `base`.

  Entries are keyed by module. When both sides carry the same module, the base's
  live data is kept but the overlay's review tier (and summary, if the base lacks
  one) wins. Overlay-only entries — curated actions not installed locally — are
  included as-is.
  """
  @spec merge(t(), t()) :: t()
  def merge(%__MODULE__{entries: base}, %__MODULE__{entries: overlay}) do
    overlay_by_module = Map.new(overlay, &{&1.module, &1})
    base_modules = MapSet.new(base, & &1.module)

    merged_base = Enum.map(base, &apply_overlay(&1, overlay_by_module[&1.module]))
    overlay_only = Enum.reject(overlay, &MapSet.member?(base_modules, &1.module))

    new(merged_base ++ overlay_only)
  end

  @doc "Serializes the index to pretty JSON under a top-level `\"actions\"` key."
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{entries: entries}) do
    Jason.encode!(%{"actions" => Enum.map(entries, &Entry.to_map/1)}, pretty: true)
  end

  @doc "Parses a JSON index produced by `to_json/1`."
  @spec from_json(String.t()) :: {:ok, t()} | {:error, term()}
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, %{"actions" => actions}} when is_list(actions) ->
        {:ok, new(Enum.map(actions, &Entry.from_map/1))}

      {:ok, _other} ->
        {:error, :invalid_index}

      {:error, _} = error ->
        error
    end
  end

  # ---------------------------------------------------------------------------

  defp apply_overlay(entry, nil), do: entry

  defp apply_overlay(entry, overlay) do
    %{entry | tier: overlay.tier, summary: entry.summary || overlay.summary}
  end

  defp matches_term?(_entry, ""), do: true

  defp matches_term?(entry, term) do
    entry
    |> haystack()
    |> String.contains?(term)
  end

  defp haystack(entry) do
    [entry.name, entry.package, entry.module, entry.summary]
    |> Enum.map_join(" ", &field_text/1)
    |> String.downcase()
  end

  defp field_text(nil), do: ""
  defp field_text(value) when is_binary(value), do: value
  defp field_text(value) when is_atom(value), do: inspect(value)

  defp filter_capability(entries, nil), do: entries

  defp filter_capability(entries, capability) do
    Enum.filter(entries, &(capability in &1.capabilities))
  end

  defp filter_tier(entries, nil), do: entries
  defp filter_tier(entries, tier), do: Enum.filter(entries, &(&1.tier == tier))

  defp normalize(nil), do: ""
  defp normalize(term) when is_binary(term), do: String.downcase(String.trim(term))

  defp sort_key(%Entry{name: name, module: module}), do: name || inspect(module)
end
