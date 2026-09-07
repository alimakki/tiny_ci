# M2-07 — `tiny_ci serve`, the config file, the HTTP API, token auth, dogfooding

**Milestone:** M2 · **Size:** M · **Depends on:** M2-04, M2-05, M2-06, M1-01 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M2-01..06 landed

## Summary

This task turns the M2 components into a product: one command that reads a config file, starts
the server tree, listens, and shuts down gracefully; an HTTP API with bearer-token auth for
listing, inspecting, streaming, cancelling, and manually triggering runs; and the first
dogfood — tiny_ci's own repository built by a running `tiny_ci serve`.

**Milestone gate:** a team points a GitHub webhook at a fresh VM running one binary and sees a
status check on their pull request within a minute of pushing.

## In scope

- `TinyCI.Server.Config` struct, loader, validator, env overrides.
- `TinyCI.Server.Supervisor` composing everything from M2-01..06 from a `%Config{}`.
- `tiny_ci serve` subcommand (registered from `tiny_ci_dist` config) with graceful shutdown.
- HTTP API under `/api` with bearer auth.
- `tiny_ci.server.exs` at the repo root and `docs/server.md` walkthrough; a live dogfood run.

## Out of scope

- The web UI (M3). The API is what M3 builds on.
- Multi-node (M4).

## Read first

- Every `lib/tiny_ci/server/*.ex` from M2-01..06; `lib/tiny_ci/cli.ex` (subcommand registry).
- `lib/tiny_ci/runs.ex` (history reads), `lib/tiny_ci/runs/projection.ex`.
- `Plug.Conn.send_chunked/2` for streaming NDJSON.
- Erlang signal handling: `:os.set_signal/2` and a `gen_event` handler on `:erl_signal_server`
  (Elixir has no wrapper; see the OTP `kernel` docs for `erl_signal_server`).

## Design

### Config file

`tiny_ci.server.exs` — an Elixir keyword list evaluated with `Code.eval_file/1`. This is
operator-owned configuration, not a pipeline from a repository, so evaluation is acceptable;
say so in the docs. Search order: `--config PATH`, `./tiny_ci.server.exs`,
`$XDG_CONFIG_HOME/tiny_ci/server.exs`.

```elixir
[
  port: 4040,
  bind: "127.0.0.1",
  public_url: "https://ci.example.com",
  data_dir: "/var/lib/tiny_ci",
  api_token: {:secret, "TINY_CI_API_TOKEN"},        # or {:env, "..."} or a literal (discouraged)
  max_concurrent: 2,
  protected_branches: ["main", "release/*"],
  auto_cancel: true,
  allow_env_secrets: false,
  keep_failed_workspaces: 5,
  runs_keep: 500,
  shutdown_grace_ms: 30_000,
  repos: [
    [
      name: "tiny_ci",
      url: "git@github.com:alimakki/tiny_ci.git",
      forge: :github,
      api_base: "https://api.github.com",
      token: {:secret, "GITHUB_TOKEN"},
      webhook_secret: {:secret, "GITHUB_WEBHOOK_SECRET"},
      pipeline: nil,                 # discovery; or "ci" for .tiny_ci/ci.exs
      default_branch: "main",
      poll_interval: 60_000,         # 0 disables polling
      submodules: false
    ]
  ]
]
```

`TinyCI.Server.Config.load(path_or_nil) :: {:ok, %Config{}} | {:error, [String.t()]}` validates
types and required keys (`data_dir`, at least one repo with `url`), expands `~`, applies env
overrides `TINY_CI_PORT`, `TINY_CI_BIND`, `TINY_CI_DATA_DIR`, `TINY_CI_PUBLIC_URL`, and
resolves `{:secret, name}` / `{:env, name}` values lazily through a `Config.resolve/2` that
takes the running secrets store (so the store starts before repos are finalised).
`protected_branches` accept `*` globs (reuse `TinyCI.Context.any_file_matches?/2`'s glob → regex).

### Supervisor

```
TinyCI.Server.Supervisor(config)  rest_for_one
├── Secrets.Store
├── RunRegistry, EventBus, RunSupervisor
├── Workspace.RepoRegistry + Workspace.RepoSupervisor
├── Scheduler(config)
├── StatusReporter(config)
├── Poller.Supervisor(config)          # one Poller per repo with poll_interval > 0
└── Web.Endpoint(config)               # Bandit, last, so nothing is reachable before the rest is up
```

`TinyCI.Server.Application` starts nothing by default; `serve` starts this supervisor. Add a
periodic `TinyCI.Runs.prune/2` (`runs_keep`) and workspace prune, hourly, in a tiny
`Maintenance` GenServer.

### `tiny_ci serve`

```
tiny_ci serve [--config PATH] [--port N] [--bind ADDR] [--data-dir DIR] [--check]
```

`--check` loads and validates the config, prints a summary (repos, port, data dir, which repos
have tokens/webhook secrets/polling), and exits 0/1 without starting. Otherwise: start the
supervisor, print `tiny_ci serve listening on http://bind:port (data: dir)`, block. On SIGTERM
or SIGINT: stop the endpoint and pollers, stop accepting (Scheduler `drain/0`: no new
dispatch), wait up to `shutdown_grace_ms` for running runs, then `Runs.cancel/2` the rest with
reason "server shutdown", then exit 0.

### HTTP API (all under `/api`, all require `Authorization: Bearer <api_token>` except `/healthz`)

| Method & path | Response |
|---|---|
| `GET /api/repos` | configured repos (no tokens/secrets in the output) |
| `GET /api/runs?repo=&limit=` | active runs first, then history (`TinyCI.Runs.list/2` per repo project_id), each as `Projection.to_json/1` plus `live: bool` |
| `GET /api/runs/:id` | one run (live status merged onto the projection) |
| `GET /api/runs/:id/events[?follow=1]` | NDJSON; with `follow`, chunked: replay the file then stream bus events until `run_finished`/final status |
| `POST /api/runs/:id/cancel` | 202 or 409 if not running |
| `POST /api/repos/:name/runs` `{"ref": "main"}` or `{"sha": "..."}` | resolves the ref via the mirror, enqueues a `:manual` run, 202 with id |
| `GET /api/queue` | queued + active |

Errors are JSON `{"error": "..."}`. 401 on missing/invalid token (`secure_compare`).

### Dogfood

- Commit `tiny_ci.server.exs` configured for this repository with polling (a laptop cannot
  receive webhooks) and `pipeline: nil`.
- `docs/server.md` gets a "Quick start" that goes: download binary → `tiny_ci secrets init` →
  `tiny_ci secrets set GITHUB_TOKEN` → `tiny_ci serve --check` → `tiny_ci serve` → push → see the
  status check. Run through it for real once on the implementer's machine and paste the API
  output for one run into the doc.

## TDD plan

1. **`test/tiny_ci/server/config_test.exs`** — valid file loads with defaults applied; missing
   `data_dir` and empty `repos` are listed as errors together; bad types are reported by key;
   env overrides win; `{:secret, _}` resolution through a test store; glob protected branches
   match. → implement `Config`.
2. **`test/tiny_ci/server/web/api_test.exs`** (Plug.Test + a started supervisor on a tmp data
   dir) — 401 without token; `/api/repos` hides tokens; run a fixture pipeline via
   `POST /api/repos/:name/runs` and read it back from `/api/runs` and `/api/runs/:id`;
   `/api/runs/:id/events` returns the NDJSON of a finished run; `?follow=1` on a slow run
   streams events and terminates after the final status (assert with a real HTTP client on an
   ephemeral port); `cancel` on a running run → 202 and the run ends `cancelled`; on a finished
   run → 409. → implement router additions.
3. **`test/tiny_ci/server/supervisor_test.exs`** — starts from a `%Config{}`; children order;
   `--check`-style summary function output. → implement `Supervisor`, `Maintenance`.
4. **`test/tiny_ci/server/cli/serve_test.exs`** — `serve --check` with a valid/invalid config
   returns 0/1; graceful shutdown: start via the supervisor API, enqueue a slow run, call the
   shutdown function with `shutdown_grace_ms: 200` → the run is cancelled and the function
   returns within a bounded time. (Signal delivery itself is verified manually: `kill -TERM`.)
5. Manual: run the quick start against this repo with polling; confirm a run appears in the
   API after a push; confirm the status check on GitHub if a token is available.
6. Suites (both projects), credo, `mix tiny_ci.run`.

## Acceptance criteria

- [ ] `tiny_ci serve --check` validates a config and explains every problem in one pass.
- [ ] `tiny_ci serve` starts everything from M2-01..06 and shuts down gracefully on SIGTERM.
- [ ] The API is token-protected and covers list/show/stream/cancel/trigger/queue.
- [ ] `follow=1` streams live events and ends.
- [ ] A push to this repository, with the server polling, produces a recorded run visible in
      the API (documented with real output).
- [ ] History and workspaces are pruned periodically per config.

## Pitfalls

- `Code.eval_file/1` on config: catch `CompileError`/`SyntaxError` and report the file:line.
- Chunked responses need `send_chunked/2` before any `chunk/2`; a client disconnect raises in
  `chunk/2` — rescue and unsubscribe.
- Do not hold the projection of every historic run in memory for `/api/runs`; read `meta.json`
  files (M0-06 `list/2` already does) and cap `limit` at 200.
- `rest_for_one` ordering matters: the store before anything that resolves secrets.

## Docs

- `docs/server.md`: quick start, config reference (every key with default), API reference,
  shutdown behaviour, operations (systemd unit example).
- README: "Server" section pointing at `docs/server.md`.

## Follow-ups

- systemd/launchd templates in `contrib/`.
