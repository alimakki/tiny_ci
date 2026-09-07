# M2-04 — HTTP layer, webhooks (GitHub / GitLab / Gitea), and a `ls-remote` poller

**Milestone:** M2 · **Size:** M–L · **Depends on:** M2-03 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M2-01..03 landed

## Summary

A CI server is triggered by the forge. This task adds the HTTP listener (Plug on Bandit),
webhook endpoints for the three forges people self-host against, HMAC/token verification, a
provider-neutral `Trigger` struct, repository matching against configuration, and a polling
fallback (`git ls-remote`) for machines that cannot receive webhooks (laptops, private
networks). Every trigger ends as a `Scheduler.enqueue/1`.

## In scope

- Deps in `tiny_ci_server`: `{:plug, "~> 1.16"}`, `{:bandit, "~> 1.6"}` (pin current minors).
- `TinyCI.Server.Web.Endpoint` (Bandit child spec) and `TinyCI.Server.Web.Router` (Plug.Router).
- Raw-body caching for signature verification.
- `TinyCI.Server.Forge` behaviour; `Forge.GitHub`, `Forge.GitLab`, `Forge.Gitea`.
- `TinyCI.Server.Trigger` struct and `RunRequest.from_trigger/2`.
- Repository matching by normalised clone URL.
- `TinyCI.Server.Poller` (one per repo with `poll_interval > 0`).
- Fixture payloads and tests.

## Out of scope

- Status reporting back (M2-05), the API and auth (M2-07), the UI (M3).
- Bitbucket, Gerrit. The behaviour makes them additive.

## Read first

- `lib/tiny_ci/server/scheduler.ex`, `run_request.ex`, `workspace.ex` (URL normalisation).
- Plug docs: `Plug.Router`, `Plug.Parsers` with a custom `:body_reader`, `Plug.Crypto.secure_compare/2`.
- Forge docs (fetch the current pages; do not work from memory):
  GitHub webhooks `X-Hub-Signature-256`, `X-GitHub-Event`, `push` and `pull_request` payloads;
  GitLab `X-Gitlab-Token`, `X-Gitlab-Event` (`Push Hook`, `Merge Request Hook`);
  Gitea `X-Gitea-Signature`, `X-Gitea-Event`.

## Design

### Router

```
GET  /healthz                 → 200 "ok"
POST /hooks/github            → Forge.GitHub
POST /hooks/gitlab            → Forge.GitLab
POST /hooks/gitea             → Forge.Gitea
```

Pipeline: `CacheBodyReader` (stores raw body in `conn.assigns.raw_body`) → `Plug.Parsers`
(json, `json_decoder: Jason`, 5 MB limit) → router. The hook handler:

1. `forge.event_name(conn)` → string; `"ping"`-like events → 200.
2. Parse to a `%Trigger{}` or `:ignore` (200 with a reason body) or `{:error, msg}` (400).
3. Match the trigger's `clone_url` to a configured repo → else 404 (log at info).
4. `forge.verify(conn, raw_body, repo.webhook_secret)` → else 401. (Match first so the secret is
   per repo; a request for an unknown repo still gets 404, not 401.)
5. `Scheduler.enqueue(RunRequest.from_trigger(repo, trigger))` → 202 with `{"run_id": id}`.

### `TinyCI.Server.Forge` behaviour

```elixir
@callback event_name(Plug.Conn.t()) :: String.t() | nil
@callback verify(Plug.Conn.t(), raw_body :: binary(), secret :: String.t() | nil) :: :ok | {:error, :unauthorized}
@callback parse(event :: String.t(), payload :: map()) :: {:ok, Trigger.t()} | :ignore | {:error, String.t()}
```

- GitHub verify: `"sha256=" <> hex(hmac_sha256(secret, raw_body))` compared with
  `Plug.Crypto.secure_compare/2`. No secret configured → `{:error, :unauthorized}` (fail closed).
- GitLab verify: `X-Gitlab-Token` `secure_compare` with the secret.
- Gitea verify: `X-Gitea-Signature` = hex(hmac_sha256(secret, raw_body)).

Parse rules:

| forge / event | accept when | Trigger fields |
|---|---|---|
| GitHub `push` | `ref` starts with `refs/heads/`, `deleted != true` | branch, sha = `after`, clone_url = `repository.clone_url`, cause `:push`, sender = `sender.login` |
| GitHub `pull_request` | `action` in opened/synchronize/reopened/ready_for_review | branch = `pull_request.head.ref`, sha = `head.sha`, base_branch = `base.ref`, pr_number, cause `:pull_request` |
| GitLab `Push Hook` | `ref` heads and `after` not all zeros | branch, sha = `after`, clone_url = `project.git_http_url` |
| GitLab `Merge Request Hook` | `object_attributes.action` in open/update/reopen | branch = `source_branch`, sha = `last_commit.id`, base = `target_branch`, pr_number = `iid` |
| Gitea `push` | as GitHub | as GitHub |
| Gitea `pull_request` | as GitHub | as GitHub |

Everything else → `:ignore`. Missing required fields → `{:error, "missing <path>"}`.

### `TinyCI.Server.Trigger`

```elixir
defstruct provider: nil, clone_url: nil, repo_full_name: nil, ref: nil, branch: nil, sha: nil,
          base_branch: nil, pr_number: nil, cause: nil, sender: nil, url: nil, received_at: nil
```

`RunRequest.from_trigger(repo, trigger)`: `repo`, `sha`, `branch`, `base_ref` (=`base_branch`
for PRs, else `nil` so detection in the workspace uses the repo's default branch — M5-01
refines), `cause`, `pipeline: repo.pipeline`, `project_id: repo.id`,
`meta: %{pr_number, sender, url, repo_name}`.

### Poller

One `TinyCI.Server.Poller` GenServer per repo with `poll_interval_ms > 0`, under a
`DynamicSupervisor` started by M2-07. Every interval: `git ls-remote --heads <url>` → map of
branch → sha; compare with the persisted last-seen map at `<data_dir>/poll/<repo_id>.json`;
for each changed or new branch, enqueue a `Trigger{cause: :poll}`; persist. On first start
with no persisted state, record heads **without** triggering (`poll_initial: false` default).
Deleted branches are just dropped from the map. Failures (network) log at warning and retry
next tick.

## TDD plan

Payload fixtures go in `tiny_ci_server/test/fixtures/webhooks/<forge>_<event>.json` — minimal
but real-shaped documents containing every field the parser reads; write them from the current
forge docs.

1. **`test/tiny_ci/server/forge/github_test.exs`** (and gitlab/gitea) — `parse/2` for each
   accepted fixture yields the expected `Trigger`; tag pushes, branch deletions, closed PRs →
   `:ignore`; a payload missing `after` → `{:error, _}`; `verify/3` accepts a correctly signed
   body and rejects a tampered body, a wrong secret, a missing header, and a nil secret.
   → implement the three forges.
2. **`test/tiny_ci/server/web/router_test.exs`** (Plug.Test) — `/healthz` 200; signed GitHub
   push for a configured repo → 202 and `Scheduler.queue/0` has one entry with the right sha;
   unsigned → 401; unknown repo → 404; ping → 200; ignored event → 200 with `"ignored"`;
   malformed JSON → 400. Configure repos through the scheduler/app config the test sets up.
   → implement router, body reader, matching.
3. **`test/tiny_ci/server/poller_test.exs`** — fixture origin repo; poller with 50 ms interval
   and `poll_initial: false` enqueues nothing at start; after a commit to the origin, a
   `:poll` trigger for that branch is enqueued (wait on the bus, deadline 2 s); the persisted
   file holds the new sha; a second identical tick enqueues nothing. → implement.
4. Start Bandit on an ephemeral port in one test and `curl`/`Req` a real request to prove the
   endpoint wiring (not just `Plug.Test`).
5. Suites, credo, dogfood.

## Acceptance criteria

- [ ] Signed webhooks from all three forges enqueue runs; unsigned or mis-signed are rejected 401.
- [ ] Unknown repositories are 404; ignored events are 200 and say why.
- [ ] Poller detects new commits without webhooks and never triggers a stampede on first start.
- [ ] Every accepted trigger carries sha, branch, base branch (PRs), cause, and sender.

## Pitfalls

- Verify **after** reading the raw body and **before** trusting anything in the JSON; but match
  the repo first (from the parsed payload) to pick the secret — parsing an unverified body is
  fine because parsing is pure.
- `Plug.Parsers` consumes the body; without the custom body reader the raw bytes are gone.
- GitHub sends `pull_request` events for forks with `head.repo.clone_url` different from the
  base repo — run **base** repo's pipeline against the head sha only if the head repo is the
  same repo (no fork builds in M2; document; follow-up).
- `git ls-remote` needs credentials for private repos; same expectation as M2-02.

## Docs

- `docs/server.md`: "Triggers" section with the webhook URLs, headers, per-forge setup steps,
  and the poller.

## Follow-ups

- Fork PR builds with a trust policy.
- Bitbucket.
