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
          },
          "completionProvider" => %{"triggerCharacters" => [":", " "]},
          "hoverProvider" => true,
          "definitionProvider" => true
        },
        "serverInfo" => %{"name" => "tiny_ci_lsp"}
      },
      @timeout
    )

    notify(client, %{method: "initialized", jsonrpc: "2.0", params: %{}})
  end

  defp completion(client, id, line, character) do
    request(client, %{
      method: "textDocument/completion",
      id: id,
      jsonrpc: "2.0",
      params: %{
        textDocument: %{uri: @uri},
        position: %{line: line, character: character}
      }
    })
  end

  defp hover(client, id, line, character) do
    request(client, %{
      method: "textDocument/hover",
      id: id,
      jsonrpc: "2.0",
      params: %{
        textDocument: %{uri: @uri},
        position: %{line: line, character: character}
      }
    })
  end

  defp definition(client, id, line, character) do
    request(client, %{
      method: "textDocument/definition",
      id: id,
      jsonrpc: "2.0",
      params: %{
        textDocument: %{uri: @uri},
        position: %{line: line, character: character}
      }
    })
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

  test "offers stage-body directives on completion", %{client: client} do
    initialize(client)
    did_open(client, "stage :test do\n  \nend")

    assert_notification("textDocument/publishDiagnostics", %{"uri" => @uri}, @timeout)

    completion(client, 2, 1, 2)

    assert_result(2, %{"isIncomplete" => false, "items" => items}, @timeout)
    labels = Enum.map(items, & &1["label"])
    assert "step" in labels
    assert "env" in labels
  end

  test "offers condition primitives inside a when value", %{client: client} do
    initialize(client)
    did_open(client, "stage :deploy, when: \nend")

    assert_notification("textDocument/publishDiagnostics", %{"uri" => @uri}, @timeout)

    completion(client, 2, 0, 21)

    assert_result(2, %{"items" => items}, @timeout)
    labels = Enum.map(items, & &1["label"])
    assert "branch()" in labels
    assert "file_changed?(...)" in labels
  end

  test "documents the symbol under the cursor on hover", %{client: client} do
    initialize(client)
    did_open(client, @valid)

    assert_notification("textDocument/publishDiagnostics", %{"uri" => @uri}, @timeout)

    hover(client, 2, 0, 2)

    assert_result(2, %{"contents" => %{"value" => value}}, @timeout)
    assert value =~ "**stage**"
  end

  test "returns null hover when no DSL symbol is under the cursor", %{client: client} do
    initialize(client)
    did_open(client, @valid)

    assert_notification("textDocument/publishDiagnostics", %{"uri" => @uri}, @timeout)

    # Column 0 of the blank line below the pipeline — nothing to document.
    hover(client, 3, 2, 0)

    assert_result(3, nil, @timeout)
  end

  test "go-to-definition on a needs atom jumps to the stage declaration", %{client: client} do
    initialize(client)

    source = """
    stage :build do
      step :c, cmd: "x"
    end

    stage :deploy, needs: [:build] do
      step :s, cmd: "x"
    end
    """

    did_open(client, source)
    assert_notification("textDocument/publishDiagnostics", %{"uri" => @uri}, @timeout)

    # `:build` inside needs is on line 4 (0-based); the `b` sits at character 24.
    definition(client, 2, 4, 25)

    assert_result(
      2,
      %{"uri" => @uri, "range" => %{"start" => %{"line" => 0, "character" => 0}}},
      @timeout
    )
  end

  test "publishes a flow diagnostic for an undefined needs target", %{client: client} do
    initialize(client)

    did_open(client, "stage :build, needs: [:missing] do\n  step :c, cmd: \"x\"\nend\n")

    assert_notification(
      "textDocument/publishDiagnostics",
      %{"uri" => @uri, "diagnostics" => [diagnostic]},
      @timeout
    )

    assert diagnostic["message"] =~ "needs unknown stage :missing"
    # Anchored to the stage declaration, not line 1 column 1 by default.
    assert %{"start" => %{"line" => 0}} = diagnostic["range"]
  end
end
