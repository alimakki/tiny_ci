defmodule TinyCI.RegistryFixtures do
  @moduledoc """
  Compiled action modules used by the registry tests.

  These stand in for actions a third-party package would ship. Tests register
  them under a fake application's `:tiny_ci_actions` env so the scanner can
  discover them without a real dependency.
  """

  defmodule Deploy do
    @moduledoc "Ships a release to production over SSH.\n\nLonger description here."
    use TinyCI.Action

    @impl TinyCI.Action
    def execute(_config, _ctx), do: :ok

    @impl TinyCI.Action
    def metadata do
      %TinyCI.Action.Metadata{
        name: "acme.deploy",
        version: "2.1.0",
        capabilities: [:network, :env_read],
        inputs: [%{name: :app, type: :string, required: true}]
      }
    end
  end

  defmodule Archive do
    @moduledoc false
    use TinyCI.Action

    @impl TinyCI.Action
    def execute(_config, _ctx), do: :ok

    @impl TinyCI.Action
    def metadata do
      %TinyCI.Action.Metadata{
        name: "acme.archive",
        version: "2.1.0",
        capabilities: [:filesystem_read, :filesystem_write]
      }
    end
  end
end
