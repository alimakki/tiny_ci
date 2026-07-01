# Provenance & attestation

Every run can emit a **signed attestation** of exactly what it did: which pipeline
ran, on which commit, which steps executed with what outcome and duration, and
which actions ran at which pinned versions/checksums. The document is
tamper-evident — any modification breaks its signature — giving you a verifiable,
[SLSA](https://slsa.dev)/[in-toto](https://in-toto.io)-style record of a run.

## Producing an attestation

```bash
# one-time: generate a signing keypair
mix tiny_ci.attest.gen_key --out ci_key        # → ci_key (private), ci_key.pub (public)

# run and attest
mix tiny_ci.run --attest run.att.json --signing-key ci_key
```

The private key can also come from the `TINY_CI_SIGNING_KEY` environment variable
(base64), so `--signing-key` isn't needed in CI where the key is a secret:

```bash
export TINY_CI_SIGNING_KEY="$(cat ci_key)"
mix tiny_ci.run --attest run.att.json
```

An attestation is written whether the run **passes or fails** — provenance of a
failed run is just as useful. A failed run still exits non-zero; if `--attest` is
given but no signing key is available, the command fails with a clear message.

## Verifying

```bash
mix tiny_ci.attest.verify run.att.json --key ci_key.pub
```

Prints the pipeline, run id, commit, and outcome on success (exit `0`); on any
tampering, a bad signature, or the wrong key it fails (exit `1`). Because the
signature covers the payload, editing the recorded steps, outcome, or action
checksums invalidates the attestation.

## What's inside

The attestation is a **DSSE-style envelope** wrapping an in-toto Statement:

```json
{
  "payloadType": "application/vnd.tiny_ci.provenance+json",
  "payload": "<base64 of the statement below>",
  "signatures": [{ "keyid": "<sha256 of pubkey>", "algo": "ed25519", "sig": "<base64>" }]
}
```

The decoded payload:

```json
{
  "_type": "https://in-toto.io/Statement/v1",
  "predicateType": "https://tiny-ci.dev/provenance/v0.1",
  "subject": [{ "name": "release", "digest": { "gitCommit": "<sha>" } }],
  "predicate": {
    "runId": "…", "pipeline": "release", "branch": "main", "commit": "<sha>",
    "outcome": "success",
    "startedAt": "…", "finishedAt": "…",
    "builder": { "tool": "tiny_ci", "version": "0.1.0" },
    "actions": [
      { "module": "Acme.Deploy", "app": "acme", "version": "1.2.0",
        "checksum": "…", "source": "hex",
        "steps": [{ "stage": "deploy", "step": "ship" }] }
    ],
    "steps": [
      { "stage": "build", "step": "compile", "status": "passed", "durationMs": 1200, "action": null },
      { "stage": "deploy", "step": "ship", "status": "passed", "durationMs": 5678, "action": "Acme.Deploy" }
    ]
  }
}
```

## How it stays honest

- **"What ran" comes from the [event stream](events.md)**, not from executor
  internals. The run's events are collected (`TinyCI.Provenance.Collector`) and
  folded into the statement (`TinyCI.Provenance.build/1`), so the record reflects
  observed execution — the run id, per-step status/duration, and outcome all come
  from emitted events.
- **Action versions and checksums come from the [lockfile](actions.md#supply-chain-action-resolution--the-lockfile)**
  (T6 resolution) — the attestation ties each executed action to the exact pinned
  package, closing the loop between "what was locked" and "what ran".
- **Only executed actions are listed.** A step skipped by a `when:` condition is
  recorded with `"status": "skipped"` and contributes no action.

## Signing backends

Signing is pluggable via the `TinyCI.Provenance.Signer` behaviour. The default
(`TinyCI.Provenance.Signer.LocalKey`) uses a local **Ed25519** keypair via
`:crypto`. An organisation can implement the behaviour to sign with cosign/
sigstore, a KMS, or an HSM without changing the envelope format.
