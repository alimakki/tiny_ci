# M3-01 — `tiny_ci_web`: Phoenix LiveView app in the release; run list; PubSub bridge

**Milestone:** M3 · **Size:** L · **Depends on:** M2-07 · **Status:** ⬜ Not started
**Written against:** the M2 design; re-read `tiny_ci_server` before starting

> Detail level: design. Expand the TDD plan against the real code when M3 opens.

## Summary

The first UI: a Phoenix LiveView application shipped inside the same binary, showing the
repositories, the queue, and a live-updating run list. It is a **pure consumer** of the event
bus and the runs store and a **thin sender** of API-equivalent commands. No database.

## In scope

- Sibling project `tiny_ci_web/` (`mix phx.new --no-ecto --no-mailer --no-dashboard --live`),
  depending on `tiny_ci` and `tiny_ci_server`; added to `tiny_ci_dist`.
- `Phoenix.PubSub` bridge: a process subscribed to `TinyCI.Server.EventBus` `:runs` topic that
  re-broadcasts on `"runs"` and `"run:<id>"` PubSub topics (so LiveViews use standard
  `Phoenix.PubSub.subscribe/2`).
- Pages: `/` (repos + queue + recent runs, live), `/repos/:name` (that repo's runs).
- The web endpoint mounts under the same Bandit listener as the API (one port): the server's
  `Web.Router` forwards non-`/api` paths to the Phoenix endpoint, or the Phoenix endpoint hosts
  `/api` via `forward` — pick one and document; one port is the requirement.
- Assets built at release time (esbuild/tailwind via the Phoenix defaults; no Node required).

## Out of scope

- Run detail (M3-02), controls and auth (M3-03).

## Design notes

- Runs are folded with `TinyCI.Runs.Projection` on the server side; the LiveView holds a
  projection per visible run and applies `{:tiny_ci_event, ...}` messages to it. No parallel
  data model in the UI.
- Initial page load reads `TinyCI.Runs.list/2` per repo (meta.json), then subscribes; handle
  the gap by re-reading after subscribing (events for a run that finished between the two
  steps are covered by the re-read).
- Keep `tiny_ci_web` free of business logic; it calls `TinyCI.Server.*` and `TinyCI.Runs.*`.
- Theme: system light/dark; keep it plain. This is an operator tool.

## Acceptance criteria

- [ ] The release binary serves the UI and the API on one port with no external services.
- [ ] The run list updates live as runs are queued, start, and finish.
- [ ] The repo page shows history from the runs store and live runs together.
- [ ] `tiny_ci_web` has LiveView tests for both pages using `Phoenix.LiveViewTest`.
- [ ] Core `mix.exs` still depends only on `jason` at runtime.

## Docs

- `docs/server.md`: "Web UI" section; `docs/web.md` if it grows.
