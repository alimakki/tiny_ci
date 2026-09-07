defmodule TinyCI.IntegrationFixtures do
  @moduledoc """
  Action and hook modules referenced by name from the flat pipeline sources in
  `test/tiny_ci/integration_test.exs`. The interpreter never compiles code, so a
  `module:` step or hook must already be loaded; these fixtures are compiled
  into the test build for that reason.
  """

  defmodule Notifier do
    @moduledoc "Writes its `channel` config and the context branch to `output_path`."
    use TinyCI.Action

    @impl true
    def execute(config, ctx) do
      path = config[:output_path]
      content = "channel=#{config[:channel]},branch=#{ctx.branch}"
      File.write!(path, content)
      :ok
    end
  end

  defmodule ImageTagger do
    @moduledoc "Puts `image_tag` into the store from its `version` config."
    use TinyCI.Action

    @impl true
    def execute(config, _ctx) do
      {:ok, %{image_tag: "myapp:#{config[:version]}"}}
    end
  end

  defmodule StoreVerifier do
    @moduledoc "Writes `inspect(ctx.store)` to the path given by `ctx.verify_path`."
    use TinyCI.Action

    @impl true
    def execute(_config, ctx) do
      path = ctx[:verify_path]
      content = inspect(ctx.store)
      File.write!(path, content)
      :ok
    end
  end

  defmodule HookNotifier do
    @moduledoc "Module hook that writes the pipeline result and branch to `output_path`."

    def run(config, ctx) do
      path = config[:output_path]
      content = "result=#{ctx.pipeline_result},branch=#{ctx.branch}"
      File.write!(path, content)
      :ok
    end
  end
end
