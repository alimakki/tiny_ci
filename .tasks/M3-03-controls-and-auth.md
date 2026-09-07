# M3-03 — Cancel / re-run / breakpoint controls; login

**Milestone:** M3 · **Size:** M · **Depends on:** M3-02 · **Status:** ⬜ Not started
**Written against:** the M2/M3 design; re-read before starting

> Detail level: design. Expand the TDD plan against the real code when M3 opens.

## Summary

Make the UI operational: cancel a run, re-run a commit, and drive breakpoints (`continue`,
`skip`, `retry`, `abort`, `set KEY VALUE`) from the browser; and put a login in front of it
because the server will be reachable on a network.

## In scope

- Controls call the same functions the API uses (`TinyCI.Server.Runs.cancel/2`,
  `Scheduler.enqueue/1` with `cause: :manual` and `meta.rerun_of`, `TinyCI.Control.resume/3`
  through the run's control server, addressable by `run_id` via `TinyCI.Control.Registry`).
  A run started from the UI with breakpoints armed needs the request to carry `control:`
  options; add `control` to `RunRequest`.
- Auth: a single shared password or the API token, configured in `tiny_ci.server.exs`
  (`ui_auth: {:password, {:secret, "TINY_CI_UI_PASSWORD"}} | :api_token | :none`), session
  cookie via `Plug.Session` with a signed cookie store keyed from `api_token`/a generated
  `secret_key_base` persisted in the data dir. `:none` is only allowed when `bind` is a
  loopback address; `serve --check` enforces that.
- Every control action is recorded: the executor already emits `breakpoint_resumed` and
  `run_diverged`; cancel and re-run go through the server, which broadcasts status. Add the
  acting user (`"ui"` for now) to the reason strings.

## Out of scope

- Multi-user accounts, SSO, roles. The seam is the auth plug; follow-up.

## Acceptance criteria

- [ ] Cancel from the UI ends the run `cancelled` and leaves no OS process (reuse the M2-01 test).
- [ ] Re-run enqueues a manual run for the same repo and sha with `rerun_of` set and shows it.
- [ ] Breakpoint controls resume a paused run; `set` marks it divergent in the UI.
- [ ] Unauthenticated requests to any page or control redirect to login; the API stays token-only.
- [ ] `ui_auth: :none` on a non-loopback bind is rejected by `serve --check`.
