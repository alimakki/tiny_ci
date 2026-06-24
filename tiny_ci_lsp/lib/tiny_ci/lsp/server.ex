defmodule TinyCI.LSP.Server do
  @moduledoc """
  A minimal Language Server for TinyCI pipeline files.

  Surfaces the core validator's load-time diagnostics live in the editor as the
  author types. The server never executes the buffer: it reuses
  `TinyCI.DSL.Interpreter.diagnose_string/2`, the same controlled-AST path the
  runner uses, so messages shown in-editor match what `mix tiny_ci.run` prints.

  ## Lifecycle handled

    * `initialize` / `initialized`
    * `textDocument/didOpen` — analyze and publish immediately
    * `textDocument/didChange` — analyze and publish, debounced (`:debounce_ms`)
    * `textDocument/didSave` — analyze and publish immediately
    * `textDocument/didClose` — clear diagnostics for the document
    * `shutdown` / `exit`
  """

  use GenLSP

  alias GenLSP.Enumerations.TextDocumentSyncKind

  alias GenLSP.Notifications.{
    Exit,
    Initialized,
    TextDocumentDidChange,
    TextDocumentDidClose,
    TextDocumentDidOpen,
    TextDocumentDidSave,
    TextDocumentPublishDiagnostics
  }

  alias GenLSP.Requests.{
    Initialize,
    Shutdown,
    TextDocumentCompletion,
    TextDocumentDefinition,
    TextDocumentHover
  }

  alias GenLSP.Structures.{
    CompletionList,
    CompletionOptions,
    CompletionParams,
    DefinitionParams,
    DidChangeTextDocumentParams,
    DidCloseTextDocumentParams,
    DidOpenTextDocumentParams,
    DidSaveTextDocumentParams,
    HoverParams,
    InitializeResult,
    Position,
    PublishDiagnosticsParams,
    SaveOptions,
    ServerCapabilities,
    TextDocumentIdentifier,
    TextDocumentItem,
    TextDocumentSyncOptions,
    VersionedTextDocumentIdentifier
  }

  alias TinyCI.DSL.Interpreter
  alias TinyCI.LSP.{Completion, Context, Definition, DiagnosticMapper, Hover}

  @default_debounce_ms 200
  @server_name "tiny_ci_lsp"

  @doc """
  Starts the language server.

  Accepts the standard `GenLSP` options (`:buffer`, `:assigns`,
  `:task_supervisor`, `:name`) plus:

    * `:debounce_ms` — delay before analyzing a `didChange` buffer (default 200)
  """
  @spec start_link(keyword()) :: {:ok, pid()}
  def start_link(args) do
    {init_args, server_opts} = Keyword.split(args, [:debounce_ms])
    GenLSP.start_link(__MODULE__, init_args, server_opts)
  end

  @impl true
  def init(lsp, args) do
    debounce_ms = Keyword.get(args, :debounce_ms, @default_debounce_ms)
    {:ok, assign(lsp, debounce_ms: debounce_ms, timers: %{}, documents: %{}, exit_code: 1)}
  end

  # ---------------------------------------------------------------------------
  # Requests
  # ---------------------------------------------------------------------------

  @impl true
  def handle_request(%Initialize{}, lsp) do
    {:reply,
     %InitializeResult{
       capabilities: %ServerCapabilities{
         text_document_sync: %TextDocumentSyncOptions{
           open_close: true,
           change: TextDocumentSyncKind.full(),
           save: %SaveOptions{include_text: true}
         },
         completion_provider: %CompletionOptions{trigger_characters: [":", " "]},
         hover_provider: true,
         definition_provider: true
       },
       server_info: %{name: @server_name}
     }, lsp}
  end

  def handle_request(%Shutdown{}, lsp) do
    {:reply, nil, assign(lsp, exit_code: 0)}
  end

  def handle_request(
        %TextDocumentCompletion{
          params: %CompletionParams{
            text_document: %TextDocumentIdentifier{uri: uri},
            position: %Position{line: line, character: character}
          }
        },
        lsp
      ) do
    items =
      lsp
      |> document(uri)
      |> Context.at(line, character)
      |> Completion.items()

    {:reply, %CompletionList{is_incomplete: false, items: items}, lsp}
  end

  def handle_request(
        %TextDocumentHover{
          params: %HoverParams{
            text_document: %TextDocumentIdentifier{uri: uri},
            position: %Position{line: line, character: character}
          }
        },
        lsp
      ) do
    {:reply, Hover.at(document(lsp, uri), line, character), lsp}
  end

  def handle_request(
        %TextDocumentDefinition{
          params: %DefinitionParams{
            text_document: %TextDocumentIdentifier{uri: uri},
            position: %Position{line: line, character: character}
          }
        },
        lsp
      ) do
    {:reply, Definition.at(uri, document(lsp, uri), line, character), lsp}
  end

  def handle_request(_request, lsp) do
    {:noreply, lsp}
  end

  defp document(lsp, uri), do: Map.get(assigns(lsp).documents, uri, "")

  # ---------------------------------------------------------------------------
  # Notifications
  # ---------------------------------------------------------------------------

  @impl true
  def handle_notification(%Initialized{}, lsp) do
    GenLSP.log(lsp, "[tiny_ci_lsp] initialized")
    {:noreply, lsp}
  end

  def handle_notification(
        %TextDocumentDidOpen{
          params: %DidOpenTextDocumentParams{
            text_document: %TextDocumentItem{uri: uri, text: text}
          }
        },
        lsp
      ) do
    publish(lsp, uri, text)
    {:noreply, put_document(lsp, uri, text)}
  end

  def handle_notification(
        %TextDocumentDidChange{
          params: %DidChangeTextDocumentParams{
            text_document: %VersionedTextDocumentIdentifier{uri: uri},
            content_changes: changes
          }
        },
        lsp
      ) do
    text = latest_text(changes)
    # Track the buffer immediately so completion/hover see the live text;
    # only the diagnostic publish is debounced.
    {:noreply, lsp |> put_document(uri, text) |> schedule_publish(uri, text)}
  end

  def handle_notification(
        %TextDocumentDidSave{
          params: %DidSaveTextDocumentParams{
            text_document: %TextDocumentIdentifier{uri: uri},
            text: text
          }
        },
        lsp
      ) do
    text = text || read_uri(uri)
    publish(lsp, uri, text)
    {:noreply, put_document(lsp, uri, text)}
  end

  def handle_notification(
        %TextDocumentDidClose{
          params: %DidCloseTextDocumentParams{text_document: %TextDocumentIdentifier{uri: uri}}
        },
        lsp
      ) do
    publish_diagnostics(lsp, uri, [])
    {:noreply, delete_document(lsp, uri)}
  end

  def handle_notification(%Exit{}, lsp) do
    System.halt(assigns(lsp).exit_code)
    {:noreply, lsp}
  end

  def handle_notification(_notification, lsp) do
    {:noreply, lsp}
  end

  # ---------------------------------------------------------------------------
  # Debounce timers
  # ---------------------------------------------------------------------------

  @impl true
  def handle_info({:publish, uri, text}, lsp) do
    state = assigns(lsp)
    publish(lsp, uri, text)
    {:noreply, assign(lsp, timers: Map.delete(state.timers, uri))}
  end

  def handle_info(_message, lsp) do
    {:noreply, lsp}
  end

  defp put_document(lsp, uri, text) do
    assign(lsp, documents: Map.put(assigns(lsp).documents, uri, text))
  end

  defp delete_document(lsp, uri) do
    assign(lsp, documents: Map.delete(assigns(lsp).documents, uri))
  end

  defp schedule_publish(lsp, uri, text) do
    state = assigns(lsp)
    cancel_timer(state.timers[uri])
    ref = Process.send_after(self(), {:publish, uri, text}, state.debounce_ms)
    assign(lsp, timers: Map.put(state.timers, uri, ref))
  end

  defp cancel_timer(nil), do: :ok
  defp cancel_timer(ref), do: Process.cancel_timer(ref)

  # ---------------------------------------------------------------------------
  # Analysis + publishing
  # ---------------------------------------------------------------------------

  defp publish(lsp, uri, text) do
    diagnostics =
      text
      |> Interpreter.diagnose_string(uri_to_path(uri))
      |> DiagnosticMapper.to_lsp(text)

    publish_diagnostics(lsp, uri, diagnostics)
  end

  defp publish_diagnostics(lsp, uri, diagnostics) do
    GenLSP.notify(lsp, %TextDocumentPublishDiagnostics{
      params: %PublishDiagnosticsParams{uri: uri, diagnostics: diagnostics}
    })
  end

  defp latest_text(changes) do
    case List.last(changes) do
      %{text: text} -> text
      _ -> ""
    end
  end

  defp uri_to_path("file://" <> _ = uri), do: URI.parse(uri).path || uri
  defp uri_to_path(uri), do: uri

  defp read_uri(uri) do
    case File.read(uri_to_path(uri)) do
      {:ok, content} -> content
      {:error, _} -> ""
    end
  end
end
