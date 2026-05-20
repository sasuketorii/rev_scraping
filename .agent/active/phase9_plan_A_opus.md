# Phase 9 — Authenticated Session Cookie Capture (Plan A / Opus 4.7-high)

> **Status:** Design only. No implementation files in scope.
> **Author track:** Plan A (Opus). Plan B (Codex) authored independently.
> **Predecessor phases assumed live:** 2 (AUP), 5e (stealth-cf), 6c (VPN leak guard), 7a (stealth-sites recipe), 8 (proxy routing).
> **Headline goal:** Let an agent (Codex / Claude Code) trigger a one-time human-driven login, persist the resulting session cookies encrypted-at-rest, and reuse them transparently from `spider` / `cf-evaluate` / `relocate` and from MCP tools — **without ever automating credentials, 2FA, or CAPTCHA**.

---

## 0. Executive design summary

Plan A picks a **two-tier UX** (headed `obscura` first, manual JSON import as fallback), a **dedicated new crate `stealth-auth`**, **OS-keyring-wrapped XChaCha20-Poly1305** encryption of a per-profile cookie jar JSON, and a **CDP-side cookie injector + reqwest CookieStore adapter** so existing code paths stay untouched. The auth surface is exposed as:

- CLI: `rev-stealth auth {login|list|show|delete|status|export-template}` and a `--use-auth <PROFILE>` opt-in on `spider` / `cf-evaluate` / `relocate`.
- MCP: parallel tools `auth_list / auth_login / auth_show / auth_delete / auth_status / spider_with_auth`.

Every auth path is **gated by AUP + VPN-required + SSRF guard** exactly like normal fetches, and login attempts are **rejected unless the target site is allowlisted with an explicit `auth = true` marker** so an agent cannot bait the user into logging into an unauthorized site. All cookie material is **redacted in logs, audit trail, MCP responses, and `show` output**. Implementation rolls out across **sub-phases 9a → 9g** (≈18–24 engineer-days), each independently revertible.

---

## A. UX / Startup mode evaluation

### A.1 Mode catalog

| # | Mode | Description | Where login UI runs |
|---|------|-------------|---------------------|
| 1 | **Headed `obscura`** (recommended primary) | Reuse existing `stealth-core::browser` (chromiumoxide) launched with `headless = false`, dedicated profile dir, CDP `Network.getAllCookies` after user signals "done". | Chromium window the user already trusts. |
| 2 | **Separate Tauri helper binary** (`rev-scraping-auth-helper`) | Standalone GUI app mirroring `rev_magic` pattern; writes encrypted cookie file consumed by main process. | Tauri WebView (system WebKit/WebView2). |
| 3 | **Manual JSON / cookies.txt import** | User runs `auth import --domain X --file cookies.json`; supports `EditThisCookie`/Playwright/Puppeteer JSON, Netscape `cookies.txt`. | External browser, DevTools. |

### A.2 Trade-off matrix

| Dimension | Mode 1 (headed obscura) | Mode 2 (Tauri helper) | Mode 3 (manual import) |
|---|---|---|---|
| New deps | none beyond current | tauri + wry + system webview | none |
| Build size impact | none | +30–80 MB binary | none |
| Fingerprint parity with later fetches | **identical** (same chromiumoxide + obscura stack) | **divergent** (system webview UA/TLS, will trip site fraud signals) | divergent (user's own browser) |
| 2FA / WebAuthn UX | full Chrome support | system webview (WebAuthn varies) | full (user's own browser) |
| CAPTCHA UX | works (real chromium) | may break (WebView differs) | works |
| Headless server hosts | **fails** (no display) | fails | **works** (user pastes JSON via SSH) |
| Implementation cost | **low** (≈3 d) | high (≈10–15 d, new platform) | low (≈2 d) |
| Cookie extraction fidelity | full CDP (all flags) | full (Tauri `cookies_for_url`) | depends on export tool |
| User cognitive load | one CLI command + browser | extra binary, extra install | several manual steps |

### A.3 Decision

- **Adopt Mode 1 as primary**, **Mode 3 as fallback** for headless / SSH operators.
- **Reject Mode 2** for Phase 9. It duplicates the Tauri lock-in we deliberately avoided when forking `rev_magic` patterns; the only thing Tauri buys us is bundling, which we don't need (`obscura` already ships chromium-aware launch).
- A future Phase 10 may add Mode 2 if we need a packaged consumer app; out of scope.

### A.4 Composite UX flow (Mode 1)

```
agent → rev-stealth auth login --url https://app.example.com/login --profile work
        │
        ├─ AUP check (must be authorized + auth-allowed)
        ├─ VPN-required probe (Phase 6c)
        ├─ SSRF guard on URL
        ├─ Launch obscura headed (fresh profile dir under /tmp/rev_auth_XXXX)
        ├─ Print: "Sign in in the open window. When done, press ENTER here (or Ctrl+C to abort)."
        ├─ User completes login (incl. 2FA / CAPTCHA) manually
        ├─ ENTER → CDP Network.getAllCookies + Storage.getCookies per scope
        ├─ Filter to eTLD+1 scope from --url
        ├─ Encrypt → ~/.rev_scraping/auth/<profile>.enc
        ├─ Audit log append
        └─ exit 0 with JSON envelope (no cookie values)
```

For Mode 3:

```
rev-stealth auth import --domain app.example.com --profile work --file ~/Downloads/cookies.json [--format playwright|editthiscookie|netscape]
```

Supported import formats are detected by structure heuristic; explicit `--format` forces.

---

## B. Cookie storage architecture

### B.1 On-disk layout

```
~/.rev_scraping/
├─ authorized.toml              (existing, Phase 2)
├─ policy.toml                  (existing)
├─ audit.jsonl                  (Phase 9 new — append-only audit)
└─ auth/
   ├─ .meta.json                (version, last_rotation, kdf_params; not secret)
   ├─ work.enc                  (encrypted blob for profile "work")
   ├─ work.meta.json            (non-secret: domain list, created, expires-soonest, cookie-count)
   ├─ personal.enc
   └─ personal.meta.json
```

- Directory perms: `0700` on Unix; ACL "owner only" on Windows.
- File perms: `0600` on Unix.
- All files stored on the same filesystem as `$HOME` (no `/tmp` for persistent state).
- `.enc` contains: `magic(4) | version(1) | nonce(24) | ciphertext | tag(16)` (XChaCha20-Poly1305).
- Plaintext inside is canonical JSON:

```jsonc
{
  "schema": 1,
  "profile": "work",
  "created_utc": "2026-05-14T10:00:00Z",
  "scopes": [
    {
      "etld_plus_1": "example.com",
      "origin": "https://app.example.com",
      "login_url": "https://app.example.com/login",
      "cookies": [
        { "name": "session", "value": "...", "domain": ".example.com",
          "path": "/", "expires_utc": "2026-06-14T10:00:00Z",
          "http_only": true, "secure": true, "same_site": "Lax",
          "host_only": false }
      ]
    }
  ]
}
```

A **profile** can hold cookies for multiple eTLD+1 scopes (e.g. an OIDC SSO that drops cookies on both `example.com` and `auth.example.com`), but **never crosses login sessions**: one human login → one profile write.

### B.2 Encryption design

- **AEAD:** `XChaCha20-Poly1305` (24-byte nonce; safe against random nonce collisions across many writes).
- **Key source priority** (first that succeeds):
  1. **OS keyring** via `keyring` crate
     - macOS Keychain (`com.rev_scraping.auth` / `<profile>`).
     - Linux Secret Service (libsecret) — falls back to (3) if no SS available.
     - Windows Credential Manager via DPAPI-backed entry.
  2. **Hardware-backed envelope** (future-proof slot — disabled in 9a) for YubiKey/TPM PIV.
  3. **Passphrase + Argon2id** (interactive prompt; `--passphrase-fd` for scripted use). Argon2id params: `m=64MiB, t=3, p=1` (tuned during 9a benchmark).

The plaintext key is **per-profile**, 32 bytes, generated by `OsRng` at first `auth login`. Rotation: `auth rotate --profile X` re-encrypts under a fresh key and atomically swaps via `rename(tmp, target)` semantics.

- **In-memory hygiene:**
  - All plaintext key buffers wrapped in `zeroize::Zeroizing<[u8; 32]>`.
  - Cookie value strings wrapped in `secrecy::SecretString` once decrypted; `Debug` impl redacts.
  - Decrypted cookie jar held only for the duration of a single fetch session; dropped before await points that don't need it.

### B.3 secret-reject hooks (consistency with stealth-sites)

The recipe loader in `stealth-sites::store` already has a "reject if value smells like a secret" pattern (Phase 7a). We mirror it in `stealth-auth`:

- Reject if any cookie value field is *also present verbatim* in any non-encrypted file under `~/.rev_scraping/` (defensive — catches paste-into-recipe mistakes).
- Reject `auth login` if `--url` resolves to a recipe TOML containing literal cookie values (refuses to overwrite a recipe-supplied stub).

### B.4 Per-site isolation

- A profile name is **opaque** to the consumer; cookies are looked up by `etld_plus_1` derived from the fetch URL via `publicsuffix` crate.
- `auth login --url https://a.example.com/login --profile work` and a later `auth login --url https://b.other.com/login --profile work` produces a profile with **two scopes**; cookies from `a.example.com` are never sent to `b.other.com` (CookieStore enforces the Set-Cookie scoping rules natively).
- `auth login --profile work` for a domain already in `work` **replaces** that scope (with audit log) — does not merge across logins to avoid stale-vs-fresh ambiguity.

### B.5 Backup / restore

- Out of scope for 9a. We document: `~/.rev_scraping/auth/` is portable across machines **only** if the OS keyring entry is also migrated, otherwise the blob is opaque garbage on the new machine. (This is a *feature*, not a bug — prevents accidental exfiltration via `tar` of the home dir.)

---

## C. Cookie lifecycle

### C.1 Expiry semantics

- Each cookie's `expires_utc` is honored. `host_only` and `secure` flags preserved as captured.
- **Session cookies** (no Expires/Max-Age) are stored with `expires_utc: null` and treated as valid until either:
  - The profile's `created_utc + session_cookie_ttl` exceeds (default `session_cookie_ttl = 24h`, configurable in `policy.toml`).
  - User runs `auth refresh` or `auth delete`.
- A cookie is considered **expired** at `expires_utc <= now()` (no skew tolerance; reject cleanly rather than fudge).

### C.2 Status states (returned by `auth status`)

| State | Condition |
|---|---|
| `valid` | All required cookies for the scope are present and non-expired. |
| `degraded` | Some non-critical cookies expired; primary session token still valid. |
| `expired` | Primary session token expired. |
| `stale` | Last successful use > 7 d (warn; not blocking). |
| `missing` | No profile / no scope match. |

"Primary" is heuristic: cookie names matching common session patterns (`session`, `sid`, `_session`, `auth`, `token`, `JSESSIONID`, `connect.sid`, `csrftoken`, etc.) tracked via a small lib-internal allowlist. The recipe (§F) may override the primary cookie name per site.

### C.3 Refresh flow

- `auth refresh --profile work --domain example.com`:
  - Re-runs the login UX for **that scope only**.
  - Old scope is moved to `~/.rev_scraping/auth/.trash/work.<ts>.enc` (encrypted, deleted on next refresh — keeps one generation for rollback).
- Auto-refresh: **explicitly out of scope** in Phase 9 (see §I). The CLI/MCP returns `expired` and the agent must escalate to the human.

### C.4 GC

- `auth gc` (cron-able): walks all profiles, drops fully-expired scopes, compacts file. Also runs implicitly at the head of `auth login` and `spider --use-auth`.

---

## D. Cookie application to fetch paths

### D.1 reqwest (HTTP fetcher path)

- New adapter `stealth-auth::reqwest::AuthCookieJar` implements `reqwest::cookie::CookieStore`.
- It wraps a `cookie_store::CookieStore` initialized from the decrypted profile.
- Wire-in: `Client::builder().cookie_provider(Arc::new(AuthCookieJar::from_profile("work")?))`.
- **Scope enforcement:** the jar refuses to emit cookies whose `domain` does not match the request URL's eTLD+1; standard cookie_store does this, but we add an extra check at the adapter to log redacted denials so we can audit cross-domain leak attempts.
- The HTTP client deliberately does **not** persist *new* Set-Cookie headers received during a fetch back into the profile by default (the profile is "what the human logged in with", not "running session state"). A `--persist-set-cookie` flag on `spider` opts into capturing fresh server-issued cookies into a *separate* `.runtime.enc` overlay file (still encrypted, distinct from the canonical profile) — useful for sites that rotate tokens.

### D.2 chromiumoxide / obscura path

- New helper `stealth-auth::cdp::inject_into_page(page, scope)`:
  - Calls `Network.setCookies` with the decrypted scope before any `Page.navigate`.
  - Sets cookies with full attribute fidelity (incl. `sameSite`, `priority` where supported).
  - Verifies post-inject via `Network.getCookies` and logs (redacted) mismatch.
- The injection happens **inside** `stealth-core::browser` launch path when the caller passes a `Some(AuthScope)`, so every consumer of the launcher (spider, cf-evaluate, relocate) gets it for free.
- For `obscura` headed login itself, the injector is bypassed (we are *capturing*, not *replaying*).

### D.3 Touch points across crates

| Crate | Change required for D |
|---|---|
| `stealth-auth` | new crate, owns adapter + injector |
| `stealth-core::browser` | accept `Option<AuthScope>` in launch options; non-breaking default `None` |
| `stealth-cli::commands::spider` | parse `--use-auth`, `--auth-domain`, load scope, pass through |
| `stealth-cli::commands::cf_evaluate` | same |
| `stealth-cli::commands::relocate` | same (only when `--url` mode) |
| `stealth-mcp::tools` | add `spider_with_auth` etc. |
| `stealth-sites::recipe` | optional `[auth]` table (see §F) |
| `obscura-bridge` | none (transparent — uses stealth-core launcher) |
| `vpn-rotate` | none (transport unchanged) |
| `captcha-bypass` | none |

### D.4 Backwards compatibility

- All new params are `Option<...>` / default off. Existing CLI flags / MCP tool schemas unchanged.
- Existing tests untouched (new test files only).

---

## E. CLI + MCP surface

### E.1 CLI

```
rev-stealth auth login   --url <U> [--profile <NAME>] [--timeout-secs <N>]
                          [--passphrase-fd <FD>] [--i-have-authorization]
rev-stealth auth import  --domain <D> --profile <NAME> --file <PATH> [--format playwright|editthiscookie|netscape]
rev-stealth auth list    [--json]
rev-stealth auth show    --profile <NAME> [--domain <D>] [--json]   # values always redacted
rev-stealth auth status  --profile <NAME> [--domain <D>] [--json]
rev-stealth auth refresh --profile <NAME> --domain <D>
rev-stealth auth delete  --profile <NAME> [--domain <D>] [--yes]
rev-stealth auth rotate  --profile <NAME>                            # rotates encryption key
rev-stealth auth gc      [--dry-run]
rev-stealth auth export-template --site <D> > recipe-snippet.toml    # for §F integration
```

Existing subcommands gain:

```
rev-stealth spider       ... [--use-auth <PROFILE>] [--auth-domain <D>] [--persist-set-cookie]
rev-stealth cf-evaluate  ... [--use-auth <PROFILE>] [--auth-domain <D>]
rev-stealth relocate     --url ... [--use-auth <PROFILE>] [--auth-domain <D>]
```

### E.2 MCP tools (added to `stealth-mcp::tools`)

| Tool | Inputs | Output (envelope) |
|---|---|---|
| `auth_list` | `{}` | `{ profiles: [{name, scopes:[{domain, expires_soonest, status}]}] }` |
| `auth_login` | `{ url, profile?, timeout_secs? }` | `{ status: "ok"|"timeout"|"rejected", profile, scope }` (no cookie material) |
| `auth_show` | `{ profile, domain? }` | `{ scopes:[{domain, cookies:[{name, expires_utc, http_only, secure, same_site}]}] }` |
| `auth_status` | `{ profile, domain? }` | `{ state, primary_cookie_name?, expires_in_secs? }` |
| `auth_delete` | `{ profile, domain? }` | `{ removed:[...] }` |
| `spider_with_auth` | `{ url, profile, depth?, ... }` | spider envelope + `{ auth_used: { profile, domain } }` |

All envelopes carry the canonical `{ schema_version, status, exit_code, ... }` shape used by the rest of stealth-mcp.

### E.3 Exit code mapping

Use existing `stealth_core::ExitCode`:

- `0` ok
- `1` user error (bad profile name, AUP rejection, expired with `--strict`)
- `2` transient (keyring locked, browser launch timeout)
- `3` permanent (corrupted enc blob, schema mismatch)
- `7` leak (VPN guard tripped during login)

New: `4` reserved as **AuthExpired** (so the agent can distinguish "you need to re-login" from generic user error). Update `ExitCode` enum accordingly — additive, non-breaking.

### E.4 JSON envelope conventions

- `auth_*` tools never include cookie values, even when explicitly requested.
- `auth_show --json` redacts `value` to `"***"` and prepends `value_hash: "sha256:abcd…"` (first 8 hex) for differencing without disclosure.
- Errors carry `error_kind: "aup_denied" | "vpn_required" | "keyring_locked" | "expired" | "schema_mismatch" | "ssrf_blocked"` for machine handling.

---

## F. Integration with existing stack

### F.1 AUP gating

- `authorized.toml` schema gains an optional `auth_allowed` boolean per target:

```toml
[[targets]]
url_pattern = "https://app.example.com/.*"
auth_allowed = true            # required for `auth login` to proceed
```

- `auth login` → `aup::check_url(url)` AND `aup::auth_allowed_for(url)`. If only first passes, exit `1` with `error_kind = "auth_not_allowed"`.
- Loose globs (e.g. `https://.*`) **never** receive `auth_allowed = true` by parser rule (refuses with descriptive error) — prevents footgun.
- `--i-have-authorization` works for ad-hoc one-offs but logs a `WARN` line citing the user, time, URL.

### F.2 VPN-required

- `auth login` flows through `vpn_guard::run_startup_probe(require_vpn, &policy).await?` *before* launching the browser. If `require_vpn=true` and the probe fails → exit `7`, no browser opened. Prevents login cookies from being established on the user's clearnet IP (which would then be a tell when later replayed via VPN).
- `auth refresh` same.
- `auth import` skips VPN check (no network egress at import time), but warns if `require_vpn=true` since the imported cookies were presumably captured outside VPN.

### F.3 SSRF guard

- `--url` for `auth login` runs through the same `stealth-cli::policy` SSRF guard used by `spider`: blocks RFC1918 / loopback / link-local unless `--allow-private` (which itself requires `--i-have-authorization`).

### F.4 Proxy routing (Phase 8)

- Login browser uses the same VPN-routed proxy chain as the eventual fetch (`policy.vpn_instances[0]` by default; `--vpn-instance` to choose). Guarantees the source IP that establishes the session matches the source IP that replays it — many fraud-detection systems pin session-to-IP and would invalidate a session if these differ.

### F.5 stealth-sites recipe

Recipe TOML gains an optional table:

```toml
[auth]
required = true
login_url = "https://app.example.com/login"
primary_cookie_names = ["session", "auth_token"]
scope_etld_plus_1 = "example.com"
notes = """
Site rotates session every 30 days. Two-factor via TOTP. Captures requires
clicking 'Stay signed in' to receive long-lived refresh cookie.
"""
```

- `stealth-sites::recipe::AuthSection` (new) carries these fields.
- `spider --recipe <path>` auto-suggests `auth login` if recipe declares `[auth].required = true` and no matching profile is found.
- Recipe values are public hints; **never store cookie values in recipes** (parser hard-rejects any key named `value`, `cookie`, `session_value`, etc. — list in §G).

### F.6 stealth-cf (Phase 5e)

- If a Cloudflare challenge appears *during* manual login, the user solves it as normal in the visible browser. We do **not** invoke `stealth-cf` auto-bypass during interactive login (could confuse the user). For *replay*, cf-evaluate is unchanged: it runs as today and the cookies happen to include CF clearance cookies which it transparently uses.

### F.7 captcha-bypass

- Same as F.6: human solves at login; no auto-solver invocation during `auth login`.

---

## G. Security threat model

### G.1 Asset

The decrypted session cookies are **password-equivalent** for the duration of their validity. Theft → full account takeover, no second-factor prompt typically required for "trusted device" sessions.

### G.2 Threat → mitigation matrix

| # | Threat | Vector | Mitigation |
|---|---|---|---|
| T1 | Cookie file exfiltration via backup / sync (iCloud, Dropbox) | `~/.rev_scraping/auth/*.enc` synced | (a) key in OS keyring, not synced; (b) `.enc` is useless without key; (c) doc warns users |
| T2 | Process memory disclosure (core dump, debugger) | OOM, panic, ptrace | `Zeroizing`/`SecretString` wrappers; `setrlimit(RLIMIT_CORE, 0)` on Unix at startup of `auth login` |
| T3 | Log leakage | tracing/log writes including cookie value | central `redact::cookie_value` helper; lint: deny any `tracing::*!(... cookie_value ...)`; log filter installed at crate init that masks any string matching cookie patterns |
| T4 | Git accidental commit | user adds `~/.rev_scraping` to a repo | global gitignore guidance; `auth login` writes `.gitignore` containing `*.enc\n*.meta.json` into `~/.rev_scraping/auth/` defensively |
| T5 | tmp leakage during obscura profile dir | chromium writes cookies to temp profile dir | Use `tempfile::TempDir` with explicit `close()` after extraction; on Drop, recursive `shred`-equivalent (zero-fill then unlink) on Unix; best-effort on Windows |
| T6 | Cross-domain cookie leak | bug sends `example.com` cookie to `attacker.com` | enforced at two layers: cookie_store native scope check + adapter-layer eTLD+1 assertion + integration test for known confusable domain pairs |
| T7 | Agent tricked into logging into attacker URL | LLM-driven supply-chain prompt | AUP `auth_allowed` per-target requirement + interactive confirm in `auth login` printing eTLD+1 in bold before launch |
| T8 | Replayed cookies on wrong VPN exit IP → invalidation | session-to-IP pinning | F.4 (same proxy at login + replay); record `captured_vpn_instance` in `.meta.json`, `spider --use-auth` warns on mismatch |
| T9 | Keyring unlocked by other process | macOS Keychain access | use a dedicated keychain service name; ACL requests "always-ask" for first access; document risk |
| T10 | Cookie value present in agent transcript via `auth show` | LLM accidentally echoes | `show` redacts unconditionally; no `--unsafe-show-values` flag |
| T11 | Replay attack window after `auth delete` | file deleted but value still in caller process | callers required to call `AuthCookieJar::wipe()` (Drop is best-effort; explicit wipe on `auth delete` IPC broadcast — defer to 9c) |
| T12 | Audit log tampering | local attacker edits `audit.jsonl` | append-only by convention; future phase: HMAC chain. Document as known limitation. |

### G.3 Audit log (`~/.rev_scraping/audit.jsonl`)

One JSON object per line, no cookie material:

```json
{"ts":"2026-05-14T10:00:00Z","event":"auth.login","actor":"$USER","host":"$HOST",
 "profile":"work","domain":"example.com","vpn_instance":"jp-1","status":"ok",
 "schema":1}
```

Events: `auth.login | auth.import | auth.refresh | auth.delete | auth.rotate | auth.gc | auth.replay (per fetch via --use-auth)`. Rotated at 10 MB to `audit.jsonl.<ts>`.

### G.4 Agent consent gate

- First time an MCP session calls a tool with `profile=X`, the server returns `status: "consent_required", consent_token: "..."` and the human (via Claude Code UI) must approve.
- Token is cached for the lifetime of the MCP connection (or `policy.toml::auth_consent_ttl_secs`, default 1h).
- Out-of-band approval: `rev-stealth auth grant --token <T>`. Without it, tool returns exit `1` `error_kind="consent_required"`.

---

## H. SNS / member site specific challenges

| Challenge | Plan A handling |
|---|---|
| TOTP / SMS / WebAuthn | User completes inside the headed browser; we never see the secret. WebAuthn works in real Chrome (platform authenticator via macOS TouchID also works for `obscura --headed` since chromium accesses CTAP). |
| Login CAPTCHA | Human solves. We do not auto-solve at login. |
| Device-trust ("New device, verify") | Human handles. We surface a hint in the CLI: "if site requires email verification, complete it before pressing ENTER". |
| Session pinning to IP | §F.4 ensures same proxy at capture and replay. |
| Concurrent-session caps | If site enforces "1 session", multiple `spider --use-auth` calls in parallel may invalidate each other. We add a `--single-flight` advisory flag (acquires an fcntl lock on `<profile>.lock`) — default off in 9a, recommended off in stealth-sites recipe. |
| Anti-scraping ToS | §J: hard disclaimer + AUP + recipe-must-declare. Refuse `auth login` on a curated `~/.rev_scraping/auth/.blocklist` (we ship a default: openly-prohibited targets like LinkedIn's ToS-banned scraping). Override only with `--i-have-authorization`. |
| Mobile-only sites | Use `mobile-fp` profile (existing) during the headed login — `auth login --mobile-profile iphone-15`. |
| OAuth redirect chains | Capture from *all* eTLD+1s encountered during login (`Network.responseReceived` listener), prompt user before persisting any beyond the `--url`'s eTLD+1. |

---

## I. Automatic refresh

### I.1 Decision: out of scope for Phase 9

Headless re-login implies storing the password (and possibly TOTP seed), which **multiplies the blast radius**: the agent now holds a credential, not a session. We refuse.

### I.2 What we do provide

- `auth status` is callable cheaply; agents are expected to call it before any `spider_with_auth`.
- Pre-expiry warning: if `expires_in < policy.auth_renew_warn_threshold_secs` (default 24h), `auth status` returns `state: "valid"` + `warning: "renew_soon"`.
- MCP `auth_status` always returns warnings; the agent can proactively prompt the human.

### I.3 Future extension hooks

- An `AuthRefresher` trait reserved in the crate; default impl `NoopRefresher`. A user-supplied refresher could (e.g.) use a vault secret. **Disabled by default; not documented in 9a public API.**

---

## J. Legal / positioning

### J.1 Doc deliverables (added in 9g, not implementation)

- `docs/AUTH-DISCLAIMER.md`:
  - "Use only on accounts you own or have written authorization to access."
  - CFAA / 不正アクセス禁止法 / GDPR pointers.
  - Lists ToS-incompatible targets that we hard-block (LinkedIn, etc.).
  - Notes that the feature exists for: (a) personal data exports, (b) corporate use with sysadmin auth, (c) research with IRB approval, (d) red-team engagements with signed SoW.

### J.2 Scope-check at fetch time

- Before any `spider_with_auth` call, the cookie domain's eTLD+1 must match (or be a subdomain of) the fetch URL's eTLD+1. Cross-eTLD+1 explicitly blocked.
- The fetch URL must also be AUP-allowlisted (this was already true pre-Phase 9; restated for emphasis).

### J.3 Telemetry

- We collect zero telemetry. The audit log is local-only. Documented in README.

---

## K. Crate structure

### K.1 New crate: `crates/stealth-auth/`

```
stealth-auth/
├─ Cargo.toml
└─ src/
   ├─ lib.rs            (public re-exports + error kinds)
   ├─ profile.rs        (Profile, Scope, Cookie types; serde)
   ├─ storage.rs        (read/write .enc + .meta.json, atomic rename)
   ├─ crypto.rs         (XChaCha20-Poly1305 wrapper, key derivation)
   ├─ keyring.rs        (OS keyring abstraction)
   ├─ passphrase.rs     (Argon2id KDF fallback)
   ├─ jar.rs            (reqwest::cookie::CookieStore impl)
   ├─ cdp.rs            (chromiumoxide cookie injector; feature-gated)
   ├─ import.rs         (playwright/editthiscookie/netscape parsers)
   ├─ redact.rs         (logging filter + Debug helpers)
   ├─ audit.rs          (append-only audit writer)
   ├─ status.rs         (status state machine)
   └─ errors.rs         (mapping to stealth_core::StealthError / ExitCode)
```

### K.2 Features

- `default = ["browser", "keyring"]`
- `browser` → pulls `chromiumoxide` cookie injector (same gate as stealth-core)
- `keyring` → pulls `keyring` crate (off in CI minimal builds)
- `passphrase-only` → no keyring dep (Linux server fallback)

### K.3 Why not extend stealth-core

- Keeps `stealth-core` free of crypto and keyring deps (currently very lean — used by tools that should not pay for `ring` / `argon2`).
- Lets `stealth-cli` / `stealth-mcp` opt-in via feature flag.
- Clean test boundary.

### K.4 Why not put it in stealth-cli

- Need to call it from `stealth-mcp` too. CLI is consumer; auth is library.

### K.5 Dependencies (curated)

| Purpose | Crate | Justification |
|---|---|---|
| AEAD | `chacha20poly1305` | RustCrypto, audited, XChaCha20 variant |
| KDF | `argon2` | RFC 9106, default OWASP params |
| Zeroize | `zeroize` | trivial, no_std |
| Secret types | `secrecy` | drops Debug exposure |
| Keyring | `keyring` (^3) | cross-platform |
| Cookie store | `cookie_store` + `reqwest::cookie::CookieStore` | already pulled by reqwest |
| Public suffix | `publicsuffix` | eTLD+1 derivation |
| Atomic write | `tempfile` + manual rename | no extra dep |
| Time | `chrono` | already in workspace |

No `ring` (we get AEAD from RustCrypto stack which is already partially present via `obscura`).

### K.6 Effort estimate (engineer-days)

- 9a stealth-auth crate (types + storage + crypto + keyring): **5 d**
- 9b obscura headed wiring + capture: **3 d**
- 9c reqwest jar + CDP injector + spider/cf/relocate integration: **4 d**
- 9d CLI subcommands + JSON envelopes + AUP gates: **3 d**
- 9e MCP tools: **2 d**
- 9f stealth-sites `[auth]` section + recipe loader: **1 d**
- 9g E2E tests + docs + disclaimer: **2 d**

Total: **~20 d** (one engineer); compressible to **~12 calendar days** with parallelism (see §M).

---

## L. Test strategy

### L.1 Unit tests (per-crate)

- `crypto.rs`: encrypt → decrypt → original; nonce reuse → tag failure; tampered ciphertext rejected.
- `storage.rs`: atomic rename never leaves partial file; permission bits set; meta vs enc consistency.
- `profile.rs`: serde roundtrip; schema v1 → v2 migration (when introduced).
- `jar.rs`: cookie scope matching against confusable domains (`example.com.attacker.com`, `examplecom.attacker.com`).
- `redact.rs`: logging filter masks pre-known patterns; property test with random cookie-shaped strings.
- `import.rs`: parse each supported format against fixture files (synthetic — no real cookies).
- `status.rs`: state machine covers all transitions.

### L.2 Integration tests (`tests/` in stealth-auth)

- **Mock login server** (httpmock or wiremock): serves a fake `/login` that issues a `Set-Cookie`, then a `/protected` that requires it.
- Full flow: launch obscura headed in *headless override mode* (test-only feature flag `test_auto_login` that types into the form), capture cookies, encrypt, decrypt, replay against `/protected`, expect 200.
- Cross-domain assertion: cookie from `a.localtest.me` not sent to `b.localtest.me`.

### L.3 CLI tests (`crates/stealth-cli/tests/`)

- `assert_cmd` style: `auth login --url ... --i-have-authorization` against mock server returns exit 0 + valid JSON envelope without cookie values.
- AUP rejection: target not in authorized.toml → exit 1 + `error_kind: aup_denied`.
- VPN-required + no instance configured → exit 7.

### L.4 MCP tests

- Round-trip `auth_login` → `auth_status` → `spider_with_auth` against mock server using stealth-mcp's existing in-process harness.

### L.5 E2E (`#[ignore]`, manual)

- One scripted real-site harness pointing at a user-provided dev account. Documented; CI skips by default. Triggered via `cargo test -p stealth-auth --test e2e -- --ignored --nocapture`.

### L.6 Negative / fuzzing

- Cargo-fuzz target for `.enc` parser (rejects malformed without panic).
- Cargo-fuzz target for cookie import parsers.

### L.7 Regression guarantees

- New tests live in new files; no existing test file edited.
- A pre-merge check `cargo test --workspace` must remain green; CI matrix includes `--no-default-features --features passphrase-only` to ensure keyring is truly optional.

---

## M. Sub-phase rollout

### M.1 Dependency DAG

```
9a (stealth-auth crate)
   ├─→ 9b (obscura headed capture)
   │      └─→ 9d (CLI auth subcommands)   ──┐
   │                                         ├─→ 9e (MCP tools)
   ├─→ 9c (reqwest + CDP integration)   ────┘             │
   │                                                       └─→ 9g (E2E + docs)
   └─→ 9f (recipe [auth] section) ───────────────────────→ 9g
```

### M.2 Sub-phase table

| Sub-phase | Scope | Deps | Effort | Parallelizable with |
|---|---|---|---|---|
| **9a** | crate skeleton, types, storage, crypto, keyring, unit tests | — | 5 d | — |
| **9b** | obscura `--headed` capture, CDP `Network.getAllCookies`, redaction | 9a | 3 d | 9c, 9f |
| **9c** | `AuthCookieJar`, CDP injector, spider/cf/relocate plumbing | 9a | 4 d | 9b, 9f |
| **9d** | `rev-stealth auth …` CLI subcommands, JSON envelopes, AUP integration | 9a, 9b | 3 d | 9f |
| **9e** | MCP tools, consent-gate, redacted envelopes | 9a, 9c, 9d | 2 d | — |
| **9f** | `[auth]` recipe section + loader + value-reject lint | 9a | 1 d | 9b, 9c, 9d |
| **9g** | E2E, fuzz target, AUTH-DISCLAIMER.md, README update | all | 2 d | — |

### M.3 Calendar

- Critical path: 9a → 9b → 9d → 9e → 9g = 5+3+3+2+2 = **15 calendar days** if 9c and 9f run in parallel with 9d.
- Recommended single-engineer schedule: serial = **20 calendar days**.

### M.4 Milestones / gates

- After 9a: `cargo test -p stealth-auth` green; key never logged (lint check).
- After 9c: spider against authenticated mock site returns protected content.
- After 9e: Claude Code can `auth_login` → `spider_with_auth` end-to-end via MCP.
- After 9g: external red-team review checklist signed off.

---

## N. Risk register

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | Keyring API instability across Linux distros (no SS daemon) | M | M | passphrase fallback; CI test on Ubuntu minimal |
| R2 | chromium profile dir leaks cookies to swap | L | H | tmpfs option on Linux; documented; shred on Drop |
| R3 | Site upgrades to passkey-only with hardware-bound assertion | M | M | document — feature simply doesn't work on those sites; not our problem to "fix" |
| R4 | User adds wildcard `auth_allowed = true` to authorized.toml | M | H | parser refuses; emits error citing the offending line |
| R5 | LLM agent calls `auth_login` against attacker URL in a prompt-injection scenario | L | H | AUP `auth_allowed` per-target + consent gate (§G.4) + interactive ENTER prompt (CLI) |
| R6 | Argon2 params too slow on low-end hardware (Pi, CI) | L | L | configurable; CI uses `t=1, m=8MiB` profile |
| R7 | reqwest cookie_store API drift between minor versions | L | M | pin minor; coverage tests |
| R8 | CDP `Network.setCookies` rejects `sameSite=None` without `secure` on plain HTTP | L | L | injector pre-validates and emits user-friendly error |
| R9 | Site detects automation via cookie capture lag (long delay between login submit and first protected fetch) | L | M | injector finishes within same browser session if user proceeds; otherwise document warning |
| R10 | Audit log fills disk | L | L | rotation at 10MB |
| R11 | Encrypted blob format v1 → v2 migration breaks users | L | M | version byte + explicit migration path in 9a |
| R12 | Feature merged but disabled by default surprises users | L | L | explicit changelog + `auth list` printing "feature ready" hint |

---

## O. Rollback plan

### O.1 Per sub-phase

Each sub-phase is independently revertible:

- **9a** lives in a new crate not yet wired into the workspace `[workspace.members]` until 9d lands. Revert = remove crate folder + member entry.
- **9b** changes to `obscura-bridge` are gated by a new optional method `with_capture_mode(bool)` — default false. Revert = drop the method.
- **9c** changes to `stealth-core::browser` are additive (`Option<AuthScope>` defaulting `None`). Revert = remove the parameter; no caller used it before 9d.
- **9d** CLI subcommands are new — revert via removing the `auth` clap subcommand and `--use-auth` flags on existing subcommands.
- **9e** MCP tools are additive in the tool registry. Revert = remove the entries.
- **9f** recipe `[auth]` is an `Option<AuthSection>` — revert = drop the field; old recipes unaffected.
- **9g** docs/tests revert trivially.

### O.2 Data preservation on rollback

- If a user has `~/.rev_scraping/auth/*.enc` blobs and we ship a version that no longer reads them: the directory remains untouched (we never delete data on uninstall). User can re-install a newer version to recover.

### O.3 Emergency kill switch

- Env var `REV_SCRAPING_AUTH_DISABLED=1` short-circuits all `auth_*` paths to exit `1` with `error_kind: "feature_disabled"`. Useful for site-wide org policy enforcement during incident response.

---

## P. Timeline

Assuming one engineer, start week of 2026-05-18:

| Week | Days | Sub-phase |
|---|---|---|
| W1 | Mon–Fri | 9a (crate, crypto, keyring) |
| W2 | Mon–Wed | 9b (obscura headed capture) |
| W2 | Thu–Fri + W3 Mon–Tue | 9c (replay path) |
| W3 | Wed–Fri | 9d (CLI) |
| W4 | Mon–Tue | 9e (MCP) |
| W4 | Wed | 9f (recipe [auth]) |
| W4 | Thu–Fri | 9g (E2E + docs) + buffer |

Two-engineer parallel: complete W3 Friday (15 days).

---

## Q. DECISION NEEDED (user judgment items)

Each item lists Plan A's **recommended value** in **bold**, plus runner-up.

1. **Q1. Primary capture UX.**
   Options: (a) headed `obscura`, (b) Tauri helper, (c) manual import only.
   → **Recommend (a) headed obscura, with (c) manual import as fallback for SSH/headless operators.** Reject (b).

2. **Q2. Encryption key storage.**
   Options: (a) OS keyring with passphrase fallback, (b) passphrase always, (c) plain disk + filesystem perms only.
   → **Recommend (a).** (c) is unacceptable. (b) is annoying for daily use.

3. **Q3. AEAD algorithm.**
   Options: (a) XChaCha20-Poly1305, (b) AES-256-GCM-SIV, (c) AES-256-GCM.
   → **Recommend (a) XChaCha20-Poly1305** (large random nonces are safe; pure-Rust; no AES-NI dependency for portability to ARM CI).

4. **Q4. Auto-refresh of expired sessions.**
   Options: (a) Out of scope (manual re-login), (b) opt-in headless replay using stored credentials, (c) trait-based pluggable.
   → **Recommend (a) out of scope for Phase 9.** Revisit in Phase 11.

5. **Q5. Per-site `auth_allowed` requirement.**
   Options: (a) hard requirement in authorized.toml, (b) `auth login` warns then proceeds, (c) no gating beyond existing AUP.
   → **Recommend (a) hard requirement.** Prevents agent-driven account hijack.

6. **Q6. Set-Cookie persistence during replay.**
   Options: (a) discard server-issued cookies (frozen profile), (b) persist into overlay file, (c) persist into main profile.
   → **Recommend (a) by default, (b) via `--persist-set-cookie` opt-in.** Never (c) — main profile reflects the human login only.

7. **Q7. New crate vs existing crate.**
   Options: (a) new `stealth-auth`, (b) extend `stealth-core`, (c) module inside `stealth-cli`.
   → **Recommend (a) new crate.** Keeps crypto deps optional; clean reuse from MCP.

8. **Q8. Audit log location.**
   Options: (a) `~/.rev_scraping/audit.jsonl`, (b) syslog, (c) both.
   → **Recommend (a) only for 9a.** syslog hook deferred.

9. **Q9. Default session-cookie TTL when site sends no Expires.**
   Options: (a) 24 h, (b) 8 h, (c) until-process-exit.
   → **Recommend (a) 24 h, configurable in `policy.toml`.**

10. **Q10. ToS blocklist enforcement.**
    Options: (a) ship a default blocklist (LinkedIn etc.), (b) empty by default, document risk, (c) hard-disable any login attempt without recipe declaring legality.
    → **Recommend (a) with override via `--i-have-authorization`.** Aligns with rev_scraping's "fail-closed" ethos.

11. **Q11. Consent gate for MCP.**
    Options: (a) per-MCP-session consent token, (b) per-call confirm, (c) trust-by-config.
    → **Recommend (a)** for usable + safe balance.

12. **Q12. Audit log integrity.**
    Options: (a) plain append-only, (b) HMAC chain, (c) external signing service.
    → **Recommend (a) for 9a; HMAC chain in a future phase.**

---

## Appendix: glossary

- **Scope:** a single eTLD+1's worth of cookies inside a profile.
- **Profile:** a named collection of scopes (e.g. `work`, `personal`).
- **Capture:** the act of recording cookies from a live browser session.
- **Replay:** sending captured cookies on a subsequent fetch.
- **Primary cookie:** the cookie whose presence/expiry defines session validity.

---

## Appendix: invariants

- I1. No cookie value is ever written to a file outside `~/.rev_scraping/auth/` (or its `.trash/`).
- I2. No cookie value is ever returned by any MCP tool.
- I3. No cookie value is ever logged at any tracing level.
- I4. `auth login` never proceeds without (AUP allowed + AUP auth-allowed + VPN-required passed + SSRF-guard passed + user ENTER).
- I5. The encryption key is never present in any file under `~/.rev_scraping/`.
- I6. Public-suffix-derived eTLD+1 is the *only* scope key; subdomain mismatch is fatal at lookup.
- I7. `stealth-core::browser` remains usable with `None` auth scope; default behavior unchanged.
- I8. Adding `stealth-auth` to the workspace does not increase the binary size of `rev-stealth` when built `--no-default-features --features minimal`.

---

*End of Plan A.*
