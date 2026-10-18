defmodule TinyCI.Sandbox.Trust do
  @moduledoc """
  Classifies an action module's provenance to decide whether it may run inline
  (in this BEAM) or must be confined to an OS sandbox.

  The BEAM is not a security boundary — a module compiled into a third-party
  dependency can call NIFs, `System.cmd/3`, or open sockets with the full
  authority of the runner. So only **first-party** code (your own app), OTP/
  Elixir **builtins**, and modules with **no owning application** (defined in a
  pipeline script) are trusted to run inline. Anything shipped by a dependency
  is **third-party** and must be sandboxed.

  Classification reuses `TinyCI.Action.Resolver.builtin?/1` so the builtin
  allowlist has a single definition.
  """

  alias TinyCI.Action.Resolver
  alias TinyCI.Project

  @type class :: :first_party | :builtin | :local | :third_party | :unknown

  @doc """
  Classifies `module` as `:first_party`, `:builtin`, `:local`, `:third_party`, or
  `:unknown`.

  ## Options

    * `:root_app` — the root project's application (treated as first-party).
      Defaults to `TinyCI.Project.root_app/0` (the current Mix project's app when
      Mix is running, `nil` otherwise).
    * `:load` — whether to load the module if it is not already loaded (default
      `true`). Pass `false` in an untrusted run so classification can never load
      repository code; a module that is not already loaded then classifies as
      `:unknown`, which callers must treat as untrusted.
  """
  @spec classify(module(), keyword()) :: class()
  def classify(module, opts \\ []) when is_atom(module) do
    root_app = Keyword.get(opts, :root_app) || Project.root_app()
    load? = Keyword.get(opts, :load, true)

    case owning_app(module, load?) do
      :unknown -> :unknown
      nil -> :local
      ^root_app when not is_nil(root_app) -> :first_party
      app -> if Resolver.builtin?(app), do: :builtin, else: :third_party
    end
  end

  @doc """
  Returns `true` when `module` is safe to run inline (not third-party or unknown).
  """
  @spec trusted?(module(), keyword()) :: boolean()
  def trusted?(module, opts \\ []) do
    classify(module, opts) in [:first_party, :builtin, :local]
  end

  defp owning_app(module, true) do
    Code.ensure_loaded(module)
    app(module)
  end

  defp owning_app(module, false) do
    case :code.is_loaded(module) do
      {:file, _path} -> app(module)
      false -> :unknown
    end
  end

  defp app(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end
end
