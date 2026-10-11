# Installing tiny_ci

The standalone `tiny_ci` binary is a single self-contained executable per
platform: it bundles Erlang/OTP, so the machine it runs on needs no Erlang,
Elixir, or Mix. This page covers downloading a release, verifying it, and the
alternatives for people who already have an Elixir toolchain.

## Download

Pick the row for your OS and architecture and download the asset from the latest
GitHub release:

| OS | Architecture | Asset |
|----|--------------|-------|
| macOS | Apple Silicon (arm64) | [`tiny_ci_macos_arm64`](https://github.com/alimakki/tiny_ci/releases/latest/download/tiny_ci_macos_arm64) |
| macOS | Intel (x86_64) | [`tiny_ci_macos_x86_64`](https://github.com/alimakki/tiny_ci/releases/latest/download/tiny_ci_macos_x86_64) |
| Linux | x86_64 | [`tiny_ci_linux_x86_64`](https://github.com/alimakki/tiny_ci/releases/latest/download/tiny_ci_linux_x86_64) |
| Linux | arm64 (aarch64) | [`tiny_ci_linux_arm64`](https://github.com/alimakki/tiny_ci/releases/latest/download/tiny_ci_linux_arm64) |

For example, on Linux x86_64 (keep the asset's name — the checksum file refers
to it by that name):

```bash
curl -fsSLO \
  https://github.com/alimakki/tiny_ci/releases/latest/download/tiny_ci_linux_x86_64
```

The asset name encodes the target (`tiny_ci_<os>_<arch>`); the download URL
pattern is
`https://github.com/alimakki/tiny_ci/releases/latest/download/tiny_ci_<os>_<arch>`.

## Verify the download

Every release publishes a `SHA256SUMS` file next to the binaries. Verify before
installing, while the downloaded file still has its asset name:

```bash
curl -fsSLO \
  https://github.com/alimakki/tiny_ci/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing
```

On macOS use `shasum -a 256 -c SHA256SUMS --ignore-missing` instead.
`--ignore-missing` lets one checksum file cover all four assets when you only
downloaded one; the file you did download must keep its asset name or the check
reports `no file was verified`.

## Install

Then put it on your `PATH`:

```bash
chmod +x tiny_ci_linux_x86_64
sudo mv tiny_ci_linux_x86_64 /usr/local/bin/tiny_ci
tiny_ci version
```

## macOS: Gatekeeper

The macOS binaries are not signed or notarised, so Gatekeeper quarantines them
on first launch. After downloading, clear the quarantine flag:

```bash
xattr -d com.apple.quarantine tiny_ci
```

Code signing and notarisation are a planned follow-up.

## First run

On first launch the binary unpacks its bundled Erlang runtime into a per-user
cache directory (about a second); later launches reuse it and start
immediately. The base directory is `.burrito` under the usual per-user data
location, with one versioned subdirectory per release:

- macOS — `~/Library/Application Support/.burrito`
- Linux — `$XDG_DATA_HOME/.burrito` (or `~/.local/share/.burrito`)

Burrito's maintenance commands manage that directory:

```bash
tiny_ci maintenance directory   # print the unpacked payload's location
tiny_ci maintenance uninstall   # remove the unpacked payload
tiny_ci maintenance meta        # print the binary's build metadata
```

Set `TINY_CI_INSTALL_DIR` to use a different base directory (for example on a
machine where the default data directory is not writable); the binary still
creates its `.burrito/<version>` subdirectory under it.

## Alternatives

If you already have an Elixir toolchain, you do not need the standalone binary:

- **Install the escript** with Mix — it needs Erlang/OTP installed but not a
  checkout of the repo:

  ```bash
  mix escript.install github alimakki/tiny_ci
  tiny_ci version
  ```

- **Run inside an Elixir project** with the Mix task, which also gives access to
  `module:` steps (they load Elixir modules from your project's code path):

  ```bash
  mix tiny_ci.run
  ```

## Building a release yourself

From a checkout, with the versions pinned in `.mise.toml` and Zig 0.16.0 on the
`PATH`:

```bash
cd tiny_ci_dist
mix deps.get
MIX_ENV=prod mix release --overwrite
# -> tiny_ci_dist/burrito_out/tiny_ci_<os>_<arch>
```

All four targets cross-build from one Linux host (Burrito downloads a prebuilt
ERTS per target). To build a single target, set `BURRITO_TARGET` to one of
`macos_arm64`, `macos_x86_64`, `linux_x86_64`, or `linux_arm64`:

```bash
BURRITO_TARGET=linux_x86_64 mix tiny_ci.run release
```

That pipeline (`.tiny_ci/release.exs`) builds and smoke-tests the binary the
same way the release workflow does.
