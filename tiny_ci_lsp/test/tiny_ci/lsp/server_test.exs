defmodule TinyCI.LSP.ServerTest do
  use ExUnit.Case, async: false

  import GenLSP.Test

  alias TinyCI.LSP.Server

  @uri "file:///tmp/tiny_ci/pipeline.exs"
  @timeout 2_000

  @valid """
  stage :test do
    step :unit, cmd: "mix test"
  end
  """

  @invalid """
  stage :deploy, when: dangerous() == 0 do
    step :release, cmd: "make release"
  end
  """

  setup do
    server = server(Server, debounce_ms: 25)
    client = client(server)
    [server: server, client: client]
  end

  defp initialize(client) do
    request(client, %{
      method: "initialize",
      id: 1,
      jsonrpc: "2.0",
      params: %{capabilities: %{}, rootUri: "file:///tmp/tiny_ci"}
    })

    assert_result(
      1,
      %{
        "capabilities" => %{
          "textDocumentSync" => %{
            "openClose" => true,
            "change" => 1,
            "save" => %{"includeText" => true}
          }
        },
        "serverInfo" => %{"name" => "tiny_ci_lsp"}
      },
      @timeout
    )

    notify(client, %{method: "initialized", jsonrpc: "2.0", params: %{}})
  end

  defp did_open(client, text) do
    notify(client, %{
      method: "textDocument/didOpen",
      jsonrpc: "2.0",
      params: %{
        textDocument: %{uri: @uri, languageId: "elixir", version: 1, text: text}
      }
    })
  end

  defp did_change(client, text, version) do
    notify(client, %{
      method: "textDocument/didChange",
      jsonrpc: "2.0",
      params: %{
        textDocument: %{uri: @uri, version: version},
        contentChanges: [%{text: text}]
      }
    })
  end

  test "completes the initialize handshake over the transport", %{client: client} do
    initialize(client)
  end

  test "publishes a diagnostic at the offending range for a disallowed construct", %{
    client: client
  } do
    initialize(client)
    did_open(client, @invalid)

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => diagnostics},
      @timeout
    )

    assert [diagnostic] = diagnostics
    assert diagnostic["message"] =~ "Invalid condition expression"
    assert diagnostic["source"] == "tiny_ci"
    # `dangerous()` begins at column 22 (1-based) on the first line → 21 (0-based).
    assert %{"start" => %{"line" => 0, "character" => 21}} = diagnostic["range"]
  end

  test "clears diagnostics when the buffer is fixed (debounced didChange)", %{client: client} do
    initialize(client)
    did_open(client, @invalid)

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => [_ | _]},
      @timeout
    )

    did_change(client, @valid, 2)

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => []},
      @timeout
    )
  end

  test "re-reports diagnostics when a fixed buffer breaks again", %{client: client} do
    initialize(client)
    did_open(client, @valid)

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => []},
      @timeout
    )

    did_change(client, @invalid, 2)

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => [_ | _]},
      @timeout
    )
  end

  test "reports a syntax error as a diagnostic", %{client: client} do
    initialize(client)
    did_open(client, "stage :x do\n  step :a, cmd: \"ok\"\n")

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => [diagnostic]},
      @timeout
    )

    assert diagnostic["message"] =~ "missing terminator"
  end
end
