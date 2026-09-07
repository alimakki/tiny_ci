# T7 — Action provenance / attestation

**Phase:** 2 — Supply chain · **Complexity:** M–L · **Depends on:** T2, T6, T1 · **Status:** ✅ Done

## Summary

Each run emits a signed attestation of exactly which action versions (by hash)
executed — a verifiable, tamper-evident record (SLSA / in-toto style).

## Implementation checklist

- [x] At run end, build a provenance document: run_id, commit, resolved action graph
      (name+version+checksum from T6), step→action mapping, per-step outcome + duration.
      → `TinyCI.Provenance.build/1` (in-toto Statement).
- [x] Source "what ran" from the **T1 event stream** (don't re-derive from internals).
      → `TinyCI.Provenance.Collector` sink (via executor `:extra_sinks`); run_id,
      per-step status/duration, and outcome all read from collected events.
- [x] Align the document schema with in-toto/SLSA predicate where practical.
      → in-toto Statement v1 + a `tiny-ci.dev/provenance/v0.1` predicate.
- [x] Sign it (default local keypair; cosign/sigstore optional).
      → `TinyCI.Provenance.Signer` behaviour + `Signer.LocalKey` (Ed25519 via `:crypto`);
      DSSE-style envelope in `TinyCI.Provenance.Attestation`. (Used `:crypto` EdDSA
      rather than `:public_key` — smaller, deterministic, pub derivable from the seed.)
- [x] `mix tiny_ci.run --attest out.json` produces the document (`--signing-key` or
      `TINY_CI_SIGNING_KEY`).
- [x] `mix tiny_ci.attest.verify out.json --key …` validates it; fails if modified.
- [x] Keep signing pluggable (local keypair v1; behaviour seam for cosign/sigstore).
      Plus `mix tiny_ci.attest.gen_key` to create keypairs.

## Acceptance criteria

- [x] `--attest out.json` produces a document conforming to a documented schema
      (`docs/provenance.md`).
- [x] Enumerates every executed action with locked checksum + the steps that used it,
      plus per-step outcome and duration (from T1). Skipped steps contribute no action.
- [x] Document is signed; verify command validates it.
- [x] Verification fails if the document is modified (signature covers the DSSE PAE).

## Implementation notes

- Signature covers the DSSE **PAE** (pre-authentication encoding) of payload type +
  bytes, so re-serialization can't change what's signed and any payload edit fails.
- `:extra_sinks` added to the executor is a general, minimal seam — the collector is
  just another `TinyCI.EventSink`; core stays lean and the LSP is untouched.
- The attestation is written for both passing and failing runs; a pipeline failure
  dominates the exit code, but a missing signing key surfaces as an error.
