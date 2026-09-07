# M7-02 — Lockfile, attestation, and registry surfaced in the UI; server runs attested

**Milestone:** M7 · **Size:** M · **Depends on:** M3-02 · **Status:** ⬜ Not started

> Detail level: design. Expand when M7 opens.

## Summary

T06 (lockfile), T07 (attestation), and T09 (registry) exist as Mix tasks. Give them a place in
the product: the server attests every non-divergent run it executes (signing key from the
secrets store), the run page shows the attestation and the resolved action versions, and the
registry search is available from the UI when a pipeline uses third-party actions.

## Design notes

- `RunRequest`/`Run`: when the server has a signing key configured, attach the provenance
  collector sink (already an `EventSink`) and write `attestation.json` into the run dir; expose
  it at `/api/runs/:id/attestation` and link it from the run page.
- The lockfile audit (`tiny_ci actions audit`) runs as a pre-step on server runs and its
  findings are shown as warnings on the run page.
- Registry search: read-only page over `TinyCI.Registry.Index`.

## Acceptance criteria

- [ ] Every passed/failed non-divergent server run has a verifiable attestation downloadable
      from the API and the UI.
- [ ] The run page lists third-party actions with their locked versions and audit findings.
