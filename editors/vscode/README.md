# TinyCI — VS Code extension

A thin [language client](https://code.visualstudio.com/api/language-extensions/language-server-extension-guide)
that launches the `tiny_ci_lsp` server and attaches it to TinyCI pipeline files
(`.tiny_ci/**/*.exs` and `tiny_ci.exs`). It provides:

- **diagnostics** — validator errors, live;
- **completion** — directives, option keys, and condition primitives;
- **hover** — description + example for the symbol under the cursor.

The extension is intentionally minimal: every feature comes from the server.

## Prerequisites

1. **Node.js + npm** (only to install the client's one dependency).
2. **The server binary.** From the repo root:
   ```bash
   cd tiny_ci_lsp && mix escript.build      # → tiny_ci_lsp/tiny_ci_lsp
   ```
   (The repo's `.mise.toml` builds this automatically when you enter the project.)
   The build always runs in `MIX_ENV=prod` (enforced by `cli/0` in
   `tiny_ci_lsp/mix.exs`); a dev build would bundle `tidewave`/`bandit`, whose
   startup output corrupts the LSP stream and prevents the server from starting.

## Install the client dependency

```bash
cd editors/vscode
npm install
```

## Run it

**Option A — Extension Development Host (quickest for trying it):**

1. Open the `editors/vscode/` folder in VS Code.
2. Press <kbd>F5</kbd>. A new “Extension Development Host” window opens with the
   extension loaded.
3. In that window, open this repo and a `.tiny_ci/*.exs` file. You'll get
   diagnostics, completion (<kbd>Ctrl</kbd>+<kbd>Space</kbd>), and hover.

**Option B — package and install a `.vsix` (persistent):**

```bash
cd editors/vscode
npx --yes @vscode/vsce package          # → tiny-ci-lsp-0.1.0.vsix
code --install-extension tiny-ci-lsp-0.1.0.vsix
```

Then reload VS Code and open a pipeline file.

## Configuration

The extension finds the server in this order:

1. the `tinyCi.serverPath` setting (absolute path), if set;
2. `<workspace>/tiny_ci_lsp/tiny_ci_lsp` (where `mix escript.build` puts it);
3. `tiny_ci_lsp` on your `PATH`.

Set `tinyCi.serverPath` in your settings if your binary lives elsewhere.

## Troubleshooting

- **Nothing happens on a pipeline file** — confirm the file matches
  `**/.tiny_ci/**/*.exs` or is named `tiny_ci.exs`. The client only attaches to
  those, by design.
- **"failed to start language server"** — the binary wasn't found or isn't
  executable. Build it (`mix escript.build` in `tiny_ci_lsp`) or set
  `tinyCi.serverPath`. Check the **TinyCI** output channel for details.
