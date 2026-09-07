# M2-05 — Commit status back to the forge

**Milestone:** M2 · **Size:** M · **Depends on:** M2-04 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M2-01..04 landed

## Summary

Without a status check on the commit, a CI run is invisible to the team. This task posts
`pending` when a run is queued and started, and `success` / `failure` / `error` when it ends,
to GitHub (commit statuses API), GitLab (commit statuses API), and Gitea. It is driven purely
by the event bus, so it works for every trigger source including the poller and manual runs.

## In scope

- `{:req, "~> 0.5"}` in `tiny_ci_server` (pin current minor).
- `TinyCI.Server.Forge` gains `report_status/4`; implementations for the three forges.
- `TinyCI.Server.StatusReporter` GenServer subscribed to `:runs`.
- Token resolution from repo config via the secrets store (M2-06) or environment.
- Retry with backoff; never affects the run.

## Out of scope

- GitHub Checks API (needs a GitHub App). Statuses work with a personal or fine-grained token
  and are enough for branch protection. Checks are a follow-up.
- Annotations / summaries in the forge UI.

## Read first

- `lib/tiny_ci/server/event_bus.ex`, `scheduler.ex`, `run.ex` — the exact messages broadcast.
- Req docs: `Req.new/1`, `Req.post/2`, `Req.Test` (stubbing via `plug:`).
- Forge docs for commit statuses (fetch current pages): GitHub `POST /repos/{owner}/{repo}/statuses/{sha}`;
  GitLab `POST /projects/{id}/statuses/{sha}`; Gitea `POST /repos/{owner}/{repo}/statuses/{sha}`.

## Design

### Behaviour addition

```elixir
@callback report_status(repo :: Repo.t(), sha :: String.t(), state :: :pending | :success | :failure | :error,
                        opts :: [description: String.t(), context: String.t(), target_url: String.t() | nil, token: String.t(), api_base: String.t()])
          :: :ok | {:error, term()}
```

State mapping from run status: `:starting`/`:running`/queued → `:pending`; `:passed` →
`:success`; `:failed` → `:failure`; `:aborted`/`:cancelled` → `:error` (GitLab: `canceled`);
`:crashed` → `:error`. Descriptions: "Queued", "Running", "Passed in 1m 12s", "Failed: stage
test", "Cancelled: superseded by abc1234", "Crashed". Context/name: `tiny_ci/<pipeline>`.

`target_url`: `"#{config.public_url}/runs/#{run_id}"` when `public_url` is set (M2-07 serves
`/api/runs/:id` now; M3 serves a page at that path).

### Repo config surface (consumed by M2-07)

```elixir
%Repo{..., forge: :github | :gitlab | :gitea, api_base: "https://api.github.com" | ..., token: {:secret, "GITHUB_TOKEN"} | {:env, "GITHUB_TOKEN"} | nil, gitlab_project_id: nil}
```

No token → reporting disabled for that repo with one warning at startup.

### `TinyCI.Server.StatusReporter`

Subscribes to `:runs`. On `{:scheduler, :queued, run_id, request}` and every `{:run_status, ...}`
it computes `{repo, sha, state, description}` from the request carried in the message (make
sure `Run`/`Scheduler` include enough of the request in the broadcast: `repo`, `sha`,
`pipeline`, `meta`). Posts asynchronously (`Task.Supervisor` under the server tree) with up to
three attempts and 1 s / 4 s backoff. Failures are logged at warning with the forge response
body truncated to 300 bytes. The reporter process never crashes on a bad response.

Deduplicate: do not post `pending` twice for `starting` and `running`; post on queued and on
running only.

## TDD plan

1. **`test/tiny_ci/server/forge/github_status_test.exs`** (and gitlab/gitea) — with
   `Req.Test` stub: `report_status/4` hits the right path, sends the right JSON (`state`,
   `context`/`name`, `description`, `target_url`), uses the token header; a 422 returns
   `{:error, _}`. → implement per forge.
2. **`test/tiny_ci/server/status_reporter_test.exs`** — feed synthetic bus messages
   (`Scheduler` and `Run` shapes) and assert, via the Req.Test stub, the sequence
   `pending(Queued) → pending(Running) → success(...)`; a failing forge (stub returns 500
   twice then 200) results in one success after retries; a repo without a token produces no
   requests. → implement the reporter.
3. End to end in `run_test.exs`: a real run against a fixture repo with the stub forge → three
   status posts observed.
4. Suites, credo, dogfood.

## Acceptance criteria

- [ ] Queued, running, and final states are reported for every run with a repo.
- [ ] Mapping and descriptions match the table above.
- [ ] Missing token disables reporting with a warning; forge errors never affect runs.
- [ ] Retries with backoff are tested.

## Pitfalls

- GitHub statuses are limited to 1000 per sha per context; irrelevant at our scale but do not
  post on every event, only on state changes.
- GitLab needs the numeric or URL-encoded project id; take it from config, do not guess from
  the clone URL.
- `Req.Test` requires the request to be built with `plug: {Req.Test, Name}`; put the option on
  the `Req.new/1` call site through a single `TinyCI.Server.HTTP.client/0` so tests can inject it.

## Docs

- `docs/server.md`: "Status checks" section — token scopes per forge, branch protection setup.

## Follow-ups

- GitHub Checks API via GitHub App.
