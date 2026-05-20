# v1.1.0 GA — P1 Audit: Linux Parity Gap

> **Phase:** P1 (Repo audit — foundational)
> **Receives:** P5 / P6 (Linux Ubuntu 22.04 first-class, B5 in ExecPlan)
> **Method:** static grep over `crates/*/src/**/*.rs` for `target_os = "linux"` / `target_os = "macos"` / hard-coded macOS paths.

---

## 1. Summary counts

| Pattern | Hits | Where |
|---|---|---|
| `#[cfg(target_os = "linux")]` | **1** | `crates/stealth-auth/src/bin/rev_auth.rs:474` |
| `#[cfg(target_os = "macos")]` | **3** | `crates/stealth-auth/src/bin/rev_auth.rs:467, 524, 971` |
| Hard-coded `/Applications/...` paths | **3** | `crates/stealth-auth/src/bin/rev_auth.rs:469, 470, 471` |

All OS-specific code in the entire workspace lives in a **single file**: `crates/stealth-auth/src/bin/rev_auth.rs`. No other crate uses `target_os` cfg gates.

## 2. Detail — what each block does

### 2a. Chrome binary discovery — `standard_chrome_paths()` (L465-486)

- **macOS branch** (L467-472): hard-coded list of 3 absolute paths:
  - `/Applications/Google Chrome.app/Contents/MacOS/Google Chrome`
  - `/Applications/Google Chrome Canary.app/Contents/MacOS/Google Chrome Canary`
  - `/Applications/Chromium.app/Contents/MacOS/Chromium`
- **Linux branch** (L474-484): `$PATH` lookup via `find_in_path` for: `google-chrome`, `google-chrome-stable`, `chromium-browser`, `chromium`. ✅ already implemented.

> Both arms have parity. Linux relies on `PATH`, macOS on absolute `.app` paths. Override available everywhere via `--chrome-bin` / `REV_AUTH_CHROME_BIN`.

### 2b. macOS-only env injection — `build_chrome_config_with_vpn` (L524-527)

```rust
#[cfg(target_os = "macos")]
{
    builder = builder.env("CFFIXED_USER_HOME", user_data_dir.display().to_string());
}
```

`CFFIXED_USER_HOME` is a CoreFoundation env var to redirect Chrome's `~/Library` writes onto the throwaway profile dir. **No Linux equivalent needed** — Chrome on Linux already respects `--user-data-dir` for all writes. ✅ correct asymmetry.

### 2c. macOS-only unit test (L971-989)

`chrome_binary_resolves_from_macos_standard_paths` — gated `#[cfg(target_os = "macos")]`. **Linux has no symmetric test** for `find_in_path` resolution. P5 should add one (`chrome_binary_resolves_from_linux_path`).

## 3. Implicit (non-grepped) Linux gaps

The grep covers only `crates/`. The following Linux-specific concerns must be **manually verified** by P5/P6 (not visible via `target_os` grep):

| Area | v1.0.0-dev status | Linux gap |
|---|---|---|
| `keyring` v3 backend | Configured for whichever backend the OS provides; on Ubuntu this is **libsecret + dbus**. | P5: confirm CI installs `libsecret-1-dev` (build-time) and `gnome-keyring` or `secret-tool` daemon (run-time). Fallback to file-encrypted profile already exists (Phase 9). |
| Docker / Gluetun (`vpn-rotate`, `bollard`) | macOS dev uses Docker Desktop; Linux uses native dockerd. | P5: confirm CI image has docker-in-docker available (or skip `bollard` integration tests on Linux PR runners). |
| `tun/tap` for native WARP | Phase 6 added VPN-required guard; native WARP currently macOS-leaning. | P5/P6: verify Cloudflare WARP Linux package handling, or document Gluetun-only on Linux. |
| `/dev/shm` Chrome sandbox | Chrome flag `--disable-dev-shm-usage` may be needed for CI containers with small shm. | P5: confirm flag already passed (search `obscura-bridge` Chrome args + `rev_auth` builder). |
| `dirs` v5 crate's `home_dir` | Behaves correctly on both platforms; just FYI. | none |
| `chromiumoxide 0.9` | works on both. | none |
| `~/.rev_scraping/` permissions (mode 0700, files 0600) | Works on Linux + macOS POSIX. | none |
| README §13 VPN setup | macOS-centric examples in places. | P5/B7 doc: add Linux-equivalent commands. |

## 4. Recommended P5/P6 deliverables (informational, not P1's scope)

1. Add `chrome_binary_resolves_from_linux_path` symmetric unit test.
2. Verify Chrome `--disable-dev-shm-usage` is set everywhere a sandboxed run might land in a small-shm container (CI / Docker).
3. CI matrix entry: `ubuntu-22.04 × {1.83, stable}` with `apt-get install -y libsecret-1-dev libdbus-1-dev` in setup.
4. Document keyring fallback path for headless Linux CI (no dbus session) — see `stealth-auth` file-encrypted profile mode.
5. Re-grep at end of P5 to confirm no new macOS hard-codes added by other sub-phases.

## 5. P1 verdict

Linux gap is **small and localized**. v1.0.0-dev already wrote the Chrome-path discovery with Linux symmetry. The remaining work is mostly CI plumbing, doc text, and one symmetric unit test — none of which blocks P5/P6 from running in parallel with P10/P2/P3.
