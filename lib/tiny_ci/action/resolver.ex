defmodule TinyCI.Action.Resolver do
  @moduledoc """
  Resolves the `module:` actions a pipeline uses against the lockfile and
  classifies each one — the supply-chain integrity check.

  Pure functions over already-gathered inputs (no filesystem or `Application`
  access — see `TinyCI.Action.Audit` for the I/O that feeds these): a list of
  action references (`%{module, app, version}`), the normalized lockfile from
  `TinyCI.Action.Lockfile`, and the root application name.

  Each action resolves to one of:

    * `:hex` — pinned in the lockfile; the loaded version must match the locked
      one (a mismatch is an **error**: the build has drifted from the lock).
    * `:git` / `:path` — declared in the lock but not hash-pinned by Hex (allowed,
      surfaced as such).
    * `:first_party` — the root project's own app (your code, nothing to pin).
    * `:builtin` — an OTP/Elixir application (not a dependency).
    * `:local` — a module with no owning application (e.g. defined in a script).
    * `:unlocked` — a loaded third-party app **absent from the lockfile**: an
      **error**, so unpinned actions fail closed.
  """

  alias TinyCI.Action.Lockfile
  alias TinyCI.{Hook, PipelineSpec, Stage, Step}

  @typedoc "An action awaiting resolution: its module, owning OTP app, and loaded version."
  @type ref :: %{module: module(), app: atom() | nil, version: String.t() | nil}

  @type source :: :hex | :git | :path | :first_party | :builtin | :local | :unlocked | :other

  @type entry :: %{
          module: module(),
          app: atom() | nil,
          source: source(),
          version: String.t() | nil,
          checksum: String.t() | nil,
          status: :ok | :error,
          message: String.t() | nil
        }

  # Applications that ship with Erlang/OTP or Elixir — never lockfile entries.
  @builtin_apps ~w(kernel stdlib elixir logger mix iex eex ex_unit compiler
                   crypto ssl public_key inets sasl runtime_tools os_mon
                   syntax_tools tools asn1)a

  @doc """
  Returns `true` if `app` ships with Erlang/OTP or Elixir (never a lockfile
  entry, and always trusted for sandbox purposes).
  """
  @spec builtin?(atom()) :: boolean()
  def builtin?(app) when is_atom(app), do: app in @builtin_apps

  @doc "Distinct `module:` targets referenced by a spec's steps and hooks."
  @spec references(PipelineSpec.t()) :: [module()]
  def references(%PipelineSpec{stages: stages, hooks: hooks}) do
    step_modules = for %Stage{steps: steps} <- stages, %Step{module: m} <- steps, do: m
    hook_modules = for {_event, list} <- hooks, %Hook{module: m} <- list, do: m

    (step_modules ++ hook_modules)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  @doc "Classifies every reference against the lockfile."
  @spec resolve([ref()], Lockfile.t(), keyword()) :: [entry()]
  def resolve(refs, locks, opts) do
    root_app = Keyword.get(opts, :root_app)
    Enum.map(refs, &classify(&1, locks, root_app))
  end

  @doc """
  Verifies every reference resolves cleanly.

  Returns `:ok`, or `{:error, {:action_lock, messages}}` listing each problem
  (drifted version or unlocked third-party action).
  """
  @spec verify([ref()], Lockfile.t(), keyword()) :: :ok | {:error, {:action_lock, [String.t()]}}
  def verify(refs, locks, opts) do
    case refs |> resolve(locks, opts) |> Enum.filter(&(&1.status == :error)) do
      [] -> :ok
      errors -> {:error, {:action_lock, Enum.map(errors, & &1.message)}}
    end
  end

  # ---------------------------------------------------------------------------
  # Classification
  # ---------------------------------------------------------------------------

  defp classify(%{app: nil} = ref, _locks, _root) do
    ok(ref, :local, nil, nil)
  end

  defp classify(%{app: app} = ref, _locks, root) when app == root do
    ok(ref, :first_party, ref.version, nil)
  end

  defp classify(%{app: app} = ref, _locks, _root) when app in @builtin_apps do
    ok(ref, :builtin, ref.version, nil)
  end

  defp classify(%{app: app} = ref, locks, _root) do
    case Map.get(locks, app) do
      nil -> unlocked(ref)
      %{scm: :hex} = lock -> hex(ref, lock)
      %{scm: scm} = lock -> ok(ref, scm, lock.version, lock.checksum)
    end
  end

  defp hex(ref, lock) do
    cond do
      is_nil(ref.version) ->
        ok(ref, :hex, lock.version, lock.checksum)

      ref.version == lock.version ->
        ok(ref, :hex, lock.version, lock.checksum)

      true ->
        error(
          ref,
          :hex,
          lock.version,
          lock.checksum,
          "Action #{inspect(ref.module)} (app :#{ref.app}) is loaded at version " <>
            "#{ref.version} but the lockfile pins #{lock.version}. " <>
            "Run `mix deps.get` to sync the build with mix.lock."
        )
    end
  end

  defp unlocked(ref) do
    error(
      ref,
      :unlocked,
      ref.version,
      nil,
      "Action #{inspect(ref.module)} (app :#{ref.app}) is not pinned in the lockfile " <>
        "(mix.lock). Declare it as a dependency and run `mix deps.get`; unpinned " <>
        "third-party actions are refused (supply-chain safety)."
    )
  end

  defp ok(ref, source, version, checksum) do
    entry(ref, source, version, checksum, :ok, nil)
  end

  defp error(ref, source, version, checksum, message) do
    entry(ref, source, version, checksum, :error, message)
  end

  defp entry(ref, source, version, checksum, status, message) do
    %{
      module: ref.module,
      app: ref.app,
      source: source,
      version: version,
      checksum: checksum,
      status: status,
      message: message
    }
  end
end
