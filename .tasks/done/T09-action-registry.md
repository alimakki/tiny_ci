# T9 — Curated action registry / index

**Phase:** 2 — Supply chain · **Complexity:** M · **Depends on:** T2, T6 · **Status:** ✅ Done

## Summary

A discoverable, curated index of well-made, locked, typed actions — "small,
curated, verifiable," the opposite of GHA's vast unaudited marketplace. The index
is metadata over Hex packages (T6).

## Implementation checklist

- [x] Index format: which Hex packages are "tiny_ci actions," their declared
      capabilities, inputs, and a quality/review tier. (`TinyCI.Registry.Entry` +
      `Index` JSON: `{"actions": [{package, version, module, name, summary,
      capabilities, inputs, tier}]}`.)
- [x] Action package self-identifies (package metadata marker + `TinyCI.Action`
      metadata) so the index builds programmatically. (Marker: `:tiny_ci_actions`
      application env listing action modules; scanner reads it + `metadata/0`.)
- [x] `mix tiny_ci.actions.search <term>` lists matches with version, capabilities, tier.
- [x] Each indexed action surfaces declared capabilities (from T2) — blast radius visible.
- [x] Documented submission/review checklist defining "curated/verified."
- [x] v1: generated static index (JSON) — `mix tiny_ci.actions.index` scans
      installed packages for the marker (no network; Hex-wide scan is the future
      extension over the same marker).

## Acceptance criteria

- [x] Action package self-identifies so the index can be built programmatically.
- [x] `mix tiny_ci.actions.search <term>` lists matching actions w/ version,
      capabilities, review tier.
- [x] Each indexed action surfaces declared capabilities.
- [x] Documented review checklist (source available, minimal capabilities, tests
      present, no undeclared network/filesystem use).

## Implementation notes

- Avoid building a bespoke registry service before there's demand — static JSON index v1.
- **Self-identification marker:** application env `:tiny_ci_actions` (a list of
  action modules), read from the compiled `.app` — discoverable from installed
  deps with no network and no separate manifest. Combined with each module's
  `TinyCI.Action.metadata/0` (name/version/inputs/capabilities) and its
  `@moduledoc` first line (summary). Version prefers the real installed app vsn,
  falling back to the declared metadata version.
- **Modules** (mirroring Audit/Resolver/Lockfile): `TinyCI.Registry.Entry` (struct
  + JSON `to_map`/`from_map`, pure), `TinyCI.Registry.Index` (pure: `new`,
  `search` with term + `:capability`/`:tier` filters, `merge` tier-overlay,
  `to_json`/`from_json`), `TinyCI.Registry` (I/O facade: `action_modules/1`,
  `scan/1`, `load/1`, `search/2`).
- **Tiers** are editorial: a scan yields `:unreviewed`; curated
  `:verified`/`:community` tiers live in a checked-in overlay index that
  `Index.merge/2` layers on top (live version/caps from the scan win, tier from
  the overlay; overlay-only entries are kept).
- **Tasks:** `mix tiny_ci.actions.search TERM [--index PATH] [--capability C]
  [--tier T]`; `mix tiny_ci.actions.index [--out PATH] [--overlay PATH]`.
- Registry is purely additive metadata — never runs actions, never touches
  executor internals (invariants #1/#3). Docs: `docs/action-registry.md`.
- Added `test/support` (via `elixirc_paths(:test)`) for shared action fixtures.
