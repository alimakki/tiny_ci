defmodule MyApp.Pipeline do
  @moduledoc false
  use TinyCI.DSL

  stage :test, mode: :parallel do
    step(:unit, cmd: "mix test")
    step(:lint, cmd: "mix credo")
    step(:format, cmd: "mix format --check-formatted")
  end

  stage :deploy, when: when_branch("main") do
    step :prod, module: DeployStep do
      set(:app, "my-app")
      set(:strategy, :heroku)
    end
  end
end

# Dummy module for demo
defmodule DeployStep do
  @moduledoc false
  def execute(config, _ctx) do
    IO.puts("🚀 Deploying #{config[:app]} with #{config[:strategy]}")
    :ok
  end
end
