defmodule TinyCI.AnsiFixtures do
  @moduledoc """
  Helpers for tests whose output depends on `IO.ANSI.enabled?/0`.

  `test/test_helper.exs` pins ANSI off for the suite, so results do not depend on
  whether a terminal is attached. A test that asserts plain text should still say so
  itself (`set_ansi(false)`), and a test that needs colours must enable them. The flag
  is global application env, so such a test must be `async: false`; the previous value
  is put back in `on_exit/1`.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Sets `:elixir, :ansi_enabled` for the current test, restoring the value found."
  @spec set_ansi(boolean()) :: :ok
  def set_ansi(enabled?) when is_boolean(enabled?) do
    previous = Application.fetch_env(:elixir, :ansi_enabled)
    Application.put_env(:elixir, :ansi_enabled, enabled?)
    on_exit(fn -> restore(previous) end)
  end

  defp restore({:ok, value}), do: Application.put_env(:elixir, :ansi_enabled, value)
  defp restore(:error), do: Application.delete_env(:elixir, :ansi_enabled)
end
