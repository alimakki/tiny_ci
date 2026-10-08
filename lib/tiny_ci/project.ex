defmodule TinyCI.Project do
  @moduledoc """
  Facts about the project tiny_ci is running in, without requiring Mix.

  Under `mix` the host project's app name is available; in a standalone binary
  (the escript, a release) there is no host project and these functions answer
  from tiny_ci itself.
  """

  @doc """
  The OTP application name of the Mix project being run, or `nil` outside Mix.

  `TinyCI.Action.Audit` treats this app's modules as first-party actions. Mix being
  loadable is not enough: with Elixir's libraries on the code path but no Mix
  running (an escript started with `ERL_LIBS` pointing at them), `Mix.Project.config/0`
  would exit, so the project stack process must be alive too.
  """
  @spec root_app() :: atom() | nil
  def root_app do
    if mix_running?(), do: Mix.Project.config()[:app]
  end

  defp mix_running? do
    Code.ensure_loaded?(Mix.Project) and function_exported?(Mix.Project, :config, 0) and
      Process.whereis(Mix.ProjectStack) != nil
  end

  @doc """
  tiny_ci's own version string.

  ## Examples

      iex> TinyCI.Project.version() =~ ~r/^\\d+\\.\\d+\\.\\d+/
      true
  """
  @spec version() :: String.t()
  def version do
    case Application.spec(:tiny_ci, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end
end
