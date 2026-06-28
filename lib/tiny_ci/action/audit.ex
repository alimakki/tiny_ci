defmodule TinyCI.Action.Audit do
  @moduledoc """
  The I/O layer over `TinyCI.Action.Resolver`: gathers each action's owning
  application and loaded version, reads the project's `mix.lock`, resolves the
  supply-chain status, and renders a human-readable tree.

  Used by `mix tiny_ci.actions.audit` (reporting) and by `mix tiny_ci.run`
  (run-start verification via `verify/3`).
  """

  alias TinyCI.Action.{Lockfile, Resolver}
  alias TinyCI.PipelineSpec

  @doc """
  Resolves every action in `spec` against the project's lockfile.

  ## Options

    * `:root_app` — the root project's application name (treated as first-party)
    * `:lock_path` — override the lockfile location (defaults to `<root>/mix.lock`)
  """
  @spec analyze(PipelineSpec.t(), String.t(), keyword()) ::
          {:ok, [Resolver.entry()]} | {:error, term()}
  def analyze(%PipelineSpec{} = spec, root, opts \\ []) do
    lock_path = Keyword.get(opts, :lock_path, Path.join(root, "mix.lock"))

    with {:ok, locks} <- Lockfile.read(lock_path) do
      refs = spec |> Resolver.references() |> build_refs()
      entries = Resolver.resolve(refs, locks, root_app: opts[:root_app])
      {:ok, Enum.sort_by(entries, &{&1.app || :"", inspect(&1.module)})}
    end
  end

  @doc """
  Verifies a spec's actions against the lockfile (run-start gate).

  Returns `:ok` or `{:error, {:action_lock, messages}}`.
  """
  @spec verify(PipelineSpec.t(), String.t(), keyword()) ::
          :ok | {:error, {:action_lock, [String.t()]}} | {:error, term()}
  def verify(%PipelineSpec{} = spec, root, opts \\ []) do
    lock_path = Keyword.get(opts, :lock_path, Path.join(root, "mix.lock"))

    with {:ok, locks} <- Lockfile.read(lock_path) do
      refs = spec |> Resolver.references() |> build_refs()
      Resolver.verify(refs, locks, root_app: opts[:root_app])
    end
  end

  @doc """
  Builds resolution references for a list of modules by looking up each module's
  owning OTP application and its loaded version.
  """
  @spec build_refs([module()]) :: [Resolver.ref()]
  def build_refs(modules) do
    Enum.map(modules, fn module ->
      Code.ensure_loaded(module)
      app = app_for(module)
      %{module: module, app: app, version: version_for(app)}
    end)
  end

  defp app_for(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end

  defp version_for(nil), do: nil

  defp version_for(app) do
    case Application.spec(app, :vsn) do
      nil -> nil
      vsn -> List.to_string(vsn)
    end
  end

  @doc """
  Renders resolved entries as a human-readable tree.
  """
  @spec format([Resolver.entry()]) :: String.t()
  def format([]), do: "No module actions referenced by this pipeline.\n"

  def format(entries) do
    header = "Resolved actions (#{length(entries)}):\n\n"
    header <> Enum.map_join(entries, "\n", &format_entry/1) <> "\n"
  end

  defp format_entry(entry) do
    mark = if entry.status == :ok, do: "✓", else: "✗"
    version = entry.version || "—"
    sum = short_checksum(entry.checksum)

    line =
      "  #{mark} #{inspect(entry.module)}  [#{entry.source}]  #{version}#{sum}"

    case entry.message do
      nil -> line
      message -> line <> "\n      " <> message
    end
  end

  defp short_checksum(nil), do: ""
  defp short_checksum(checksum), do: "  #{String.slice(checksum, 0, 12)}…"
end
