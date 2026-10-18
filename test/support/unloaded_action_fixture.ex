defmodule TinyCI.UnloadedActionFixture do
  @moduledoc """
  A module action used to prove untrusted pipeline loading never loads code.

  If this module is loaded, `@on_load` writes the path in
  `TINY_CI_ON_LOAD_MARKER` (when set). Tests assert neither the module nor the
  marker appears.
  """

  @on_load :__mark_loaded__

  def __mark_loaded__ do
    case System.get_env("TINY_CI_ON_LOAD_MARKER") do
      nil -> :ok
      path -> File.write(path, "loaded")
    end

    :ok
  end

  @doc false
  def execute(_config, _context), do: {:ok, %{}}
end
