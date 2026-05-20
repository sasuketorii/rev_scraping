# Phase 9 ExecPlan rev1 — Authenticated Session Capture (Integrated)

> **Status:** Design only. No implementation files in scope.
> **Provenance:** Synthesis of Plan A (Opus 4.7-high, 746 lines) and Plan B (Codex gpt-5.5-high, 999 lines), authored independently.
> **Synthesis date:** 2026-05-14.
> **Predecessor phases assumed live:** 2 (AUP), 5e (stealth-cf), 6c (VPN leak guard), 7a (stealth-sites recipe), 8 (proxy routing).
> **Headline goal:** A one-time human-driven login captures session cookies → encrypted-at-rest → reused transparently by `spider` / `cf-evaluate` / `relocate` and MCP tools — **no credential, 2FA, or CAPTCHA automation**.

---

## 0. Executive design summary (integrated)

This rev1 picks, per-section, the technically stronger of A/B (or merges both where they are complementary). Headline integrated decisions:

- **Capture UX:** Default = **headed `obscura` invoked via an isolated `rev-auth` helper subprocess**. Fallback = manual JSON / Netscape import. Tauri helper rejected (A). The Codex helper-process boundary is adopted as a memory-isolation feature, but it runs the same `obscura`/chromiumoxide stack rather than a Tauri WebView — best of both.
- **Crate:** New workspace crate **`stealth-auth`** (A and B agree). Optional feature `stealth-auth`, additive only.
- **AEAD:** **XChaCha20-Poly1305** (24-byte nonce, RustCrypto, pure Rust, ARM-portable) — A's choice, technically superior to B's ChaCha20-Poly1305-96bit-nonce for many-write workloads.
- **Key storage:** **OS keyring (`keyring` v3) primary; Argon2id passphrase fallback; fail-closed on headless Linux unless explicit CI fixture key configured** — merges A (passphrase fallback) + B (fail-closed posture).
- **Application:** Replay via **both** `reqwest::cookie_provider` (HTTP) **and** CDP `Network.setCookies` (browser) — A and B agree; both layers required because both fetch paths exist.
- **Proxy stickiness:** `RequireSameNamedProxy` by default (B), recorded in `.meta.json` (A's `captured_vpn_instance`).
- **Agent authorization:** **Two-layer**: AUP `auth_allowed=true` per-target requirement (A) **plus** per-MCP-session consent token with TTL (A). Plan B's "no MCP export, no values" invariant is also adopted.
- **Auto-refresh:** **Out of scope** for Phase 9 — both A and B agree, no merge needed.
- **Scope keying:** eTLD+1 via `publicsuffix` crate (A; B mostly implicit).
- **Sub-phase ordering:** Hybrid DAG — 9a is foundational; 9b (capture) and 9c (HTTP replay) parallel after 9a; 9d (CDP replay) merged into 9c per A's structure; CLI/MCP/recipe/E2E follow.

Effort: **~20 engineer-days serial; ~12 wall days parallel (2 engineers).** Detailed breakdown in §K and Model Assignment Map.

---

## A. UX / Startup mode

**Plan A says:** Mode 1 headed `obscura` primary, Mode 3 manual import fallback, Mode 2 Tauri rejected. Login runs in-process.

**Plan B says:** Default = separate `rev-auth` helper binary that runs the headed browser in an isolated subprocess; `rev-scraping auth login` is canonical and shells out to it. Manual import fallback. Headed obscura is "internal capture path, not main boundary."

**統合判断: ADOPT B's helper-binary boundary, RUNNING A's obscura stack inside it.**

**理由:**
- A is correct that Tauri/WebView is wrong (fingerprint divergence, build bloat).
- B is correct that a separate process gives **memory isolation** (T2 in A's threat model: core dumps, ptrace) and a clean kill-on-exit boundary for plaintext key + cookies.
- These are orthogonal: the helper binary can launch obscura/chromiumoxide just like in-process would.
- Net win: A's fingerprint parity + B's process isolation + B's "single canonical CLI entry that delegates" UX.

**Manual import** is the SSH/headless fallback (both A and B agree). Headed-obscura-in-main-process is also retained as a `--mode in-process` diagnostic flag for tests.

### A.4 Composite UX flow (integrated)

```
agent → rev-scraping auth login --profile work --url https://app.example.com/login
        │
        ├─ AUP check (must be authorized + auth_allowed=true)
        ├─ VPN-required probe (Phase 6c)
        ├─ SSRF guard on URL
        ├─ Phase 8 proxy resolver → ResolvedProxyRoute
        ├─ fork/exec → rev-auth (isolated helper binary)
        │     ├─ Launch obscura headed (chromiumoxide; same stack as replay)
        │     ├─ Print: "Sign in in window. ENTER when done."
        │     ├─ User completes login (incl. 2FA / CAPTCHA) manually
        │     ├─ ENTER → CDP Network.getAllCookies + per-scope
        │     ├─ Filter to eTLD+1 of --url
        │     ├─ Capture UA + Accept-Language (browser metadata)
        │     ├─ Encrypt → ~/.config/rev_scraping/auth/<profile>.jar.enc
        │     ├─ Write keyring entry
        │     └─ exit, returning redacted JSON envelope on stdout
        ├─ Parent: audit log append
        └─ exit 0
```

---

## B. Cookie storage architecture

**Plan A says:** `~/.rev_scraping/auth/`, XChaCha20-Poly1305 (24-byte nonce), per-profile 32-byte key, OS keyring with Argon2id (m=64MiB, t=3, p=1) passphrase fallback. Atomic rename. `.trash/` for one rollback generation. eTLD+1 scope keying.

**Plan B says:** `~/.config/rev_scraping/auth/` (XDG), ChaCha20-Poly1305 96-bit nonce, AAD = `rev_scraping:stealth-auth:v1:<profile>`. `keyring` v3 with platform backends. Custom `PersistedCookieJarV1` schema (not raw cookie_store JSON). Atomic write with fsync of file + parent dir.

**統合判断:**
- **Path:** Adopt **B's XDG path** (`~/.config/rev_scraping/auth/`). Standard Linux convention; macOS still works because `directories` crate or manual resolution handles `$XDG_CONFIG_HOME`. A's `~/.rev_scraping/` is non-standard.
- **AEAD:** Adopt **A's XChaCha20-Poly1305 (24-byte nonce)**. 96-bit nonce (B) is safe enough but XChaCha20 buys safety margin for many writes (rotation, refresh, audit-related rewrites) at zero perf cost.
- **AAD:** Adopt **B's explicit AAD** `rev_scraping:stealth-auth:v1:<profile>`. Prevents cross-profile blob confusion. A did not specify AAD.
- **Envelope:** B's `EncryptedJarEnvelopeV1` (magic 8 + version 2 + profile_hash 32 + nonce 24 + ct + tag). Profile hash binds the blob to its filename.
- **Atomic write:** B's spec — temp → chmod 0600 → fsync file → atomic rename → fsync parent. A's atomic-rename is correct but B's sequence is more precise.
- **Trash / rollback:** Keep **A's `.trash/work.<ts>.enc`** for one previous generation (rollback safety on refresh). B has no rollback path.
- **Schema:** Adopt **B's `PersistedCookieJarV1`** typed schema (versioned, includes `BrowserReplayMetadata`, `AuthRouteBinding`, `AuthLifecycleMetadata`). A's JSON is similar but B's typing is stronger and captures more replay context.
- **Keyring service/account naming:** B's spec (`rev_scraping.stealth_auth` / `cookie-jar:<profile>`).
- **Key source priority:** A's three-tier list (OS keyring → reserved hardware slot disabled → Argon2id passphrase). B's "fail closed on headless Linux" merged in as policy default; passphrase fallback explicitly opt-in via `--passphrase-fd`.
- **In-memory hygiene:** Both A (`Zeroizing`, `SecretString`) and B (`SecretCookieValue` + `ZeroizeOnDrop`) agree. Adopt the union.
- **secret-reject hooks:** Keep A's recipe-paste defense (B does not mention).
- **Per-profile multi-scope:** Keep A's design (one profile holds multiple eTLD+1 scopes, e.g. OIDC SSO crosses example.com + auth.example.com).

---

## C. Cookie lifecycle

**Plan A says:** States `valid|degraded|expired|stale|missing`. Session cookies treated as valid until 24h default (configurable). Auto-refresh out of scope. Primary cookie name heuristic + recipe override. `.trash/` for one generation rollback.

**Plan B says:** `CookieExpirySummary`. Warn-before-expiry threshold = 7 days. Session-cookie policy = `PersistUntilDelete` default. Lifecycle metadata includes `last_verified_at`, `stale_reason` enum. Rich `AuthStaleReason` (HTTP 401/403, redirect-to-login, login-form detection, etc.).

**統合判断:**
- **Status states:** Adopt **A's `valid|degraded|expired|stale|missing`** as the user-facing state. Map B's `AuthStaleReason` as the **diagnostic detail field** attached to `stale` / `expired` states. Best of both: A's user-facing simplicity + B's machine-readable reason codes.
- **Session-cookie TTL:** Adopt **B's `PersistUntilDelete`** as default (more useful than A's 24h hard cutoff for daily-driver profiles). Expose A's `DropAfter(Duration)` as configurable policy in `policy.toml` for high-security profiles.
- **Warn threshold:** Adopt **B's 7 days** as default (A had 24h, which is too late to act).
- **Refresh:** A's `.trash/` rollback + B's "keep previous jar if refresh fails" — same idea, merged.
- **Primary cookie name:** A's heuristic + recipe override.
- **GC:** A's `auth gc` subcommand.
- **Probe contract:** Adopt **B's `probe_auth_status()` API** for active staleness detection.

---

## D. Cookie application to fetch paths

**Plan A says:** `AuthCookieJar` adapter implementing `reqwest::cookie::CookieStore`. CDP `Network.setCookies` injector via new `stealth-auth::cdp::inject_into_page()`. Scope enforcement at adapter layer (defense-in-depth over `cookie_store` native). `--persist-set-cookie` overlay file for token-rotating sites.

**Plan B says:** Same approach but adds **UA + Accept-Language replay** as first-class concern: `BrowserReplayMetadata` carries the login UA, and `build_authenticated_http_client()` sets `cookie_provider` + `user_agent` + `default_headers` together. CDP flow includes `Emulation/UserAgent override` before `Network.setCookies`.

**統合判断: 完全に補完。両採用。**

- A's `AuthCookieJar` adapter + CDP injector.
- B's `BrowserReplayMetadata` integrated into `AuthenticatedSession`; UA/Accept-Language replay enforced at HTTP **and** CDP layers. **This is a critical correctness fix A missed** — many fraud systems detect UA mismatch between login and replay.
- A's `--persist-set-cookie` overlay retained as optional opt-in.
- B's CDP edge-case handling table (`__Host-`, `__Secure-`, `SameSite=None` requires `secure`, partitioned cookies) adopted as injector validation rules.
- A's `Option<AuthScope>` non-breaking parameter on `stealth-core::browser` adopted.

---

## E. CLI + MCP surface

**Plan A says:** `rev-stealth auth {login|import|list|show|status|refresh|delete|rotate|gc|export-template}` + `--use-auth` flags on `spider`/`cf-evaluate`/`relocate`. MCP tools: `auth_list / auth_login / auth_show / auth_delete / auth_status / spider_with_auth`. Exit code 4 = AuthExpired (new).

**Plan B says:** `rev-scraping auth {login|list|show|delete|status|export|import|refresh}`. `auth show --reveal` for local TTY only with audit. MCP tools: **only** `auth_list / auth_status / auth_login_start / auth_login_complete`. **Explicitly no `auth_export` over MCP, no values ever.** Detailed JSON schemas for each tool.

**統合判断:**
- **Binary name:** Adopt **B's `rev-scraping`** (matches existing crate ecosystem name; A's `rev-stealth` may already be in use — DECISION NEEDED if A's name is the actual binary).
- **CLI subcommand list:** Take the **union**: `login, import, list, show, status, refresh, delete, rotate, gc, export, export-template`.
  - `rotate` (A only): rotate encryption key.
  - `gc` (A only): collect expired.
  - `export` (B only, CLI-gated + audited): local-only cookie export for advanced users.
  - `export-template` (A only): for recipe authoring.
  - `--reveal` flag on `show` (B): TTY-only, audited, never via MCP.
- **`--use-auth` on existing subcommands:** A's design adopted.
- **MCP tool set:** Adopt **B's narrower set** (`auth_list / auth_status / auth_login_start / auth_login_complete`) plus A's `spider_with_auth`. **Reject A's `auth_show` over MCP** (B's stricter posture wins — no leak surface, even redacted hashes are signal).
- **MCP invariant:** Adopt **B's hard rule**: `cookie_values_returned: false` field in every output schema, enforced at serialization.
- **Two-phase login (B):** `auth_login_start` returns `login_id` + deadline; `auth_login_complete` finalizes. This is **strictly better than A's blocking `auth_login`** for MCP because MCP calls should not block for minutes waiting for human input. Adopt B's design.
- **Exit codes:** Adopt **A's `4 = AuthExpired`** (new, additive to existing ExitCode enum). DECISION NEEDED: confirm 4 is not currently used elsewhere.
- **JSON schemas:** Adopt **B's published schemas verbatim** (concrete, machine-checkable). A's schemas were prose-described only.
- **Consent gate:** A's per-MCP-session consent token (B does not address agent consent, only output redaction).

---

## F. Integration with existing stack

**Plan A says:** `authorized.toml` gains `auth_allowed=true` per-target (hard requirement). Wildcards refused for `auth_allowed`. VPN-required runs before browser launch. SSRF guard on `--url`. Same VPN-routed proxy at capture + replay (F.4). Recipe TOML gains `[auth]` table.

**Plan B says:** No `--ignore-aup`. Recipe `AuthRecipe` with `login_url`, `probe_url`, `required_cookies`, `ua_pin`, `login_hosts`, `refusal_policy`. `resolve_auth_route()` enforces Phase 8 routing. SSRF guard on probe URL every time. `AuthRefusalPolicy` (`Allow`/`WarnRequireExplicitFlag`/`RefuseByDefault`).

**統合判断: 一致 + 補完, 両方採用。**

- A's `auth_allowed=true` AUP per-target requirement (hard).
- A's wildcard-refusal parser rule.
- A's VPN-required-before-browser-launch gate.
- A's `--i-have-authorization` override with WARN log.
- B's `AuthRecipe` schema (richer than A's — adopt B's typed struct).
- B's `AuthRefusalPolicy` per-recipe (richer SNS handling than A's blocklist file).
- A's blocklist file kept as **default-shipped** `RefuseByDefault` entries (LinkedIn, etc.).
- B's `resolve_auth_route()` for Phase 8 binding.
- B's probe URL SSRF guard (continuous, not just login-time).
- A's stealth-cf + captcha-bypass non-invocation during login (both agree implicitly).

---

## G. Security threat model

**Plan A says:** Detailed T1–T12 threat table. Audit log JSONL at `~/.rev_scraping/audit.jsonl`. Per-MCP-session consent token (G.4). Future HMAC chain for audit integrity.

**Plan B says:** 10-vector leakage table. `AuthRedactionLayer` tracing layer. `install_auth_panic_hook` redactor. Audit fields including `cookie_name_hashes` and `value_hashes` (hashes only). Security dependency policy (pinned versions, `cargo audit`, `cargo deny`, `#![forbid(unsafe_code)]`).

**統合判断: ほぼ補完。両採用。**

- Take A's T1–T12 matrix as the canonical threat model.
- Add B's tracing redaction layer (`AuthRedactionLayer`) as the implementation mechanism for A's T3.
- Add B's panic hook redactor (A did not address panic-time leak).
- Adopt **A's per-MCP-session consent token** (B does not address agent consent).
- Adopt **B's `#![forbid(unsafe_code)]`** crate-level lint (A did not specify).
- Adopt **B's pinned dep policy + `cargo deny`** in CI.
- Audit log: A's location moves to **B's XDG path** (`~/.config/rev_scraping/auth/audit.log`). Format = A's JSONL. Rotation = 10MB (both agree). Add **B's `cookie_name_hashes` + `value_hashes`** as fields for differential analysis without disclosure.
- Future HMAC chain (A) noted as deferred.
- `setrlimit(RLIMIT_CORE, 0)` in helper binary startup (A's T2 mitigation, strengthened by B's process isolation).

---

## H. SNS / member site challenges

**Plan A says:** Per-row mitigation table (TOTP/WebAuthn/passkey/CAPTCHA/device-trust/IP-pinning/concurrent-session-caps/ToS/mobile-only/OAuth-redirect-chains).

**Plan B says:** 2FA/passkey matrix per method. CAPTCHA: human only, no service integration. Device-fingerprint risk by site family (Twitter/Meta/LinkedIn high). `AuthRefusalPolicy` enum.

**統合判断: 補完。両採用。**

- A's coverage of operational scenarios (mobile-fp, OAuth chain, concurrent-session) is broader; adopt.
- B's `AuthRefusalPolicy` per-recipe is the cleaner mechanism for A's blocklist (B's enum > A's flat blocklist). Adopt B's enum, ship A's blocklist as default `RefuseByDefault` entries.
- A's `--single-flight` fcntl lock kept as advisory.
- B's risk-by-site-family table → documented in recipe template comments.

---

## I. Auto-refresh

**Plan A says:** Out of scope. `AuthRefresher` trait reserved (default noop, undocumented).

**Plan B says:** Reject silent auto-refresh. Manual refresh only. Explicit rules: no daemon, no scheduled refresh, no headless credential replay, keep previous jar on failure.

**統合判断: 一致。両採用。**

Out of scope. Take **B's explicit failure-mode rules** ("keep previous jar if refresh fails", "replace only after new encrypted write succeeds") + **A's reserved `AuthRefresher` trait** as a future hook (disabled, undocumented in public API).

---

## J. Legal / positioning

**Plan A says:** `docs/AUTH-DISCLAIMER.md` with CFAA / 不正アクセス禁止法 / GDPR pointers, ToS-incompatible target list, allowed use cases. Zero telemetry.

**Plan B says:** One-line stance, CFAA + 不正アクセス禁止法 + ToS + credentials position table. Forbidden storage types (`Password`, `TotpSecret`, `RecoveryCode` — must not exist as types in the crate). Allowed: `SecretCookieValue` only.

**統合判断: 補完, 両採用。**

- A's doc structure (`AUTH-DISCLAIMER.md`).
- B's forbidden-storage-type **enforcement** in code: a clippy lint or review-checklist + test that grep-rejects `password`/`totp`/`recovery_code` identifiers in `stealth-auth/src/`. This is stronger than just docs.
- B's required `--help` and README copy verbatim.
- A's zero-telemetry statement.
- A's `J.2` cross-eTLD+1 fetch-time scope check.

---

## K. Crate structure

**Plan A says:** New `crates/stealth-auth/` with `lib/profile/storage/crypto/keyring/passphrase/jar/cdp/import/redact/audit/status/errors`. Features: `default = ["browser", "keyring"]`, `passphrase-only`. Dep list curated.

**Plan B says:** New `crates/stealth-auth/` with `lib/jar/keystore/capture/probe/redact/audit/import_export/types` + later `http/cdp_apply/policy`. Features: `cdp-capture`, `manual-import`, `test-fixtures`. Workspace feature `stealth-auth` gates everything.

**統合判断:**
- **Crate name + location:** `crates/stealth-auth/` (both agree).
- **Module layout:** Merge — adopt B's `types.rs / capture.rs / probe.rs / http.rs / cdp_apply.rs / keystore.rs / jar.rs / redact.rs / audit.rs / import_export.rs / policy.rs` (B is more granular and explicit per sub-phase deliverables). Add A's `errors.rs` for `StealthError` / `ExitCode` mapping.
- **Features:** Merge — workspace-level `stealth-auth` feature gate (B) + crate-level `cdp-capture / manual-import / test-fixtures / passphrase-only` (A+B union). `keyring` always-on; `passphrase-only` builds without `keyring` for CI minimal.
- **Lints:** `#![forbid(unsafe_code)]` (B).
- **Deps:** Union of both lists. Pin versions per B's policy. No `ring` (A) — use RustCrypto stack. Add `argon2` (A only) for passphrase KDF.
- **`rev-auth` helper binary:** New binary at `crates/stealth-auth/src/bin/rev-auth.rs` (or separate `crates/rev-auth/`). DECISION NEEDED: same-crate `[[bin]]` vs separate crate. Recommend same-crate `[[bin]]` to share types without re-export gymnastics.

---

## L. Testing strategy

**Plan A says:** Unit (crypto/storage/profile/jar/redact/import/status) + integration (mock login server) + CLI tests (`assert_cmd`) + MCP tests + manual E2E (`#[ignore]`) + cargo-fuzz on parsers.

**Plan B says:** Unit (round-trip/AAD/atomic/permissions/redaction/expiry/prefix) + integration (mock CDP / reqwest / MCP schema snapshot / status / Netscape import) + manual E2E env-flag-gated + property tests (`proptest`: merge idempotence, newer-wins, partition, prefix).

**統合判断: 完全に補完。両採用。**

- A's `cargo-fuzz` targets on `.enc` parser + cookie importers.
- B's `proptest` properties on jar merge semantics.
- A's mock login server (real flow incl. browser).
- B's MCP schema snapshot tests.
- B's `0600` permission assertion.
- A's wrong-AAD-decrypt-fails (B has same).
- Both: CI matrix with `--features stealth-auth` and without (workspace must compile + green tests both ways).

---

## M. Sub-phase rollout (integrated DAG)

### M.1 Integrated DAG

```
9a (stealth-auth crate foundation)
   ├─→ 9b (rev-auth helper binary + obscura headed capture)
   │       └─→ 9d (CLI auth subcommands)
   │              └─→ 9e (MCP tools: list/status/login_start/login_complete)
   ├─→ 9c (reqwest jar + CDP injector + UA replay + Phase 8 binding)
   │       └─→ 9d (parallel after 9c too)
   ├─→ 9f (stealth-sites [auth] recipe + AuthRefusalPolicy)
   │       └─→ 9g
   └─→ 9g (E2E + SNS hardening + docs + disclaimer + fuzz/proptest)
```

### M.2 Integrated sub-phase table

(A's 7-step granularity preferred over B's because A clearly separates HTTP replay (9c) from CLI (9d) from MCP (9e); B conflated CDP into 9d. Adjusted: 9c = reqwest + CDP both, since they share the `AuthenticatedSession` plumbing.)

| Sub-phase | Scope | Deps | Effort | Model | Engineer | Parallel |
|---|---|---|---|---|---|---|
| **9a** | crate scaffold, types, storage, crypto, AAD, keyring, passphrase, redaction layer, panic hook, audit, errors | — | 5 d | gpt-5.5-high | Codex | foundational |
| **9b** | `rev-auth` helper binary, obscura headed capture, CDP `Network.getAllCookies`, `BrowserReplayMetadata` capture | 9a | 3 d | gpt-5.5-high | Codex | parallel with 9c, 9f |
| **9c** | `AuthCookieJar` reqwest adapter, CDP `Network.setCookies` injector, UA/Accept-Language replay, Phase 8 `RequireSameNamedProxy`, `--persist-set-cookie` | 9a | 4 d | gpt-5.5-high | Codex | parallel with 9b, 9f |
| **9d** | CLI auth subcommands (login/list/show/status/refresh/delete/rotate/gc/export/import), AUP `auth_allowed` integration, consent token storage, exit code 4 | 9a, 9b, 9c | 3 d | opus-4.7-medium | Claude Opus | parallel with 9f |
| **9e** | MCP tools (`auth_list`/`auth_status`/`auth_login_start`/`auth_login_complete`/`spider_with_auth`) with B's published JSON schemas, consent gate | 9a, 9c, 9d | 2 d | opus-4.7-medium | Claude Opus | last before 9g |
| **9f** | stealth-sites `AuthRecipe` typed struct + loader + `AuthRefusalPolicy` + value-reject lint + default blocklist | 9a | 1 d | gpt-5.5-medium | Codex | parallel with 9b/9c/9d |
| **9g** | E2E (axum mock + headed driver), proptest, cargo-fuzz, `AUTH-DISCLAIMER.md`, README, refusal-policy enforcement, audit hash fields, panic-hook tests | all | 2 d | gpt-5.5-medium | Codex | terminal |

### M.3 Calendar

- **Critical path** (single engineer, serial): 9a→9b→9c→9d→9e→9g = **5+3+4+3+2+2 = 19 days**. 9f fits in slack.
- **Wall time (2 engineers, parallel)**: 9a (5d) → {9b,9c,9f} parallel (4d max) → 9d (3d) → 9e (2d) → 9g (2d) = **~16 wall days**, or **~12 wall days** if 9d/9f also overlap.
- **3 engineers / 3 tracks** (Codex on 9a-9c-9g, Codex on 9f, Opus on 9d-9e): **~12 wall days**.

### M.4 Milestones

- After 9a: `cargo test -p stealth-auth --features stealth-auth` green; lint check confirms no `password`/`totp` identifiers; redaction layer test passes.
- After 9b: `rev-auth login` opens browser, captures cookies, writes encrypted jar, exits clean.
- After 9c: HTTP and CDP replay against mock authenticated site both succeed; UA mismatch test fails as expected.
- After 9d: full CLI surface usable; AUP `auth_allowed=false` rejects with exit 1.
- After 9e: MCP `auth_login_start`/`auth_login_complete` round-trip via Claude Code; `cookie_values_returned: false` in all envelopes.
- After 9g: external review checklist signed off; SNS refusal policy tested.

---

## N. Risk register

Take A's R1–R12 and B's 12-risk table — they overlap ~70%. Integrated 14 risks:

| # | Risk | L | I | Mitigation |
|---|---|---|---|---|
| R1 | Keyring missing on headless Linux | M | M | fail-closed by default; explicit `--passphrase-fd` opt-in; CI fixture key gate |
| R2 | Chromium profile dir leaks cookies to swap | L | H | `tempfile::TempDir` + shred on Drop; helper-process isolation |
| R3 | Passkey/hardware-bound site | M | M | document as out-of-scope; manual-import fallback for cases where user's own browser has the passkey |
| R4 | User wildcards `auth_allowed=true` | M | H | parser refuses; emits offending line |
| R5 | LLM agent calls `auth_login` against attacker URL | L | H | AUP `auth_allowed` + consent token + interactive ENTER prompt |
| R6 | Argon2 too slow on low-end | L | L | configurable params; CI uses lighter profile |
| R7 | reqwest cookie_store API drift | L | M | pin minor; coverage tests |
| R8 | CDP rejects `SameSite=None` without `secure` on HTTP | L | L | injector pre-validates with user-friendly error |
| R9 | Site detects automation via capture-replay lag | L | M | same-session injection if possible; document |
| R10 | Audit log fills disk | L | L | 10 MiB rotation |
| R11 | Enc blob v1→v2 migration breaks users | L | M | version byte + explicit migration path |
| R12 | Anti-bot detection on SNS replay | H (SNS) | M | UA replay, proxy stickiness, low-rate probes, refusal policy |
| R13 | Chrome auto-update CDP drift (cookie/partition fields) | M | M | adapter tests; ignore unsupported fields safely |
| R14 | Partitioned cookie loss → modern login fails | M | M | persist partition key in `PersistedCookieV1`; feature-detect CDP |

---

## O. Rollback plan

Both A and B agree: additive design, feature-gate, data inert without keystore. Adopt **B's `--features stealth-auth` gate at workspace level** + **A's per-sub-phase revert table**.

- 9a: remove workspace member + feature.
- 9b: unregister `auth login`; helper binary not built.
- 9c: `cookie_provider` not wired in fetch builders.
- 9d: CLI subcommand removed.
- 9e: MCP tools unregistered.
- 9f: recipe `auth` block ignored.
- 9g: docs trivially reverted.

Emergency kill switch: `REV_SCRAPING_AUTH_DISABLED=1` short-circuits all `auth_*` paths (A's idea).

Data preservation: encrypted jars remain inert without keyring entry. Manual purge documented (B).

---

## P. Timeline (integrated)

| Week | Days | Sub-phase | Track |
|---|---|---|---|
| W1 | Mon–Fri | 9a | Codex (gpt-5.5-high) |
| W2 | Mon–Thu | 9b (Codex) + 9c (Codex) + 9f (Codex med) | 3 parallel Codex sub-tasks |
| W2 | Fri–W3 Tue | 9d | Claude Opus |
| W3 | Wed–Thu | 9e | Claude Opus |
| W3 | Fri–W4 Mon | 9g | Codex (gpt-5.5-med) |

Total wall: ~3 weeks with 2-engineer mix; ~4 weeks single-engineer.

---

## Q. DECISION NEEDED (integrated)

Both A's 12-item Q list and B's 10-item Q list merged. Recommended values shown.

| # | Question | Options | Recommendation | Source |
|---|---|---|---|---|
| Q1 | Primary capture UX | (a) headed obscura in-process; (b) Tauri helper; (c) manual only; **(d) headed obscura inside isolated `rev-auth` helper subprocess + manual fallback** | **(d) — integrated** | A+B merge |
| Q2 | Encryption key storage | (a) OS keyring + Argon2id passphrase fallback; (b) keyring + fail-closed (no passphrase); (c) passphrase only | **(a) keyring primary, Argon2id passphrase opt-in, fail-closed on headless Linux without explicit opt-in** | A+B merge |
| Q3 | AEAD algorithm | (a) XChaCha20-Poly1305; (b) ChaCha20-Poly1305 (96-bit nonce); (c) AES-256-GCM | **(a) XChaCha20-Poly1305** | A |
| Q4 | Auto-refresh | (a) out of scope; (b) opt-in headless replay; (c) trait pluggable | **(a) out of scope** (reserved trait, undocumented) | A+B agree |
| Q5 | Per-site `auth_allowed` in AUP | (a) hard requirement; (b) warn-only; (c) no gating | **(a) hard requirement, wildcards refused** | A |
| Q6 | Set-Cookie persistence during replay | (a) discard; (b) overlay file opt-in; (c) main profile | **(a) default, (b) via `--persist-set-cookie`** | A |
| Q7 | Crate placement | (a) new `stealth-auth`; (b) extend `stealth-core`; (c) inside `stealth-cli` | **(a) new crate** | A+B agree |
| Q8 | Audit log location | (a) `~/.rev_scraping/audit.jsonl`; (b) `~/.config/rev_scraping/auth/audit.log`; (c) syslog | **(b) XDG path, JSONL format** | B path + A format |
| Q9 | Default session-cookie TTL | (a) 24h; (b) until-delete; (c) until-process-exit | **(b) PersistUntilDelete**, with policy.toml override | B |
| Q10 | ToS / refusal policy | (a) shipped blocklist; (b) recipe-level `AuthRefusalPolicy` enum; (c) both | **(c) both — enum mechanism + default `RefuseByDefault` entries** | A+B merge |
| Q11 | MCP consent gate | (a) per-session token; (b) per-call confirm; (c) trust-by-config | **(a) per-session token, TTL 1h** | A |
| Q12 | MCP exposure surface | (a) full CLI parity incl. export; (b) `list/status/login_start/login_complete` only, no values ever; (c) no MCP auth | **(b) — no values, no export** | B |
| Q13 | Audit log integrity | (a) plain append-only; (b) HMAC chain; (c) external signing | **(a) for 9a; HMAC deferred** | A+B agree |
| Q14 | Proxy strictness | (a) `RequireSameNamedProxy`; (b) warn-only; (c) allow mismatch | **(a) require same route; manual-import escape hatch only** | B |
| Q15 | Serialization schema | (a) raw `cookie_store` JSON; (b) custom `PersistedCookieJarV1`; (c) Netscape envelope | **(b) custom typed schema** | B |
| Q16 | Probe default | (a) always probe network; (b) local-only default + `--probe`; (c) never probe | **(b)** | B |
| Q17 | Crate unsafe policy | (a) allow; (b) `#![forbid(unsafe_code)]`; (c) feature-gated | **(b)** | B |
| Q18 | New ExitCode `4 = AuthExpired` | (a) add; (b) reuse existing code; (c) string error_kind only | **(a) add, additive** — verify 4 not in use | A; needs verification |
| Q19 | `rev-auth` helper binary placement | (a) `[[bin]]` inside `stealth-auth` crate; (b) separate `crates/rev-auth/`; (c) inside `stealth-cli` | **(a) `[[bin]]` inside `stealth-auth`** — DECISION NEEDED | new |
| Q20 | CLI top-level name | (a) `rev-stealth auth …`; (b) `rev-scraping auth …` | **DECISION NEEDED** — confirm with existing binary registry | A vs B disagree |
| Q21 | Cookie export over CLI | (a) no export; (b) CLI-only, audited, confirmed; (c) CLI + MCP | **(b) CLI-only with `--reveal`/`export`** | B |
| Q22 | Default warn-before-expiry threshold | (a) 24h; (b) 7d | **(b) 7d** | B |

---

## Comparison Matrix

| 章 | Plan A 主張 | Plan B 主張 | 一致/補完/対立 | 統合判断 | 理由 |
|---|---|---|---|---|---|
| A. UX | headed obscura in-process; manual fallback; Tauri reject | `rev-auth` separate helper binary; manual fallback; obscura is internal | 対立 (process boundary) | rev-auth helper running obscura | A's stack + B's isolation |
| B. AEAD | XChaCha20-Poly1305 (24B nonce) | ChaCha20-Poly1305 (96b nonce) + AAD | 対立 + 補完 | XChaCha20 + B's AAD scheme | larger nonce safety margin; AAD prevents cross-profile confusion |
| B. Path | `~/.rev_scraping/auth/` | `~/.config/rev_scraping/auth/` XDG | 対立 | B XDG | standard Linux convention |
| B. Key | OS keyring + Argon2id passphrase fallback | keyring v3 + fail-closed | 補完 | keyring primary + Argon2id opt-in + fail-closed default headless | both safety modes |
| B. Schema | JSON inline | typed `PersistedCookieJarV1` | 対立 | B typed | versioning + replay metadata stronger |
| C. TTL | 24h session default | PersistUntilDelete | 対立 | B until-delete | A's 24h too aggressive for daily use |
| C. Warn | 24h | 7d | 対立 | B 7d | A 24h too late |
| C. States | A's 5 user states | B's `AuthStaleReason` enum | 補完 | both layers | user-facing + diagnostic |
| D. Replay | jar + CDP injector | jar + CDP + **UA/Accept-Language replay** | 補完 (B adds) | both + UA replay | UA mismatch is real detection vector A missed |
| D. Proxy | F.4 same-proxy pin | `RequireSameNamedProxy` enum | 一致 | B enum + A meta recording | same idea, cleaner API |
| E. CLI | `rev-stealth` + 11 subcommands | `rev-scraping` + 9 subcommands | 対立 (name) + 補完 (subcommands) | union of subcommands; binary name DECISION NEEDED | richer surface |
| E. MCP | 6 tools incl. `auth_show` + `spider_with_auth` | 4 tools, no `show`, no values ever | 対立 | B's narrower set + A's `spider_with_auth` | minimize MCP attack surface |
| E. Login flow | blocking `auth_login` | `auth_login_start` + `auth_login_complete` (2-phase) | 対立 | B 2-phase | MCP must not block for human input |
| E. Exit codes | new `4 = AuthExpired` | not addressed | A unique | adopt A | machine-distinguishable expiry |
| E. JSON schemas | prose | published JSON Schema | B unique | adopt B verbatim | machine-checkable |
| F. AUP | `auth_allowed=true` per-target hard requirement | no `--ignore-aup` | 一致 | A's hard rule + B's no-bypass | both fail-closed |
| F. Recipe | `[auth]` table | typed `AuthRecipe` + `AuthRefusalPolicy` | 補完 | B typed struct + A integration | B's policy enum > A's blocklist file |
| G. Threat model | T1–T12 table + audit JSONL | 10 vectors + redaction layer + panic hook + cargo-deny | 補完 | both | A's model + B's mechanisms |
| G. Consent | per-MCP-session token | not addressed | A unique | A | agent-driven attack mitigation |
| G. Unsafe | not specified | `#![forbid(unsafe_code)]` | B unique | B | secrets handling crate |
| H. SNS | mitigation table | refusal policy enum + risk-by-family | 補完 | both | wider + cleaner mechanism |
| I. Refresh | out of scope + reserved trait | out of scope + explicit failure rules | 一致 | both | trait reserved, B's failure rules |
| J. Legal | disclaimer doc | doc + forbidden type enforcement | 補完 | both | docs + code-level prohibition |
| K. Modules | 13 modules | 11 modules + later additions | 補完 | union | both are right per sub-phase |
| L. Tests | unit + integration + cargo-fuzz | unit + integration + proptest + MCP schema snapshot | 補完 | both | fuzz + proptest complementary |
| M. DAG | 9a→{9b,9c,9f}→9d→9e→9g | 9a→9b→9c→9d→9e→{9f,9g} | 対立 (parallelism) | A's parallelism wins | B's serial DAG ignores that HTTP/CDP/recipe can parallelize |
| O. Rollback | per-sub-phase revert + env kill switch | feature-gate `--features stealth-auth` | 補完 | both | feature gate + env switch + per-phase revert |

---

## Model Assignment Map

Per user directive: **security-critical (crypto / secret / cookie capture / injection) → gpt-5.5-high (Codex)**. **Boilerplate (CLI / MCP / docs / recipe schema) → opus-4.7-medium or gpt-5.5-medium**.

| sub-phase | 内容 | 堅牢性 | モデル | dispatch エージェント | 並列可 | 工数 |
|---|---|---|---|---|---|---|
| **9a** | stealth-auth crate foundation: types, storage (envelope, atomic write, AAD), XChaCha20-Poly1305, keyring + Argon2id, redaction layer, panic hook, audit, errors, `#![forbid(unsafe_code)]` | 🔴 critical (crypto, secret) | **gpt-5.5-high** | Codex orchestrator | foundational | 5 d |
| **9b** | `rev-auth` helper binary + obscura headed mode + CDP `Network.getAllCookies` + `BrowserReplayMetadata` capture + setrlimit core-dump=0 | 🔴 critical (cookie extraction, process isolation) | **gpt-5.5-high** | Codex orchestrator | parallel after 9a | 3 d |
| **9c** | `AuthCookieJar` reqwest adapter + CDP `Network.setCookies` injector + UA/Accept-Language replay + Phase 8 `RequireSameNamedProxy` + `--persist-set-cookie` overlay | 🔴 critical (injection layer, fetch path correctness) | **gpt-5.5-high** | Codex orchestrator | parallel after 9a | 4 d |
| **9d** | CLI auth subcommands (login/list/show/status/refresh/delete/rotate/gc/export/import), AUP `auth_allowed` integration, consent token storage, exit code 4 | 🟡 boilerplate (CLI ergonomics, clap, envelope) | **opus-4.7-medium** | Claude Opus | after 9a/9b/9c | 3 d |
| **9e** | MCP tools (`auth_list`/`auth_status`/`auth_login_start`/`auth_login_complete`/`spider_with_auth`) with B's published JSON schemas, consent gate, `cookie_values_returned: false` invariant | 🟡 boilerplate (tool wrapping; schema correctness load-bearing) | **opus-4.7-medium** | Claude Opus | after 9a/9c/9d | 2 d |
| **9f** | stealth-sites `AuthRecipe` typed struct + loader + `AuthRefusalPolicy` enum + value-reject lint + default `RefuseByDefault` blocklist | 🟡 boilerplate (typed schema + lint) | **gpt-5.5-medium** | Codex orchestrator | parallel after 9a | 1 d |
| **9g** | E2E (axum mock + headed driver), proptest, cargo-fuzz on parsers, `AUTH-DISCLAIMER.md`, README, refusal-policy enforcement test, audit hash field tests, panic-hook test | 🟡 boilerplate (test harness + docs) | **gpt-5.5-medium** | Codex orchestrator | terminal | 2 d |

**Total:** 20 engineer-days serial, ~12 wall days with 3 parallel tracks (Codex high on 9a→9b→9c→9g; Codex med on 9f; Opus med on 9d→9e).

**Immediately dispatchable after user approval of DECISION NEEDED items:** 9a (Codex orchestrator, gpt-5.5-high, foundational, no upstream deps).

---

## Appendix: invariants (integrated)

- I1. No cookie value ever written outside `~/.config/rev_scraping/auth/` (or `.trash/`).
- I2. No cookie value ever returned by any MCP tool (`cookie_values_returned: false` enforced).
- I3. No cookie value ever logged at any tracing level (redaction layer + panic hook).
- I4. `auth login` requires (AUP allowed + `auth_allowed=true` + VPN-required passed + SSRF-guard passed + user ENTER).
- I5. Encryption key never present in any file under `~/.config/rev_scraping/`.
- I6. Public-suffix-derived eTLD+1 is the only scope key; subdomain mismatch fatal at lookup.
- I7. `stealth-core::browser` remains usable with `None` auth scope; default behavior unchanged.
- I8. Disabling `--features stealth-auth` keeps workspace green; all pre-Phase-9 tests pass.
- I9. No `Password` / `TotpSecret` / `RecoveryCode` types exist anywhere in `stealth-auth/src/` (review + grep test).
- I10. `#![forbid(unsafe_code)]` on `stealth-auth` crate.
- I11. UA captured at login is replayed at fetch (HTTP + CDP); mismatch is rejected unless recipe pins different UA.
- I12. Login proxy route == replay proxy route (default `RequireSameNamedProxy`).

---

*End of ExecPlan rev1.*
