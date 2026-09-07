# M4-04 — TLS distribution; documented threat model; authenticated protocol (later)

**Milestone:** M4 · **Size:** M · **Depends on:** M4-01 · **Status:** ⬜ Not started

> Detail level: design. Expand when M4 opens.

## Summary

Distributed Erlang's cookie is not authentication and its default transport is plaintext. Before
anyone runs a runner outside a trusted network, ship TLS distribution with mutual certificate
verification, a `tiny_ci certs` helper to generate a CA and node certificates, and a written
threat model. An authenticated non-distribution protocol (WebSocket + token) for hostile
networks is the follow-on and is explicitly deferred.

## Design notes

- `-proto_dist inet_tls -ssl_dist_optfile <file>` in the release `vm.args` when
  `distribution: :tls` is configured; the optfile lists server/client certs, CA, `verify_peer`,
  `fail_if_no_peer_cert`.
- `tiny_ci certs init` (CA), `tiny_ci certs issue --node NAME` — using `:public_key`; no
  OpenSSL dependency.
- Threat model document: what the cookie is and is not; that any connected node can run
  arbitrary code on any other node (this is inherent to distribution) — hence TLS with mutual
  auth **and** network isolation are both required; what M4-04 does not protect against.
- Test with `:peer` nodes started with the TLS options.

## Acceptance criteria

- [ ] Runners connect over TLS with mutual verification; a node with an unsigned cert is rejected.
- [ ] `tiny_ci certs` produces working material without external tools.
- [ ] `docs/security.md` states the threat model plainly.
