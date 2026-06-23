// Thin VS Code client for the TinyCI language server (tiny_ci_lsp).
//
// It does nothing language-specific itself — it just launches the escript over
// stdio and attaches it to TinyCI pipeline files. All features (diagnostics,
// completion, hover) come from the server.

const fs = require("fs");
const path = require("path");
const { workspace, window } = require("vscode");
const { LanguageClient, TransportKind } = require("vscode-languageclient/node");

let client;

// Resolve the server executable: explicit setting → <workspace>/tiny_ci_lsp/tiny_ci_lsp
// (where `mix escript.build` puts it) → bare `tiny_ci_lsp` on PATH.
function resolveServerPath() {
  const configured = workspace.getConfiguration("tinyCi").get("serverPath");
  if (configured) {
    return configured;
  }

  for (const folder of workspace.workspaceFolders || []) {
    const candidate = path.join(folder.uri.fsPath, "tiny_ci_lsp", "tiny_ci_lsp");
    if (fs.existsSync(candidate)) {
      return candidate;
    }
  }

  return "tiny_ci_lsp";
}

function activate() {
  const command = resolveServerPath();

  const serverOptions = {
    command,
    args: [],
    transport: TransportKind.stdio,
  };

  const clientOptions = {
    // Attach only to pipeline files, not every Elixir file in the workspace.
    documentSelector: [
      { scheme: "file", pattern: "**/.tiny_ci/*.exs" },
      { scheme: "file", pattern: "**/.tiny_ci/**/*.exs" },
      { scheme: "file", pattern: "**/tiny_ci.exs" },
    ],
    outputChannelName: "TinyCI",
  };

  client = new LanguageClient(
    "tinyCi",
    "TinyCI",
    serverOptions,
    clientOptions,
  );

  client.start().catch((err) => {
    window.showErrorMessage(
      `TinyCI: failed to start language server (${command}). ` +
        `Build it with \`mix escript.build\` in tiny_ci_lsp, or set tinyCi.serverPath. (${err})`,
    );
  });
}

function deactivate() {
  return client ? client.stop() : undefined;
}

module.exports = { activate, deactivate };
