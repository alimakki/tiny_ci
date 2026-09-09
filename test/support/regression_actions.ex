defmodule TinyCI.RegressionActions do
  @moduledoc false

  def execute(config, ctx) do
    case Keyword.get(config, :operation, :write) do
      :write -> {:ok, %{tag: Keyword.get(config, :tag, "new")}}
      :matrix -> if ctx.store.variant == "writer", do: {:ok, %{tag: "new"}}, else: :ok
      :config -> {:ok, %{config: config, env: ctx.env}}
      :print -> IO.puts(ctx.secrets["TOKEN"])
      :block -> block(ctx)
    end
  end

  def run(config, ctx) do
    case Keyword.get(config, :operation) do
      :block -> block(ctx)
      :print -> IO.puts(ctx.secrets["TOKEN"])
      :raise -> raise ctx.secrets["TOKEN"]
      _ -> send(ctx.test_pid, {:hook_config, config})
    end

    :ok
  end

  defp block(ctx) do
    send(ctx.test_pid, {:callback_started, self()})

    receive do
      :finish -> :ok
    end
  end
end
