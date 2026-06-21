defmodule TinyCI.LSP.CLI do
  @moduledoc """
  Escript entry point for the TinyCI language server.

  Boots the `GenLSP` supervision tree (buffer + assigns + task supervisor +
  server) speaking the Language Server Protocol over stdio, then blocks. Editors
  launch the generated `tiny_ci_lsp` binary as their language server command.
  """

  alias TinyCI.LSP.Server

  @doc """
  Starts the language server and blocks until the client disconnects.
  """
  @spec main([String.t()]) :: no_return()
  def main(_args) do
    # stdout carries the JSON-RPC stream — keep all logging on stderr so it
    # cannot corrupt the protocol the editor reads.
    :logger.update_handler_config(:default, :config, %{type: :standard_error})
    Logger.configure(level: :warning)

    {:ok, _} = Application.ensure_all_started(:gen_lsp)
    {:ok, _} = Application.ensure_all_started(:tiny_ci)

    children = [
      {GenLSP.Buffer, name: TinyCI.LSP.Buffer},
      {GenLSP.Assigns, name: TinyCI.LSP.Assigns},
      {Task.Supervisor, name: TinyCI.LSP.TaskSupervisor},
      {Server,
       buffer: TinyCI.LSP.Buffer,
       assigns: TinyCI.LSP.Assigns,
       task_supervisor: TinyCI.LSP.TaskSupervisor}
    ]

    {:ok, _pid} = Supervisor.start_link(children, strategy: :one_for_one)

    Process.sleep(:infinity)
  end
end
