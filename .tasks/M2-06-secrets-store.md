# M2-06 — Encrypted-at-rest secrets store

**Milestone:** M2 · **Size:** M · **Depends on:** M0-03 · **Status:** ⬜ Not started
**Written against:** commit `b9496e7` (2026-08-08), assuming M0-03 landed

## Summary

Runs need credentials, and a server cannot read them from a developer's shell. This task adds
a small encrypted file store to `tiny_ci_server`, a CLI to manage it, and wiring so a run's
`secret` declarations (M0-03) resolve from the store — repo scope over global scope — while
the server's own process environment is **not** exposed to runs by default.

## In scope

- `TinyCI.Server.Secrets.Store` GenServer and `TinyCI.Server.Secrets.Crypto`.
- Master key handling: `TINY_CI_MASTER_KEY` (base64, 32 bytes) or `<data_dir>/master.key`.
- CLI `tiny_ci secrets init|set|rm|list` registered via the subcommand registry.
- `Run` resolves `spec.secrets` with `provider: Store.resolve_for(repo_id, names)` and
  `env: %{}` unless `allow_env_secrets: true`.
- Forge tokens (`{:secret, name}` in repo config, M2-05) resolve through the store.

## Out of scope

- External secret managers (Vault, SOPS, cloud KMS). The provider map is the seam; follow-up.
- Rotation UX beyond "set again".

## Read first

- `lib/tiny_ci/secrets.ex` (M0-03) — `resolve/2` and its `provider:` option.
- `lib/tiny_ci/redaction.ex` — the values a run receives are masked automatically once they
  are on the context; nothing to do here beyond passing them.
- `lib/tiny_ci/server/run.ex` — `handle_continue(:start)`.
- Erlang `:crypto.crypto_one_time_aead/6` docs (AES-256-GCM).

## Design

### File format

`<data_dir>/secrets.enc`, mode `0600`:

```
"TCS1" <> iv(12 bytes) <> tag(16 bytes) <> ciphertext
```

Plaintext is JSON: `{"version": 1, "scopes": {"global": {"NAME": "value"}, "repo:<id>": {...}}}`.
AAD is the 4-byte magic. Writes go to `secrets.enc.tmp` then `File.rename/2`; the temp file is
created with `0600` before any bytes are written (`File.open!/2` with `[:write, :binary]` then
`File.chmod!/2` immediately — or `:file.open` with `{:mode, 0o600}` is not available; chmod
right after open is acceptable because the file is empty at that point).

### Key

`TINY_CI_MASTER_KEY` (base64 of 32 random bytes) wins; else `<data_dir>/master.key` (raw
base64 text, `0600`). `tiny_ci secrets init` creates the key file if neither exists and prints
where. A key file with permissions broader than `0600` is refused at startup with a clear
message. Wrong key → decrypt fails → the store refuses to start (never silently empty).

### Store API

```elixir
start_link(data_dir: path, key: binary | nil)          # key resolved by the caller from env/file
get(scope, name) :: {:ok, value} | :error
put(scope, name, value) :: :ok
delete(scope, name) :: :ok
list(scope) :: [name]                                 # names only, sorted
resolve_for(repo_id, names) :: %{name => value}       # repo scope overrides global; missing names absent
scope :: :global | {:repo, repo_id}
```

Decrypted content lives only in the GenServer's state. `inspect/1` of the state must not show
values: implement `Inspect` for the state struct or store values in a map wrapped in a struct
with a custom inspect that prints `#Secrets<n entries>`.

### CLI

```
tiny_ci secrets init [--data-dir D]
tiny_ci secrets set NAME [--repo REPO_NAME] [--from-env VAR]   # value from stdin unless --from-env
tiny_ci secrets rm NAME [--repo REPO_NAME]
tiny_ci secrets list [--repo REPO_NAME]
```

Runs against the data dir from the server config (M2-07) or `--data-dir`. Reads stdin with
`IO.read(:stdio, :eof)` and trims one trailing newline. Never echoes values.

### Run wiring

In `Run.handle_continue(:start)` after loading the spec:

```elixir
provider = Store.resolve_for(request.project_id, spec.secrets)
env = if config.allow_env_secrets, do: System.get_env(), else: %{}
case TinyCI.Secrets.resolve(spec.secrets, provider: provider, env: env, root: root) do
  {:ok, values} -> ... run with secrets: values
  {:error, {:missing_secrets, names}} -> status :failed, reason "missing secrets: ..."
end
```

The `.tiny_ci/secrets` file inside a workspace is still consulted by `resolve/2` (it reads
`root`); that is acceptable and useful for per-repo non-sensitive defaults, and it is
documented.

## TDD plan

1. **`test/tiny_ci/server/secrets/crypto_test.exs`** — encrypt/decrypt roundtrip; tampering
   one ciphertext byte fails; wrong key fails; magic header present. → implement `Crypto`.
2. **`test/tiny_ci/server/secrets/store_test.exs`** (`@tag :tmp_dir`) — `put/get/list/delete`;
   scope precedence in `resolve_for/2`; file mode is `0600` after a write; restart with the same
   key sees the data; restart with a different key fails to start; `inspect(state)` contains
   no value. → implement `Store`.
3. **`test/tiny_ci/server/secrets/cli_test.exs`** — `set` from stdin (use a `StringIO` as
   `:stdio` via `Process.group_leader/2` or an injectable reader), `list` shows the name only,
   `rm` removes; `init` creates a `0600` key file. → implement CLI.
4. **`test/tiny_ci/server/run_test.exs`** — a pipeline declaring `secret :TOKEN` with the value
   in the store: the step `echo $TOKEN` output in the recorded events is `***`; without the
   value the run fails with "missing secrets"; with the value only in the server's env and
   `allow_env_secrets: false` it also fails. → wire.
5. Suites, credo, dogfood.

## Acceptance criteria

- [ ] Secrets are AES-256-GCM encrypted at rest with an authenticated header; tampering is detected.
- [ ] Key comes from env or a `0600` key file; loose permissions are refused.
- [ ] Repo scope overrides global; runs receive only the secrets they declare.
- [ ] The server's environment is not exposed to runs unless explicitly enabled.
- [ ] CLI manages secrets without ever printing a value.

## Pitfalls

- `:crypto.strong_rand_bytes/1` for IVs; never reuse an IV with the same key (fresh per write).
- Base64 decoding of the key must check the decoded length is exactly 32 bytes.
- Do not log the store state anywhere; add a `Logger` metadata filter test if in doubt.

## Docs

- `docs/server.md`: "Secrets" section — key management, scopes, CLI, what is and is not exposed.

## Follow-ups

- Vault/SOPS/KMS providers behind the provider map.
