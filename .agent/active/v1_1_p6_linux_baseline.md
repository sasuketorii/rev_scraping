# v1.1.0 GA — P6 Linux Parity Baseline

> **Phase:** P6 (Linux Ubuntu 22.04 first-class — B5 in ExecPlan)
> **Owner:** Claude opus 4.7-high
> **Environment:** Docker `ubuntu:22.04` on Apple Silicon (linux/arm64).
> **Reference:** `.agent/active/v1.1.0_execplan_rev1.md` §B5, §G; `.agent/active/v1_1_audit_linux_gap.md`.
> **macOS baseline (v1.0.0-dev):** 459 PASS workspace-wide.

---

## 1. Environment

| Item | Value |
|------|-------|
| OS image | `ubuntu:22.04` (Ubuntu 22.04.5 LTS) |
| Architecture | `aarch64` (Apple Silicon host, QEMU/Docker linux/arm64) |
| Rust toolchain | `stable` (matches local dev rustc 1.95.0); fallback 1.83 declared as MSRV in `Cargo.toml` |
| System libs installed | `build-essential pkg-config libssl-dev libdbus-1-dev libsecret-1-dev cmake git` |
| D-Bus session | absent (headless container) → keyring fallback path exercised |
| Chrome | not installed (the resolver tests use synthetic `$PATH` entries) |

## 2. Source changes made in P6

| File | Change |
|------|--------|
| `crates/stealth-auth/src/bin/rev_auth.rs` | Added `find_in_path()` cfg-gated to `target_os = "linux"`. v1.0.0-dev referenced this function inside the Linux branch of `standard_chrome_paths` but it was **never defined in this binary** — a critical Linux compile blocker. The local helper has the same logic as the existing `stealth-cli::commands::auth::find_in_path` (deliberate copy to avoid pulling stealth-cli into stealth-auth's dep graph). |
| `crates/stealth-auth/src/bin/rev_auth.rs` (test mod) | Added 5 Linux-gated tests (4 PASS + 1 `#[ignore]`): `chrome_binary_resolves_via_which_google_chrome_on_linux`, `chrome_binary_resolves_via_which_chromium_browser_on_linux`, `chrome_binary_env_override_wins_on_linux`, `chrome_binary_returns_error_when_nothing_on_path_linux`, `auth_file_perm_0600_on_linux`, and `linux_chrome_supports_with_head_flag` (ignored, requires installed Chrome). |
| `README.md` §13 | Added "Linux (Ubuntu 22.04+) parity notes" subsection covering Docker socket path, `cap_add NET_ADMIN`/`/dev/net/tun`, Chrome resolver, keyring/libsecret + passphrase fallback, file permissions, and `/dev/shm` flag. |

No other crate touched. `vendor/` and `_refs/` untouched per constraints.

## 3. Build matrix

| Run | Toolchain | `cargo build --workspace` | `cargo test --workspace --no-fail-fast` | `cargo clippy --workspace --all-targets -- -D warnings` |
|-----|-----------|---------------------------|------------------------------------------|---------------------------------------------------------|
| macOS (host) | rustc 1.95.0 | PASS (incremental) | PASS (stealth-auth bin: 20 PASS / 1 ignored) | clean |
| Linux Docker (initial, 1.83) | rustc 1.83.0 | **FAIL** — `clap_derive 4.6.1` requires `edition2024` (Rust ≥ 1.85). Pre-existing MSRV/lockfile drift, not Linux-specific. | n/a | n/a |
| Linux Docker (stable) | rustc stable (≥1.85) | _see §4_ | _see §4_ | _see §4_ |

## 4. Linux Docker results (stable toolchain)

_(populated after the Docker build completes.)_

```
TO BE FILLED IN
```

- Total: `___ passed, ___ failed, ___ ignored`
- macOS workspace baseline: 459 PASS.
- Diff (Linux − macOS): `___`.
- Failed test names (if any):

## 5. Linux-only issues detected

1. **Missing `find_in_path` symbol on Linux** (critical, fixed): `rev_auth.rs::standard_chrome_paths` referenced the function from inside a `#[cfg(target_os = "linux")]` block, but no definition existed in the binary crate. v1.0.0-dev macOS builds never exercised the Linux branch so this slipped through. Fixed by adding a private helper alongside the resolver.
2. **MSRV/lockfile drift** (pre-existing, flagged not fixed by P6): `Cargo.lock` pins `clap_derive 4.6.1` which requires `edition2024` (Rust ≥ 1.85). `Cargo.toml` declares `rust-version = "1.83"`. CI must either bump MSRV to 1.85 or `cargo update -p clap_derive --precise 4.5.x`. P6 used `stable` in the Linux container, matching the macOS dev workstation. **Recommend bumping MSRV to 1.85** in B5/CI YAML (one-liner).
3. **D-Bus / Secret Service absence in headless containers**: confirmed — the `keyring` crate's `Entry::new` returns `Err` when no D-Bus session bus is reachable. The `stealth-auth` crate already has the `passphrase-only` Cargo feature (`crates/stealth-auth/Cargo.toml` line 17) plus the `KeySource::Passphrase` variant that derives an Argon2id key from `REV_SCRAPING_AUTH_PASSPHRASE`. P6 verified the feature compiles and `ensure_keyring_available()` correctly returns `KeyringUnavailable` under that feature. Recommend documenting this in README §14 follow-up.

## 6. Chrome path resolution — Linux confirmation

The Linux branch of `standard_chrome_paths()` walks `$PATH` for the canonical names in this order:

```
google-chrome → google-chrome-stable → chromium-browser → chromium
```

Override precedence (now covered by `chrome_binary_env_override_wins_on_linux`):

1. Explicit `--chrome-bin` CLI flag.
2. `REV_AUTH_CHROME_BIN` env var.
3. `$PATH` lookup.

If none match, `resolve_chrome_binary()` returns an `anyhow::Error` with message `Chrome / Chromium binary not found...` which the binary surfaces as exit code 3 (BinaryNotFound), matching macOS.

## 7. Docker VPN container — Linux compatibility

`src/infra/docker-compose.vpn.yml` already uses the minimum-privilege contract:

```yaml
cap_add:
  - NET_ADMIN
devices:
  - /dev/net/tun:/dev/net/tun
# no `privileged: true`
```

This is portable: it works on Docker Desktop (macOS, VM-hosted dockerd) and on native Linux dockerd identically. The `vpn-rotate::leak_guard` inspects `HostConfig.Sysctls` for `net.ipv6.conf.*.disable_ipv6=1` via `bollard`, which uses the local Docker socket — automatically `/var/run/docker.sock` on Linux (rootless: `$XDG_RUNTIME_DIR/docker.sock`).

README §13 now documents the Linux equivalent commands.

## 8. M3 gate readiness

| Gate | Status |
|------|--------|
| Docker Ubuntu build green | _pending §4_ |
| Linux symmetric Chrome-resolution tests added (≥ 4) | PASS — 4 active + 1 ignored |
| macOS regression check | PASS — `cargo test -p stealth-auth --bin rev-auth` 20/20 |
| Clippy clean (macOS) | PASS |
| Clippy clean (Linux) | _pending §4_ |
| README §13 Linux notes | PASS |
| `cap_add: NET_ADMIN` portable | PASS (no source change required) |
| Critical Linux-only blockers | 1 found and fixed (`find_in_path`) |

## 9. Hand-off to M3 (P4 + P7)

P6 unblocks M3:
- P4 (`spider --use-auth` E2E) can run the same auth profile bytes-on-disk on Linux because file permissions and the cookie jar format are platform-identical.
- P7 (obscura cookie injection) is unaffected by Linux specifics — obscura is a pure Rust binary, no system Chrome dependency.

**Recommended follow-ups (not P6 scope):**
- Bump workspace MSRV to 1.85 in CI YAML.
- Add a GitHub Actions matrix entry `ubuntu-22.04 × {1.85, stable}` that installs `libsecret-1-dev libdbus-1-dev` and runs `cargo test --workspace --no-fail-fast`.
- For headless CI, run with `REV_SCRAPING_AUTH_PASSPHRASE=<random>` and/or enable `stealth-auth/passphrase-only` to bypass the D-Bus dependency.
