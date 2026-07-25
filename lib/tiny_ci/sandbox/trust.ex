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

  @type class :: :first_party | :builtin | :local | :third_party

  @doc """
  Classifies `module` as `:first_party`, `:builtin`, `:local`, or `:third_party`.

  ## Options

    * `:root_app` — the root project's application (treated as first-party).
      Defaults to the current Mix project's app when Mix is available.
  """
  @spec classify(module(), keyword()) :: class()
  def classify(module, opts \\ []) when is_atom(module) do
    root_app = Keyword.get(opts, :root_app) || root_app()

    case owning_app(module) do
      nil -> :local
      ^root_app when not is_nil(root_app) -> :first_party
      app -> if Resolver.builtin?(app), do: :builtin, else: :third_party
    end
  end

  @doc """
  Returns `true` when `module` is safe to run inline (not third-party).
  """
  @spec trusted?(module(), keyword()) :: boolean()
  def trusted?(module, opts \\ []), do: classify(module, opts) != :third_party

  defp owning_app(module) do
    Code.ensure_loaded(module)

    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end

  defp root_app do
    if function_exported?(Mix.Project, :config, 0), do: Mix.Project.config()[:app]
  end
end
