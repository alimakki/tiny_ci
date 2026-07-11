defmodule TinyCI.Registry do
  @moduledoc """
  A curated, discoverable index of `TinyCI.Action` packages — "small, curated,
  verifiable," the deliberate opposite of a vast unaudited marketplace.

  The registry is metadata *over* Hex packages (see `TinyCI.Action.Audit` for how
  `mix.lock` pins them). It is the I/O layer over `TinyCI.Registry.Index`.

  ## How a package self-identifies

  A package advertises the actions it ships by listing their modules in its
  application environment under the `:tiny_ci_actions` key. In the package's
  `mix.exs`:

      def application do
        [
          env: [
            tiny_ci_actions: [Acme.Deploy, Acme.Notify]
          ]
        ]
      end

  Because this lives in the compiled `.app` file, the index can be built
  programmatically by scanning installed dependencies — no network required and
  no separate manifest to keep in sync. Each listed module's identity, inputs,
  and capabilities come from its `c:TinyCI.Action.metadata/0`.

  ## Review tiers

  A scanned entry is `:unreviewed`. Curated review tiers (`:verified`,
  `:community`) are editorial and live in a checked-in overlay index that
  `TinyCI.Registry.Index.merge/2` layers on top of a scan — live version and
  capability data stays authoritative while the tier reflects human review.
  """

  alias TinyCI.Action
  alias TinyCI.Registry.{Entry, Index}

  @env_key :tiny_ci_actions

  @doc """
  Returns the action modules a package declares under its `:tiny_ci_actions`
  application env, or `[]` if it declares none.
  """
  @spec action_modules(atom()) :: [module()]
  def action_modules(app) when is_atom(app) do
    _ = Application.load(app)

    case Application.get_env(app, @env_key, []) do
      modules when is_list(modules) -> modules
      _ -> []
    end
  end

  @doc """
  Scans installed packages for self-identified actions and returns an index.

  ## Options

    * `:apps` — the applications to scan (defaults to every loaded application)
  """
  @spec scan(keyword()) :: Index.t()
  def scan(opts \\ []) do
    apps = Keyword.get_lazy(opts, :apps, &loaded_apps/0)

    apps
    |> Enum.flat_map(&entries_for_app/1)
    |> Index.new()
  end

  @doc "Loads a static JSON index from disk."
  @spec load(Path.t()) :: {:ok, Index.t()} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path) do
      Index.from_json(content)
    end
  end

  @doc """
  Searches the registry for `term`.

  Uses the JSON index at `:index` when given, otherwise scans locally-installed
  packages. `:capability` and `:tier` filter the results (see
  `TinyCI.Registry.Index.search/3`).

  ## Options

    * `:index`      — path to a static JSON index (skips scanning)
    * `:apps`       — applications to scan when no `:index` is given
    * `:capability` — keep only entries declaring this capability
    * `:tier`       — keep only entries at this review tier
  """
  @spec search(String.t() | nil, keyword()) :: {:ok, [Entry.t()]} | {:error, term()}
  def search(term, opts \\ []) do
    with {:ok, index} <- index_for(opts) do
      {:ok, Index.search(index, term, Keyword.take(opts, [:capability, :tier]))}
    end
  end

  # ---------------------------------------------------------------------------

  defp index_for(opts) do
    case Keyword.get(opts, :index) do
      nil -> {:ok, scan(Keyword.take(opts, [:apps]))}
      path -> load(path)
    end
  end

  defp entries_for_app(app) do
    app
    |> action_modules()
    |> Enum.map(&entry_for(app, &1))
  end

  defp entry_for(app, module) do
    Code.ensure_loaded(module)
    metadata = Action.metadata(module)

    %Entry{
      package: app,
      version: app_version(app) || metadata_version(metadata),
      module: module,
      name: action_name(module, metadata),
      summary: summary(module),
      capabilities: metadata_field(metadata, :capabilities, []),
      inputs: metadata_field(metadata, :inputs, []),
      tier: :unreviewed
    }
  end

  defp action_name(module, metadata) do
    case metadata_field(metadata, :name, nil) do
      nil -> inspect(module)
      name -> name
    end
  end

  defp metadata_version(metadata), do: metadata_field(metadata, :version, nil)

  defp metadata_field(nil, _key, default), do: default
  defp metadata_field(metadata, key, default), do: Map.get(metadata, key) || default

  defp app_version(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  defp summary(module) do
    case Code.fetch_docs(module) do
      {:docs_v1, _, _, _, %{"en" => doc}, _, _} when is_binary(doc) -> first_line(doc)
      _ -> nil
    end
  end

  defp first_line(doc) do
    doc
    |> String.split("\n", trim: false)
    |> Enum.map(&String.trim/1)
    |> Enum.find(&(&1 != ""))
  end

  defp loaded_apps do
    for {app, _desc, _vsn} <- Application.loaded_applications(), do: app
  end
end
