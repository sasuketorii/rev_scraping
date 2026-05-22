<!--
  rev_scraping — README.md
  v1.2.0 GA (2026-05-22)
  Synthesized from 5 parallel Opus 4.7-high research passes
  (feature inventory, competitive analysis, architecture, security model, quickstart).
-->

# rev_scraping

> **An AI-agent-native, stealth-first web scraping toolkit for production.**
> Rust workspace · 13 crates · MCP-native (16 tools) · VPN-required by default ·
> XChaCha20-Poly1305 cookie vault · Prompt-injection sanitizer with `<<<UNTRUSTED_CONTENT>>>` envelope · systemd-grade VPS deploy.

[![tests](https://img.shields.io/badge/workspace_tests-776%20PASS%20%2F%200%20fail-success)](#test-suite)
[![python](https://img.shields.io/badge/hermes_python-20%20PASS-success)](#hermes-plugin)
[![rust](https://img.shields.io/badge/rust-1.83%2B-orange)](https://www.rust-lang.org/)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![release](https://img.shields.io/badge/release-v1.2.0-blueviolet)](RELEASE_NOTES_v1.2.0.md)
[![mcp](https://img.shields.io/badge/MCP-stdio_JSON--RPC_2.0-purple)](docs/MCP_REFERENCE.md)
[![ci](https://img.shields.io/badge/CI-8_jobs-green)](.github/workflows/ci.yml)

🇯🇵 日本語版: [README.ja.md](README.ja.md)

---

## Table of Contents

- [30-second pitch](#30-second-pitch)
- [Why rev_scraping?](#why-rev_scraping)
- [Quickstart](#quickstart)
- [16 MCP tools at a glance](#16-mcp-tools-at-a-glance)
- [Architecture](#architecture)
- [Security model](#security-model)
- [Feature catalog](#feature-catalog)
- [How it works (sequence flows)](#how-it-works-sequence-flows)
- [Use cases](#use-cases)
- [Competitive comparison](#competitive-comparison)
- [Configuration](#configuration)
- [FAQ / debugging](#faq--debugging)
- [Limitations &amp; v1.2.1 backlog](#limitations--v121-backlog)
- [Project process](#project-process)
- [License](#license)

---

## 30-second pitch

```bash
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping && cargo build --release --bin stealth-mcp --bin rev-stealth
./target/release/rev-stealth doctor --output-format json
```

You now have:

- a **`stealth-mcp` binary** that speaks Model Context Protocol (`2024-11-05`) over stdio and exposes **16 strict-schema tools** (`spider`, `auth_login_*`, `vpn_rotate`, `recipe_*`, `session_show`, …);
- a **`rev-stealth` CLI** for direct operator workflows (doctor / config / profile / hermes / auth / spider);
- a **stealth Chromium driver** (chromiumoxide + obscura CDP shim) that fills `canAccessOpener`, drops WebSocket warnings to 0, and works on a headless VPS via auto-wrapped `xvfb-run`;
- a **VPN-required gate** with continuous leak monitor (Surfshark + Gluetun, 3-instance HRW sticky pool);
- a **5-layer prompt-injection sanitizer** (`stealth-sanitize`) that wraps every tool response in `<<<UNTRUSTED_CONTENT origin=… sanitize_id=NONCE>>>` and detects 20 canary classes (100% Critical / 100% High detection on the v1.2.0 golden corpus);
- a **26-variant closed `ErrorEnvelope`** with retriable hints — so your typed agent does not need to grep stack traces;
- a **systemd 5-unit pack** (`dist/systemd/`) + `systemd-creds`-encrypted secrets for one-command VPS deploy;
- a **Python Hermes plugin** (`dist/hermes/rev-scraping-mcp/`) that spawns the MCP server with a whitelisted env (no `ANTHROPIC_API_KEY` leak to children).

**Who this is for**: defender-side red/blue teams, AI-agent operators (Claude Code / Cursor / Hermes), and analysts who need authenticated scraping with a defensible audit trail and operator-controlled egress.

**Who this is *not* for**: distributed 10 M-URL crawls, HTML→Markdown RAG ingestion at scale, GUI-managed browser fleets. See [honest limitations](#limitations--v121-backlog) — Crawl4AI / Browserless / Bright Data are correct picks for those.

---

## Why rev_scraping?

Five things the rest of the ecosystem leaves to the operator. `rev_scraping` ships them by default.

| Axis | What rev_scraping ships | What the field looks like |
|---|---|---|
| **Prompt-injection defense on scraped content** | `stealth-sanitize` 5-layer pipeline, 20 canary classes, `<<<UNTRUSTED_CONTENT>>>` envelope, `_meta.sanitize` report on every tool response. **100% Critical / 100% High detection** on the v1.2.0 golden corpus. | Crawl4AI / Playwright MCP / Puppeteer MCP / Browserless / Bright Data Web Unlocker — **all pass raw HTML/markdown to the LLM**. Cf. Crawl4AI's own MCP docs that punt the issue to "models with strong alignment." |
| **VPN-required as a precondition, not a config** | `require_vpn=true` default · leak monitor polling every 5–300 s (default 30 s) · IP/country/DNS/kill-switch/IPv6/WebRTC checks · HRW sticky 3-instance pool · `systemd-creds`-encrypted Surfshark credentials · exit code 7 on leak. | Every other tool in the comparison: VPN is operator-supplied glue. Bright Data and Browserless ship *proxy* primitives, not VPN-with-leak-stop. |
| **Encrypted credentials at rest** | XChaCha20-Poly1305 AEAD (24-byte `OsRng` nonce, 32-byte key) · key in OS keyring (Keychain / `secret-service` / DPAPI) · Argon2id passphrase fallback (`m=64 MiB, t=3, p=1`) · `Zeroizing<Vec<u8>>` + `secrecy::SecretString` plaintext lifetimes · per-profile AAD binding. | Playwright `storageState.json` **plaintext**. Puppeteer `userDataDir` **plaintext**. Scrapling / Crawl4AI / obscura / gocrawl — no session-encryption layer. |
| **Typed error contract** | 26-variant closed `ErrorKind` · `retryable: bool` + `hint` + `retry_after_ms` per envelope · compile-time arity guard (`#[forbid(unreachable_patterns)]` + exhaustive no-wildcard match). Adding a 27th variant is intentionally a breaking change. | Go `error` strings (gocrawl) · Python exception strings (Scrapling / Crawl4AI) · HTTP status + JSON `error: "..."` (Browserless / Bright Data) · Playwright/Puppeteer string exceptions. Agent ends up with `if "rate limit" in str(err)` glue. |
| **MCP-native with strict schemas** | 16 tools, **each with input *and* output JSON-Schema** auto-generated to `docs/MCP_REFERENCE.md` + CI freshness gate. `cookie_values_returned: false` marker on every auth tool response. | Crawl4AI MCP — 4 tools, errors are strings. Playwright MCP — broad surface, no closed error enum. Most MCP servers in this space return either raw markdown or HTTP-shape errors. |

Read the full [competitive comparison](#competitive-comparison) for the matrix across **8 tools × 11 axes** plus the honest list of cases where rev_scraping is the *wrong* choice.

---

## Quickstart

### Route A — Local dev (macOS / Linux)

```bash
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping
cargo build --release --bin stealth-mcp --bin rev-stealth

# seed ~/.rev_scraping/{policy.toml, authorized.toml, sites/}
./target/release/rev-stealth config init

# leak-prevention sanity check
./target/release/rev-stealth doctor --output-format json
# exit 0 = OK / exit 7 = leak detected / exit 3 = precondition fail
```

Requirements: Rust 1.83+, Chrome/Chromium 120+ on `PATH` (or `OBSCURA_BIN` set), macOS Keychain or Linux `secret-service` for the cookie vault. Windows: **not supported** in v1.2.0 (ACL TODO).

### Route B — VPS production (Ubuntu 24.04 / Debian 12+, systemd 252+)

Full runbook in [`docs/deploy/vps.md`](docs/deploy/vps.md). Short form:

```bash
# OS prereqs
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-v2 chromium-browser \
                        xvfb x11vnc ufw fail2ban unattended-upgrades

# build
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping && cargo build --release

# install systemd units (idempotent — `ln -sfn`, safe to re-run after `git pull`)
sudo ./dist/systemd/install.sh

# encrypt Surfshark credentials via systemd-creds (TPM2-sealed when available)
sudo ./dist/systemd/setup-credentials.sh

# enable VPN instances + MCP server + doctor timer
sudo systemctl enable --now rev-stealth-vpn@1 rev-stealth-vpn@2 rev-stealth-vpn@3
sudo systemctl enable --now rev-stealth-mcp rev-stealth-doctor.timer

# first-boot sanity (9 VPS deep checks)
sudo -u rev-stealth ./target/release/rev-stealth doctor --vps --output-format json \
  | tee /var/log/rev-stealth/doctor-firstboot.json
```

What `install.sh` lays down (symlinks into `/etc`, not copies):

- `rev-stealth-mcp.service` — `User=rev-stealth`, `NoNewPrivileges=yes`, `ProtectSystem=strict`, `ProtectHome=yes`, `PrivateTmp=yes`, `ProtectKernel{Tunables,Modules,ControlGroups}=yes`, `LockPersonality=yes`, `RestrictSUIDSGID=yes`, `LimitNOFILE=65536`, `Restart=on-failure RestartSec=5s`, `ReadWritePaths=/var/lib/rev-stealth /var/log/rev-stealth`.
- `rev-stealth-vpn@.service` (templated; one instance per Gluetun container).
- `rev-stealth-doctor.{service,timer}` — fires `OnBootSec=5min` + `OnUnitActiveSec=30min` (every 30 min), appends JSONL to `/var/log/rev-stealth/doctor.jsonl`.
- `rev-stealth-xvfb-vnc.service` — **opt-in** via `install.sh --with-vnc-fallback`. Localhost-bound x11vnc for emergency operator access via `ssh -L` forwarding. Not enabled by default.
- `tmpfiles.d` + `sysusers.d` configs (provisions `rev-stealth` user with `/usr/sbin/nologin`).

Credentials drop-in (operator-supplied — wires `systemd-creds` blobs to env-file paths):

```ini
# /etc/systemd/system/rev-stealth-mcp.service.d/override.conf
[Service]
LoadCredentialEncrypted=surfshark_user:/etc/credstore.encrypted/surfshark_user.cred
LoadCredentialEncrypted=surfshark_password:/etc/credstore.encrypted/surfshark_password.cred
Environment=VPN_USER_FILE=%d/surfshark_user
Environment=VPN_PASSWORD_FILE=%d/surfshark_password
```

The `<KEY>_FILE` precedence is honored by `CredentialResolver`, which **refuses** any file whose Unix mode has any owner-other bits set (`mode & 0o077 != 0`) — systemd's 0400 exposure is accepted, a hand-rolled 0644 file is refused.

### Route C — Hermes plugin

```bash
./target/release/rev-stealth hermes install
./target/release/rev-stealth hermes verify
# Hermes 起動 → 16 MCP tools auto-registered as ctx callables
```

Under the hood:

1. Scaffold copied to `~/.hermes/plugins/rev-scraping-mcp/` (override with `--prefix`).
2. `register(ctx)` spawns `stealth-mcp` with a **whitelisted env** — `REV_SCRAPING_*`, `VPN_*_FILE`, `PATH`, `HOME`, `LANG`. `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GITHUB_TOKEN`, AWS creds are **stripped before spawn**.
3. MCP `2024-11-05` handshake → `tools/list` → each tool registered via `ctx.register_tool(...)`.
4. Child crash → restart with exponential backoff `1, 2, 4, 8, 16 s` (cap 16 s).
5. Response payloads pass through `schema_bridge.redact_response` (defense in depth on top of Rust-side `stealth-sanitize`).

Override the binary location with `REV_SCRAPING_MCP_BIN`.

### AI client wiring (Claude Code / Cursor)

```json
{
  "mcpServers": {
    "rev-scraping": {
      "command": "/absolute/path/to/target/release/stealth-mcp",
      "env": {
        "REV_SCRAPING_HOME": "/home/user/.rev_scraping",
        "VPN_USER_FILE": "/run/credentials/rev-stealth-mcp/vpn_user",
        "VPN_PASSWORD_FILE": "/run/credentials/rev-stealth-mcp/vpn_password"
      }
    }
  }
}
```

Smoke test (16 tools expected):

```bash
printf '%s\n%s\n%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
  '{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}' \
  | ./target/release/stealth-mcp | jq '.result.tools | length'
# expect: 16
```

---

## 16 MCP tools at a glance

All tools share the envelope shape `{ok, operation, result, _meta: { sanitize: {...} }}` (or `{ok: false, exit_code, error}` on failure). Full input/output schemas live in [`docs/MCP_REFERENCE.md`](docs/MCP_REFERENCE.md) (auto-generated; CI gate prevents drift).

| # | Tool | Purpose |
|---|---|---|
| 1 | `spider` | Stealth-fetch an AUP-allowed URL via obscura CDP shim + optional CF challenge eval + adaptive selector relocate. Per-host rate-limited, `session_id`-idempotent. |
| 2 | `relocate` | Adaptive selector resurrection via `stealth-parse` fingerprint cache. Locates a previously-recorded element on new HTML or URL. |
| 3 | `cf_evaluate` | Cloudflare Turnstile resilience evaluator (defender-side; no solver bundled). |
| 4 | `doctor` | Leak / VPN / captcha-sidecar health diagnostics. Flat output. |
| 5 | `vpn_rotate` | Rotate VPN exit (Surfshark via Gluetun); strategies `lazy-on-fail`/`every-n`/`interval`. Emits `vpn_country_mismatch` (retriable) on region miss. |
| 6 | `recipe_list` | List all site recipes (TOML in `~/.rev_scraping/sites/`). |
| 7 | `recipe_show` | Return full `SiteRecipe` JSON for a domain. |
| 8 | `recipe_remove` | Remove a recipe; preview-by-default, commits only with `confirm=true`. |
| 9 | `recipe_propose_endpoint` | Append a new endpoint to an existing recipe; secret-bearing fields rejected. |
| 10 | `recipe_export` | Export all recipes as base64-encoded JSON array. |
| 11 | `recipe_import` | Import recipes from base64 JSON; secrets rejected, path-traversal guarded. |
| 12 | `auth_login_start` | Phase 1 of 2-phase login. AUP-enforce + spawn `rev-auth` helper. Returns single-use `session_token`. **`cookie_values_returned=false`**. |
| 13 | `auth_login_complete` | Phase 2; poll until helper finishes, returns `ProfileMeta`. Cookie *values* never leave the encrypted vault. |
| 14 | `auth_list` | List stored auth profiles (`ProfileMeta` only). |
| 15 | `auth_status` | Freshness classification: `Valid` / `ExpiringSoon` / `ExpiringCritical` / `PartiallyExpired` / `AllExpired` / `Missing`. |
| 16 | `session_show` | Persisted session metadata (VPN binding + recipe hits + auth profile). Cookie values never returned. |

**Common runtime invariants** across all 16:

- **Rate limit**: per-host token bucket (`DashMap<String, TokenBucket>`); 429 backoff clamped at `MAX_429_BACKOFF_SECS = 86400` s (closes a u64::MAX DoS path). Returns `kind: "rate_limit"` + `retry_after_ms` on exhaustion.
- **Idempotency**: Stripe-style key on `spider` / `relocate` / `cf_evaluate`. `DashMap::remove_if` atomic eviction (closes TOCTOU race).
- **AUP / SSRF**: every URL-accepting tool runs through `aup::enforce` + `ObscuraBridge::validate_url` (loopback / RFC1918 / link-local rejected).
- **Secrets**: cookie values are **never** returned through MCP. The `cookie_values_returned=false` field on every auth tool is the contract marker.

---

## Architecture

### Workspace crate graph

```mermaid
graph TD
  cli["stealth-cli<br/>(bin: rev-stealth)"]
  mcp["stealth-mcp<br/>(bin: stealth-mcp + gen_reference)"]
  auth_bin["stealth-auth<br/>(bin: rev-auth)"]

  core[stealth-core]
  contracts[stealth-agent-contracts]
  sanitize[stealth-sanitize]
  obscura[obscura-bridge]
  vpn[vpn-rotate]
  authlib[stealth-auth lib]
  mfp[mobile-fp]
  cf[stealth-cf]
  parse[stealth-parse]
  sites[stealth-sites]
  cap[captcha-bypass]

  cli --> core
  cli --> cap
  cli --> vpn
  cli --> mfp
  cli --> obscura
  cli --> cf
  cli --> parse
  cli --> sites
  cli --> authlib

  mcp --> contracts
  mcp --> sanitize
  mcp --> sites
  mcp --> authlib
  mcp -. "spawn rev-stealth bin" .-> cli

  auth_bin --> authlib
  auth_bin --> obscura
  auth_bin --> vpn

  obscura --> core
  obscura --> mfp
  vpn --> core
  core --> mfp
```

The workspace cleanly factors three execution surfaces (`rev-stealth` CLI, `stealth-mcp` MCP server, `rev-auth` login helper) over **10 library crates**, with `stealth-agent-contracts` providing the shared types that cross IPC boundaries (errors, tokens, rate limits) and `stealth-sanitize` providing the content-safety boundary.

### Three runtime topologies

#### A. Local operator mode

```
Operator shell
   │
   ▼
rev-stealth (stealth-cli binary)
   │
   ├──► vpn_guard::run_startup_probe  (require_vpn check; exit 7 on leak)
   ├──► InstancePool::pick(session_id) (HRW sticky)
   ├──► ObscuraBridge (CDP shim, SSRF guard)
   │     └──► Chrome/Chromium via chromiumoxide WebSocket
   ├──► stealth-cf (challenge detect)
   └──► stealth-parse (adaptive selector cache, SQLite WAL)
```

Authentication uses a separate binary spawned by `rev-stealth auth login`:

```
rev-stealth auth login ── spawn ──► rev-auth (stealth-auth crate)
                                       │
                                       ├──► auth_aup::enforce
                                       ├──► prepare_vpn_context (probe + monitor)
                                       ├──► chromiumoxide::Browser::launch
                                       │     (headed / headless / xvfb shim)
                                       ├──► page.get_cookies() via CDP
                                       └──► XChaCha20-Poly1305 encrypt
                                            + OS keyring store
                                            + audit JSONL
```

#### B. VPS production (systemd)

```
systemd (PID 1, system scope)
 │
 ├── rev-stealth-vpn@{1,2,3}.service   docker compose ──► Gluetun/WireGuard
 │     LoadCredentialEncrypted=surfshark_user/password.cred
 │
 ├── rev-stealth-mcp.service
 │     User=rev-stealth NoNewPrivileges=yes ProtectSystem=strict
 │     PrivateTmp=yes ReadWritePaths=/var/lib/rev-stealth /var/log/rev-stealth
 │
 ├── rev-stealth-doctor.timer ──► doctor.service
 │     OnBootSec=5min  OnUnitActiveSec=30min  Persistent=true
 │
 └── rev-stealth-xvfb-vnc.service   (opt-in localhost VNC fallback)
```

#### C. AI agent over MCP

```
Claude / GPT / Hermes (MCP client)
        │ stdio JSON-RPC 2.0
        ▼
stealth-mcp ──► dispatch_tool
        │
        ├── auth_*    → in-process (handle_auth_tool)
        ├── recipe_*  → in-process (SiteRecipeStore)
        ├── session_* → in-process (~/.rev_scraping/sessions/)
        └── spider/relocate/cf_evaluate/doctor/vpn_rotate
                                       → subprocess (rev-stealth)
                                       │
                                       ▼
                          stealth-sanitize: L4 → L5 → L3 → L2 → L7
                                       │
                                       ▼
                          JSON-RPC result with _meta.sanitize report
```

### File / process layout

| Path / process | Mode | Owner | Purpose |
|---|---|---|---|
| `/var/lib/rev-stealth/` | 0700 | `rev-stealth:rev-stealth` | service state root |
| `/var/lib/rev-stealth/vpn/` | 0700 | `rev-stealth:rev-stealth` | per-instance compose work dir |
| `/var/log/rev-stealth/` | 0750 | `rev-stealth:rev-stealth` | doctor JSONL + audit |
| `/etc/credstore.encrypted/surfshark_{user,password}.cred` | 0400 | root | systemd-creds-encrypted Surfshark |
| `~/.rev_scraping/policy.toml` | 0600 | user | VPN / require_vpn / instance descriptors |
| `~/.rev_scraping/sessions/<id>.json` | 0600 | user | HRW sticky binding metadata |
| `<user_data_dir>/rev-auth-xvfb-run.sh` | 0700 | user | auto-generated `xvfb-run` shim |
| OS keyring entry | — | user | `service=rev_scraping.stealth_auth`, `account=cookie-jar:<profile>` |

### Exit codes (canonical: `stealth-core::ExitCode`)

| Code | Variant | Meaning |
|---|---|---|
| 0 | `Ok` | success |
| 1 | `UserError` | clap parse / user input |
| 2 | `TransientError` | retriable failure |
| 3 | `PermanentError` | precondition fail (incl. Chrome unresolved) |
| 4 | `AuthExpired` | all captured cookies already expired at save time |
| 7 | `Leak` | VPN tunnel down / IP/country/DNS leak detected |

Sanitize Critical fail-closed surfaces as `isError: true` in the JSON-RPC envelope, **not** as a distinct process exit code.

---

## Security model

`rev_scraping` v1.2.0 is **fail-closed by default** at every external boundary.

### 1. Three-tier threat model

- **T1 — passive (data-at-rest, forensic)**: cookie jars XChaCha20-Poly1305 AEAD-encrypted with per-profile AAD; key never in the cookie file (OS keyring or Argon2id); plaintext lives only in `Zeroizing<Vec<u8>>`; `tracing` redaction layer + panic hook scrub cookie-shape regex from logs; audit JSONL records actions but not values (regression-tested).
- **T2 — active (intercept, DNS poison, VPN timing)**: `require_vpn=true` is the default; startup probe + continuous leak monitor (5–300 s, default 30 s; first tick immediate; **latch** semantics on first leak); country gate (`vpn_country_mismatch` → `vpn_rotate`); HRW sticky pool for session stability; `<KEY>_FILE` credential resolver rejects any file with `mode & 0o077 != 0`.
- **T3 — content-layer (prompt injection, supply-chain, Unicode covert channel)**: `stealth-sanitize` 5-layer pipeline; 20 canary rules across Aho-Corasick (literal chat-template tokens) + `regex::RegexSet` (shape rules); `<<<UNTRUSTED_CONTENT origin=… sanitize_id=NONCE>>>` envelope with 64-bit forgery-resistant nonce.

### 2. Cryptographic stack

- **Algorithm**: XChaCha20-Poly1305 AEAD (24-byte nonce, 32-byte key). 192-bit nonce makes random-nonce collision negligible; ChaCha20 is constant-time in pure software (no AES-NI dependency).
- **AAD binding**: `rev_scraping:stealth-auth:v1:<profile>[:<aad_context>]`. Wrong-AAD outcome = `AuthStoreError::BadKeyOrTamper`; cross-profile attempt = `AuthStoreError::ProfileHashMismatch` (before the cipher runs).
- **Envelope**: `MAGIC "REVAUTH1" || version u16 || profile_hash[32] || nonce[24] || ciphertext`.
- **Key source**: OS keyring (macOS Keychain / Linux `secret-service` / Windows DPAPI). Fallback `feature = "passphrase-only"` uses Argon2id (`m=64 MiB, t=3, p=1`, 32-byte output, 16-byte salt).
- **systemd-creds**: TPM2 sealing when available; otherwise host master key. Operator-installed drop-in (`/etc/systemd/system/rev-stealth-mcp.service.d/override.conf`) loads credentials at unit start; `${CREDENTIALS_DIRECTORY}/<name>` is exposed at mode `0400`.

### 3. The `stealth-sanitize` pipeline

Five layers, evaluated in this order on every MCP tool response:

| Layer | What it does | Defaults (Balanced) |
|---|---|---|
| **L4 — Unicode strip** | NFKC normalize → strip zero-width (U+200B/C/D, U+2060, U+FEFF) → strip tag chars (U+E0000–E007F) → strip bidi overrides (U+202D/E, U+2066–9). Bidi hits → Suspicious canary. | always on |
| **L5 — length clamp** | Per-field 256 KiB (Strict: 64 KiB) / total 512 KiB (Strict: 128 KiB). Over-budget → 80%-head + `[...TRUNCATED...]` + 20%-tail. | always on |
| **L3 — canary detect** | Aho-Corasick (literal chat-template tokens: `<\|im_start\|>`, `[INST]`, `<<SYS>>`, …) + `regex::RegexSet` (shape: `ignore previous instructions`, `### Instruction:`, `\bSYSTEM\s*[:>]`, `curl --data`, `data:text/html`, envelope-forgery `<<<UNTRUSTED_CONTENT`, …). **20 rules** across 3 severities. | Critical = fail-closed when `critical_fail_closed=true` · High = `[REDACTED:injection]` replace · Suspicious = report-only |
| **L2 — envelope wrap** | Surrounds each sanitized string leaf with `<<<UNTRUSTED_CONTENT origin=… tool=… sanitize_id=NONCE>>> … <<<END_UNTRUSTED_CONTENT sanitize_id=NONCE>>>`. 64-bit hex nonce per call (forgery defense). | always (skipped only when aborted) |
| **L7 — `_meta.sanitize` report** | Appends `{schema_version, policy_name, mode, bytes_in, bytes_out, truncated, aborted, layers_applied, canary_hits, sanitize_id}` to every response. `canary_hits[]` contains **id + severity + location only — never the matched bytes** (closes the descendant-pointer leak fix). | always on |

**Detection rate** (v1.2.0 golden corpus, 20 hostile + 20 benign): Critical 100% (8/8), High 100% (12/12), FP ≤ 1 Suspicious per benign fixture.

**Mode matrix**:

| Preset | Mode | Used by |
|---|---|---|
| `Strict` | `Enforce` (Critical → payload null + `aborted=true`) | `auth_login_*` |
| `Balanced` | `Warn` (default; `critical_fail_closed=true`) | most tools |
| `PassThrough` | `Off` | trusted internal calls only |

### 4. Strict UUID v4 validation

Pre-v1.2.0, `SessionId` / `ProgressToken` were `#[serde(transparent)]` over `Uuid` — `serde_json::from_str("\"00000000-0000-0000-0000-000000000000\"")` produced a valid-looking token with version 0 / variant NCS. v1.2.0 uses **manual `Serialize`/`Deserialize`** routing through:

```rust
fn is_strict_v4(u: &Uuid) -> bool {
    matches!(u.get_version(), Some(Version::Random))
        && u.get_variant() == Variant::RFC4122
}
```

**Both** conditions required — explicitly rejects `00000000-0000-4000-0000-000000000000` (v4 version, NCS variant).

### 5. Rate limit / idempotency / backoff

- **Per-host token bucket** on `Instant` (monotonic — wall-clock adjustments cannot unblock).
- **`Retry-After` clamped at `MAX_429_BACKOFF_SECS = 86400`** + `Instant::checked_add(...).unwrap_or(now)` fallback. Without the clamp, `Retry-After: 18446744073709551615` panics the limiter (process DoS).
- **Idempotency `DashMap::remove_if` atomic eviction** closes the TOCTOU race where a naive expired-eviction path could delete a freshly inserted record.

### 6. systemd hardening

The `rev-stealth-mcp.service` unit ships with `NoNewPrivileges=yes` + `ProtectSystem=strict` + `ProtectHome=yes` + `PrivateTmp=yes` + `ProtectKernel{Tunables,Modules,ControlGroups}=yes` + `LockPersonality=yes` + `RestrictSUIDSGID=yes`. The `ExecStart` uses **`exec`** (load-bearing — previous version was missing it, leaving `/bin/sh` as PID 1 of the cgroup and breaking zombie reaping).

### 7. Acceptable Use Policy (AUP)

`aup::enforce` runs before every URL-accepting subcommand. Three paths to allow:

1. `--i-have-authorization` flag (warns to stderr; operator self-attestation).
2. `REV_SCRAPING_AUP_ACK` env that matches `SHA256("rev-scraping-aup:" + YYYYMMDD)[:8]` — **valid only for the local day**.
3. `~/.rev_scraping/authorized.toml` allow-list (regex `url_pattern` per `[[targets]]`).

Rejection → exit 3 / `kind: "aup"` (non-retriable).

---

## Feature catalog

### The 13 crates

| Crate | Purpose | Key public types |
|---|---|---|
| `stealth-core` | shared traits + Chromium-backed stealth launcher | `StealthError`, `ExitCode`, `StealthProfile`, `leak_guard` |
| `mobile-fp` | mobile fingerprint presets (UA / viewport / touch / sensors / WebGL) | 6 presets: `iPhone15Pro/Max`, `iPadProM4`, `Pixel9Pro`, `Pixel8a`, `GalaxyS24Ultra`; `StealthLevel{Off,Low,Medium,High(default)}` |
| `obscura-bridge` | CDP shim + SSRF guard (vendored obscura patches statically linked) | `ObscuraBridge`, `BridgeError`, `BrowserOps`, `inject_cookies`, `validate_url` |
| `captcha-bypass` | reCAPTCHA v2/v3 / hCaptcha / Turnstile research (Node sidecar bridge) | `CaptchaKind`, `SolveRequest`, feature-gated under `sidecar` |
| `stealth-cf` | Cloudflare Turnstile resilience evaluator (defender-side) | `detect_from_html`, `CfEvaluator`, `ChallengeType` |
| `stealth-parse` | adaptive element relocation + SQLite WAL fingerprint cache | `fingerprint_from_html`, `ElementFingerprint`, `Relocator`, `ParseStore` |
| `stealth-sites` | per-domain TOML Site Recipe store | `SiteRecipe`, `SiteMeta`, `SiteRecipeStore`, `Endpoint`, `AuthRecipe` |
| `vpn-rotate` | VPN IP rotation (Surfshark/Gluetun) + leak monitor + HRW pool | `RotationStrategy`, `InstancePool`, `LeakMonitor`, `CredentialResolver` |
| `stealth-auth` | encrypted authentication cookie storage + `rev-auth` binary | `AuthStore`, `AuthCookieJar`, `Cookie` |
| `stealth-agent-contracts` | shared cross-crate contract types | `ErrorEnvelope`, `ErrorKind` (26 variants), `SessionId`/`ProgressToken` (UUID v4 strict), `ToolRateLimiter`, `IdempotencyKey`, `ProgressTracker` |
| `stealth-sanitize` | prompt-injection defense (5-layer pipeline) | `sanitize_for_agent`, `SanitizePolicy`, `Mode`, `SanitizationReport`, `CanaryHit` |
| `stealth-cli` | `rev-stealth` CLI front-end | clap-driven subcommands incl. `config_io/` (schema/validate/writer/lev/migration) |
| `stealth-mcp` | MCP stdio JSON-RPC 2.0 server + `gen_reference` binary | 16 tools, in-process dispatch for auth_*/recipe_*/session_*, subprocess for the rest |

### `rev-stealth` CLI subcommand tree

```
rev-stealth
├── doctor         leak-prevention pre-flight (kill-switch / DNS / IPv6 / WebRTC)
│                  flags: --vps (9 deep checks), --deep, --output-format {json|text}
├── spider         AUP-gated browse + optional CF eval + adaptive relocate
├── relocate       locate previously-fingerprinted element on new HTML/URL
├── cf-evaluate    Cloudflare Turnstile resilience evaluator
├── auth           {login,list,show,delete,status,refresh}
├── measure        local fingerprint diagnostics
│                  flags: --enable-external, --enable-egress-probe (feature: vps-egress-probe)
├── browser        stealth browser launch / stealth-test sweep
├── vpn            rotate / status (Surfshark + Gluetun)
├── captcha        CAPTCHA bypass (research; defaults to dry-run)
├── config
│   ├── show       merged effective config (4 layers, secrets <redacted>)
│   ├── paths      list config file paths + existence + mode
│   ├── validate   strict validate; exit 1 + issue list on violation
│   ├── diff       unified diff vs templates/policy.toml
│   ├── get <key>  resolve dotted key (e.g. policy.require_vpn)
│   ├── init       materialize ~/.rev_scraping/{policy,authorized}.toml + sites/
│   ├── set <k> <v> --target {policy|authorized}  atomic write 0600 at creation
│   ├── edit       open in $EDITOR (fallback vi); validate-then-commit
│   ├── migrate    schema_version migrate (LATEST=1)
│   ├── history    list .bak.<epoch> backups newest→oldest
│   ├── rollback <name>  restore backup (current preserved as new .bak.<epoch>)
│   ├── gc --keep N      delete older backups (default 5)
│   └── profile
│       ├── list
│       ├── create <name>  pattern [A-Za-z0-9_-]{1,64}
│       ├── switch <name>  prints shell `export REV_SCRAPING_HOME=…` line
│       └── delete <name> --yes  refuses active profile; best-effort zero-overwrite shred
└── hermes
    ├── install [--prefix <dir>] [--source <dir>] [--force]
    ├── uninstall [--prefix <dir>]
    └── verify [--prefix <dir>] [--no-python-check]
```

### Environment variables (selected)

#### Config paths / profile
- `REV_SCRAPING_HOME` — config base override (default `~/.rev_scraping`)
- `REV_SCRAPING_PROFILES_ROOT` — profile registry root (decoupled from `HOME` in P6.5)
- `REV_SCRAPING_PROFILE` — active profile name (Hermes-allowlisted)
- `REV_SCRAPING_POLICY`, `REV_SCRAPING_AUTHORIZED`, `REV_SCRAPING_AUTH_DIR` — path overrides

#### Policy / guard
- `REV_SCRAPING_REQUIRE_VPN=1` — force `require_vpn` (highest precedence)
- `REV_SCRAPING_AUP_ACK` — daily-rotating AUP ack hash
- `REV_SCRAPING_ALLOW_LOOPBACK` — loopback target allowed (dev/test only)
- `REV_SCRAPING_CONFIG_LENIENT` — relax strict validate
- `REV_SCRAPING_AUTH_PASSPHRASE` — passphrase-only mode key supply

#### VPN
- `VPN_USER_FILE`, `VPN_PASSWORD_FILE` — `<KEY>_FILE` precedence (systemd-creds)
- `VPN_USER`, `VPN_PASSWORD` — plaintext (avoid in production)
- `VPN_INSTANCES` — `name:proxy_port:control_port,...` (policy override)

#### Auth helpers
- `REV_AUTH_BIN`, `REV_AUTH_CHROME_BIN`, `REV_AUTH_AUTO_XVFB`, `REV_AUTH_DISPLAY`, `REV_AUTH_HEADLESS`
- `REV_OBSCURA_BIN` / `OBSCURA_BIN` — obscura subprocess path
- `REV_STEALTH_CHROME` — Chrome override (stealth-cli side)
- `REV_STEALTH_SIDECAR` — captcha-bypass Node sidecar path

#### Other
- `REV_SCRAPING_MCP_BIN` — Hermes adapter `stealth-mcp` path override
- `REV_STEALTH_BIN` — MCP-side CLI binary override
- `REV_STEALTH_EGRESS_PROBE_URL` — `measure --enable-egress-probe` probe URL
- `EDITOR` — `config edit` fallback (default `vi`)
- `RUST_LOG` — `tracing-subscriber` EnvFilter

---

## How it works (sequence flows)

### Flow A — `auth_login_start` → `auth_login_complete`

```
1. MCP receives  tools/call {name: auth_login_start, args: {profile, url, ...}}
2. server.rs    is_auth_tool → handle_auth_tool
3. rev-auth     auth_aup::enforce(domain, url)            → AUP gate
4. rev-auth     ObscuraBridge::validate_url(login_url)    → SSRF guard
5. rev-auth     publicsuffix eTLD+1 normalize
6. rev-auth     prepare_vpn_context().await
                  ├─ load policy.toml
                  ├─ InstancePool::pick(session_id) — HRW sticky
                  ├─ leak_guard::probe_all(instances, expected_country)
                  └─ LeakMonitor::spawn(5–300s, default 30s, FIRST TICK IMMEDIATE)
7. rev-auth     resolve_login_display_mode
                  ├─ --headless → Headless
                  ├─ --xvfb → Xvfb (auto-generate <user_data_dir>/rev-auth-xvfb-run.sh @0700)
                  ├─ Linux + DISPLAY unset + REV_AUTH_AUTO_XVFB=1 → Xvfb
                  └─ otherwise → Headed (macOS Auto)
8. rev-auth     chromiumoxide::Browser::launch — operator interacts
9. MCP polls    auth_login_complete waits on <TMPDIR>/rev-auth-<token>.complete
                  ├─ timeout → ErrorKind::AuthSessionExpired + retry_after_ms
                  └─ helper finishes → continue
10. rev-auth    page.get_cookies() via CDP
                  ├─ filter_cdp_cookies → eTLD+1 only
                  ├─ all_cookies_expired → exit 4
                  └─ otherwise:
                       ├─ crypto::encrypt (XChaCha20-Poly1305 + 24-byte OsRng nonce
                       │   + AAD: rev_scraping:stealth-auth:v1:<profile>)
                       ├─ keystore.set(service=rev_scraping.stealth_auth, account=cookie-jar:<profile>)
                       └─ audit::append_jsonl(start + success events)
11. teardown    browser.close → sleep(CHROME_TEARDOWN_FLUSH_MS=1500ms) → browser.wait
                                → handler_task.abort → profile_dir.cleanup
12. MCP wraps   sanitize_structured("auth_login_complete", result) → _meta.sanitize → JSON-RPC out
```

### Flow B — `spider`

```
1. MCP receives  tools/call {name: spider, args: {url, session_id?, ...}}
2. server.rs    NOT in-process → build_cli_argv("spider", args) → rev-stealth subprocess
3. rev-stealth  policy load → InstancePool::pick(session_id) → leak_guard::probe_all
                  exit 7 on leak (StealthError::Leak)
4. rev-stealth  ObscuraBridge launch → CDP shim → SSRF guard
5. rev-stealth  optional stealth-cf evaluate → challenge handling
6. rev-stealth  fetch via HRW-picked VPN proxy
7. rev-stealth  stealth-parse stable_id relocate (if recipe carries one)
8. server.rs    capture stdout (parse as JSON; on parse failure → {"raw": "..."})
9. server.rs    sanitize_structured("spider", body)
                  L4 → L5 → L3 → L2 → L7
                  policy_for_tool("spider") = Balanced (Warn mode, 256/512 KiB)
10. server.rs   emit JSON-RPC result with content + structuredContent + _meta.sanitize
                  + isError = !out.status.success() + exitCode
                stderr separately sanitized
```

### Flow C — VPN leak-monitor loop

```
1. systemd starts rev-stealth-vpn@N → docker compose up -d Gluetun container
2. stealth-cli   vpn_guard::run_startup_probe
                   ├─ require_vpn=false → Ok(None)
                   ├─ require_vpn=true + no instances → Err(Leak) → exit 7
                   └─ probe_all(instances, expected_country) → JSON to spider envelope
3. LeakMonitor::spawn(instances, expected_country, interval)
   interval clamp [5s, 300s], default 30s
   first tick FIRES IMMEDIATELY
4. each tick: probe_once → ProbeVerdict::{Healthy, Leak{instance, reason}}
5. on Leak:
     leak_detected=true (latch — no further polling)
     notify_waiters() via tokio::sync::Notify
     state.reason / failed_instance written
6. fetcher (caller) uses tokio::select! to race work vs notify:
     notify.notified() → bridge.force_kill() → return Err(StealthError::Leak(reason))
     work_future       → continue
7. InstancePool::mark_failure(name) per fail → 3 consecutive → 60s exclusion
   mark_success resets; all_failed() is fail-closed sentinel
8. systemd Restart=on-failure RestartSec=5s on doctor/vpn/MCP units
```

### Flow D — `stealth-sanitize` 5-layer pipeline

```
input: serde_json::Value (raw tool output)
   │
   ▼
[L4 unicode] NFKC → zero-width strip → tag-char strip → bidi-override strip
              bidi hit emits Suspicious canary
   │
   ▼
[L5 clamp] per-field 256 KiB / total 512 KiB (Balanced)
            over-budget → 80%-head + "[...TRUNCATED...]" + 20%-tail
            sets report.truncated = true
   │
   ▼
[L3 canary] Aho-Corasick (literal) + RegexSet (shape) → 20 rules
              Critical (Enforce + critical_fail_closed) → matched region cleared
                                                          + payload = Value::Null
                                                          + report.aborted = true
              High        → replace match with "[REDACTED:injection]"
              Suspicious  → report-only
              report.canary_hits[] = {id, severity, location}
                            NEVER contains matched bytes
   │
   ▼  (skipped if aborted)
[L2 envelope] wrap each string leaf with:
              <<<UNTRUSTED_CONTENT origin=<ctx.origin> tool=<ctx.tool>
                 sanitize_id=<64-bit-hex-nonce>>>>
              ...sanitized content...
              <<<END_UNTRUSTED_CONTENT sanitize_id=<same-nonce>>>>
              forgery defense: body cannot pre-bake END marker without nonce
   │
   ▼
[L7 meta] append _meta.sanitize = {schema_version, policy_name, mode,
                                    bytes_in, bytes_out, truncated, aborted,
                                    layers_applied[], canary_hits[], sanitize_id}
   │
   ▼
output: SanitizedEnvelope { payload, report }
```

---

## Use cases

### 1 — Periodic scrape of an authenticated members-only site

```bash
rev-stealth config init
cp templates/sites/example.com.toml ~/.rev_scraping/sites/myfinance.toml
$EDITOR ~/.rev_scraping/sites/myfinance.toml   # site.domain, [auth], [api.endpoints]

# 2-phase login (operator interacts with the spawned browser once)
rev-stealth auth login --profile myfinance_main --url https://myfinance.example/login

# freshness classification before next cron tick
rev-stealth auth status --profile myfinance_main --format json
# → Valid | ExpiringSoon | ExpiringCritical | PartiallyExpired | AllExpired | Missing

# cron (weekdays 09:00 JST)
# 0 9 * * 1-5 /usr/local/bin/rev-stealth spider \
#   --url https://myfinance.example/portfolio --profile myfinance_main --format json \
#   >> /var/log/rev-stealth/myfinance-$(date +\%F).jsonl
```

Spider response (excerpt):

```json
{
  "ok": true,
  "operation": "spider",
  "result": {
    "session_id": "7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01",
    "recipe": {"domain": "myfinance.example", "hits": ["/portfolio"]},
    "api_response": {"status": 200, "body_sha256": "..."}
  },
  "_meta": {"sanitize": {"schema_version": 1, "canary_hits": [], "aborted": false}}
}
```

### 2 — Cloudflare-protected JSON API behind a Turnstile challenge

```json
{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{
  "name":"cf_evaluate","arguments":{"url":"https://protected.example/login"}}}

{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{
  "name":"spider","arguments":{
    "url":"https://protected.example/api/quotes",
    "cf_evaluate": true,
    "session_id": "7c3e3b8a-3b2e-4e57-9a8a-1e1c1f6d7a01"}}}
```

Shared `session_id` lets `spider` reuse the challenge cookie within its idempotency window. Failure with `kind:"captcha"` is **non-retriable** — switch to an authenticated profile or solve out-of-band.

### 3 — VPS as 24/7 AI agent eyes

```bash
sudo systemctl enable --now rev-stealth-mcp rev-stealth-doctor.timer
sudo systemctl enable --now rev-stealth-vpn@1 rev-stealth-vpn@2 rev-stealth-vpn@3
tailscale up --ssh   # optional private mesh; not bundled with rev_scraping
```

Workstation Claude Desktop config (SSH-spawned MCP server):

```json
{"mcpServers": {"rev-scraping-vps": {
  "command": "ssh",
  "args": ["operator@vps.tailnet.ts.net", "sudo", "-u", "rev-stealth",
           "/usr/local/bin/stealth-mcp"]}}}
```

Health timer fires every 30 min, writes JSON to `/var/log/rev-stealth/doctor.jsonl`. Leak detect → exit 7 → unit goes `failed` → operator alert (wire your own).

### 4 — Parallel JP / US / EU exit IPs against the same site

```json
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{
  "name":"vpn_rotate","arguments":{
    "provider":"surfshark","region":"JP","strategy":"lazy-on-fail",
    "reason":"warmup JP exit for nikkei feed"}}}
```

Success:

```json
{"ok":true,"operation":"vpn.rotate",
 "result":{"instance":"vpn-1","exit_ip":{"country":"JP","asn":"AS9009"},"reason":"warmup ..."}}
```

VPN-specific error variants (closed set): `vpn_not_configured` (non-retriable), `vpn_all_instances_failed` (retriable), `vpn_country_mismatch` (retriable, retry with different region hint).

### 5 — Verify the prompt-injection sanitizer

```bash
./target/release/stealth-mcp <<'EOF' | jq '.result._meta.sanitize'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"canary","version":"0"}}}
{"jsonrpc":"2.0","method":"notifications/initialized","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"spider","arguments":{"url":"https://canary-fixtures.local/critical-01"}}}
EOF
```

Expected (Critical canary hit):

```json
{
  "schema_version": 1,
  "aborted": true,
  "canary_hits": [{"id": "C-IGNORE-PREV", "severity": "Critical", "location": "$.result.html"}]
}
```

Envelope carries `isError: true`; `env.message` is preserved (no raw bytes — only canary IDs).

### 6 — Multi-environment same-host with profiles

```bash
rev-stealth config profile create dev
rev-stealth config profile create staging
rev-stealth config profile list

rev-stealth config profile switch dev          # prints export line — eval it in your shell
export REV_SCRAPING_HOME="$HOME/.rev_scraping/profiles/dev"
rev-stealth config show --format json | jq '.profile, .config_root'
```

Notes:
- **Registry root** (`REV_SCRAPING_PROFILES_ROOT`) and **activation root** (`REV_SCRAPING_HOME`) are deliberately decoupled.
- `switch` only updates the registry pointer — `export REV_SCRAPING_HOME=…` in shell is what actually activates.
- Active profile delete is refused; switch first.

### 7 — Schema migration

```bash
rev-stealth config validate --format json
rev-stealth config migrate --dry-run
rev-stealth config migrate           # atomic 0600 write at creation; chmod-after race-free
rev-stealth config history
rev-stealth config rollback --to <history_id>
rev-stealth config gc                # default --keep 5
```

Migration loop is bounded (no infinite chain).

---

## Competitive comparison

Legend: ✅ first-class · 🟡 partial / plugin / operator-supplied · ❌ not supported

| Axis | rev_scraping v1.2.0 | gocrawl | Scrapling 0.4 | obscura | Playwright | Puppeteer | Crawl4AI 0.8 | Browserless | Bright Data Unlocker |
|---|---|---|---|---|---|---|---|---|---|
| Language / runtime | Rust workspace (13 crates) | Go | Python | Rust (V8) | TS/Py/Java/.NET | TS / Node | Python | Managed (Node) | SaaS API |
| Stealth (CDP patch + FP) | ✅ obscura CDP shim, 11+ field patch, WS warn=0 | ❌ (HTTP only) | ✅ Patchright + humanized input | ✅ per-session GPU/screen/canvas/audio/battery randomization | 🟡 `playwright-stealth` plugin; **unmaintained since Mar 2023** | 🟡 community `puppeteer-extra` | 🟡 inherits Playwright | ✅ BrowserQL / `/unblock` | ✅ AI unlocking (opaque) |
| VPN-required gate | ✅ Surfshark + Gluetun + 3-instance HRW + leak monitor + exit 7 | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 residential-proxy add-on | 🟡 proxy is the product |
| Encrypted credentials | ✅ XChaCha20-Poly1305 + OS keyring + Argon2id fallback | ❌ | 🟡 cookies via fetcher, no enc | 🟡 standard CDP storage | ❌ `storageState.json` **plaintext** | ❌ `userDataDir` **plaintext** | ❌ | 🟡 server-side opaque | N/A |
| MCP-native agent interface | ✅ stdio JSON-RPC 2.0, **16 tools with input + output schemas** | ❌ | ✅ MCP server (v0.4) | 🟡 3rd-party wrappers | ✅ Microsoft official | 🟡 community | ✅ 4 tools | ✅ hosted at `mcp.browserless.io` | ❌ |
| **Prompt-injection defense** | ✅ `stealth-sanitize` 5-layer · 20 canary · 100% Critical/High detect · `<<<UNTRUSTED_CONTENT>>>` envelope · `_meta.sanitize` | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ raw markdown to LLM (selling point) | ❌ | ❌ raw HTML/markdown |
| Closed-enum error contract | ✅ 26 ErrorKind + retriable + hint + UUID v4 strict | ❌ Go strings | ❌ Python exception strings | 🟡 Rust `Result`, no catalog | ❌ | ❌ | ❌ HTTP status + JSON | 🟡 | 🟡 |
| Idempotency (Stripe-style) | ✅ key + `Retry-After` clamp | ❌ | ❌ | ❌ | ❌ | ❌ | 🟡 host-side rate limit only | 🟡 concurrency units | 🟡 quota only |
| Production deploy | ✅ systemd 5 units + systemd-creds + Xvfb auto-wrap | 🟡 binary | 🟡 pip | 🟡 binary | 🟡 | 🟡 | ✅ Docker + self-host guide | ✅ SaaS / self-host license | ✅ SaaS |
| License | MIT | BSD-3 | BSD-3 | Apache-2.0 | Apache-2.0 | Apache-2.0 | Apache-2.0 | proprietary | proprietary |
| Activity (2026-05) | v1.2.0 current | last tag **2021** | v0.4 (2026-02) | active | active | active | active | active SaaS | active SaaS |

### Axis-by-axis (selected)

**Stealth** — `playwright-stealth` is unmaintained since March 2023 (Chrome 109–112 era), and 2026 anti-bot stacks fingerprint on TLS / HTTP/2 SETTINGS frames *before* JavaScript runs — JS-layer `navigator.webdriver = undefined` is moot. rev_scraping integrates obscura's CDP shim as a Rust crate (no plugin drift), but does not match Browserless / Bright Data on residential IP diversity (we ship VPN, not a 150M-IP pool). If your target is Akamai Bot Manager with strict ASN reputation, a SaaS unlocker is the pragmatic choice.

**AI-agent-native MCP** — rev_scraping's bet is **strict schemas + closed `ErrorEnvelope`**. Most MCP servers in this space return raw markdown or HTTP-shape errors; consumers end up with `if "rate limit" in str(err)` glue. We return `ErrorKind::RateLimited{retry_after_ms}` as a typed envelope. Worth it for typed agent consumers; overhead for one-off scripts.

**Prompt-injection defense** — this is the single largest differentiator. **No other tool in the table does this.** Crawl4AI's own MCP server docs acknowledge prompt injection as an *agent-side* concern to be solved by "models with strong alignment" — i.e., not addressed at the server. A canary-tested sanitizer with a marker envelope is not a panacea (no sanitizer is), but it converts the issue from "silent compromise" to "logged + rejected + reviewable." For agents with **write capability** (file writes, tool calls, MCP fan-out), this matters more than stealth.

### Where rev_scraping is the wrong choice (honest)

| Use case | Pick instead | Why |
|---|---|---|
| Distributed crawl across 10M+ URLs | Crawl4AI / Scrapy lineage | Single-machine; no distributed work queue. |
| HTML → Markdown ingestion for RAG | Crawl4AI / Bright Data | Crawl4AI's entire product is clean markdown for LLMs. |
| GUI-managed browser fleet / live debug | Browserless / Bright Data | We are CLI + systemd. No fleet dashboard. |
| Cross-language client SDKs | Playwright (TS/Py/Java/.NET) | We are Rust + Python (Hermes adapter). |
| Community-size-bound projects | Playwright / Puppeteer | Single-vendor codebase vs. Microsoft / Google ecosystems. |

**One-line summary**: rev_scraping is the right choice when the workload is **a typed AI agent driving authenticated, members-only sessions from a hardened single VPS, with prompt-injection-safe content delivery and egress-IP-leak guarantees as non-negotiables**.

---

## Configuration

### File layout (`~/.rev_scraping/`)

```
~/.rev_scraping/                          # default base (override: REV_SCRAPING_HOME)
├── policy.toml                           # mode 0600 — VPN / require_vpn / instances
├── authorized.toml                       # mode 0600 — AUP allow-list
├── sites/                                # mode 0700 — per-domain SiteRecipe TOMLs
├── sessions/                             # mode 0700 — HRW sticky session bindings
└── profiles/                             # mode 0700 — multi-environment registry
    ├── dev/
    ├── staging/
    └── prod/
```

### `policy.toml` essentials

```toml
schema_version = 1                        # bounded migration (LATEST=1)
require_vpn = true                        # fail-closed default
vpn_required_country = "JP"               # ISO-2 / alias table

[[vpn_instances]]
name = "vpn-1"
http_proxy_port = 18801
control_port = 18831

[proxies.gluetun]
strength = "high"
url = "http://${VPN_USER}:${VPN_PASSWORD}@vpn-1:18801"   # ${VAR} placeholders REQUIRED
                                                          # plaintext user:pass = LOAD REJECT
auth_env = "VPN_USER"
no_proxy = "127.0.0.1,localhost"

[fallback_chain]
auto = ["gluetun", "direct"]              # tier order; "auto" itself is forbidden
```

`require_vpn` precedence (highest first): env `REV_SCRAPING_REQUIRE_VPN=1` > `--require-vpn` flag > `--allow-no-vpn` flag > `policy.toml::require_vpn` > built-in default `true`.

`ConfigWriter` writes via `OpenOptions::new().write(true).create_new(true).mode(0o600).open()` — permissions set **at creation**, no chmod-after race window.

---

## FAQ / debugging

**Q: `rev-stealth doctor` exits 7.**
A: VPN tunnel down / leak detected. `systemctl status rev-stealth-vpn@1` and `docker compose logs vpn-1`. `doctor --output-format json` shows which of `kill_switch` / `dns_lock` / `webrtc_guard_present` / `exit_ip_ok` is false.

**Q: Cookies disappear / `auth_status` returns `Missing`.**
A: Keyring permission. macOS: `security find-generic-password -s rev_scraping.stealth_auth`. Linux: `secret-tool search service rev_scraping.stealth_auth`. After profile switch, did you `export REV_SCRAPING_HOME=…`?

**Q: VPS Chrome won't start (`Failed: no $DISPLAY`).**
A: Auto-Xvfb didn't trigger. Either set `REV_AUTH_AUTO_XVFB=1` + ensure `xvfb-run` is on PATH, or use `--with-vnc-fallback` (opt-in xvfb-vnc service) + drop-in `Environment=DISPLAY=:99`.

**Q: MCP tool call returns `_meta.sanitize.aborted: true` + `isError: true`.**
A: Critical canary detected. `canary_hits[].id` + `severity` indicates which rule. Critical hits fail closed (Enforce + `critical_fail_closed`). Operator-side intent: re-fetch with `Preset::Balanced` policy if false positive (e.g., a security blog quoting `[INST]`).

**Q: `config profile switch dev` doesn't change anything.**
A: `switch` updates the registry, but `REV_SCRAPING_HOME` is per-shell. Run the printed `export` line (or open a new shell). Verify with `config show --format json | jq '.profile, .config_root'`.

**Q: `vpn_rotate` returns `kind: "vpn_country_mismatch"`.**
A: Requested region not present in pool. Retriable — try a different region. `docker compose logs vpn-N` for Gluetun handshake details.

**Q: `recipe_import` returns `kind: "recipe_invalid"` / secret-rejected.**
A: Payload contains a secret-shaped field (token / password). Strip before export → import. v1.2.1 will add `recipe_import` strict mode (refuses recipes whose fields trip canaries).

**Q: `tools/call` returns `kind: "aup"`.**
A: URL not on `authorized.toml` allow-list. Or fails SSRF guard (`kind: "ssrf"` — loopback / RFC1918 / link-local). Both non-retriable.

**Q: Hermes plugin shows fewer than 16 tools.**
A: `stealth-mcp` binary not built or not on PATH. Set `REV_SCRAPING_MCP_BIN` to the absolute path. `cd dist/hermes/rev-scraping-mcp && python3 -m unittest discover tests -v` for adapter smoke.

**Q: `LoadCredentialEncrypted=` fails at unit start.**
A: systemd < 252, or `/etc/credstore.encrypted/` missing. `systemctl --version`; re-run `setup-credentials.sh`.

**Q: `auth_login_complete` returns `kind: "auth_session_not_found"` on the second call.**
A: `session_token` is **single-use**. Re-run `auth_login_start` for a new token.

**Q: `doctor --vps` JSON is unexpectedly an array.**
A: v1.2.0 changed it to top-level array. Old `{doctor, vps}` object form is gone.

---

## Limitations & v1.2.1 backlog

Carried verbatim from [`RELEASE_NOTES_v1.2.0.md`](RELEASE_NOTES_v1.2.0.md) so adopters know the exact residual risk:

- **L1 — ammonia HTML scrub.** v1.2.0 has no HTML sanitization. Hidden text (`<span style="display:none">`), JSON-LD blocks relocated into the visible flow, and SVG `<script>` payloads reach the LLM unmodified.
- **L6 — URL scheme allowlist + length cap.** `javascript:`, `file:`, oversized `data:` URLs are not filtered at the URL layer.
- **Multilingual canaries.** Canary regex set is English-only. JP / ZH / KR / RU pattern packs are v1.2.1 backlog.
- **Hermes Python mirror sanitizer.** Sanitize runs on the Rust side; a Python adapter that re-serializes content downstream bypasses it.
- **`recipe_import` strict mode.** Imported recipes are not run through the canary engine (T3 supply-chain vector).
- **Enforce-mode default flip.** v1.2.0 ships `Warn` default with `Critical-only` fail-closed. v1.2.1 will flip Enforce default.
- **L2 envelope idempotence on re-scan.** Sanitizing already-sanitized payload re-trips envelope canary because the marker matches its own pattern.
- **Site-specific policy overrides.** Today per-tool policy is the only granularity. v1.2.1 adds per-target overrides keyed on domain.
- **Tamper-evident audit log.** v1.2.0 audit JSONL has no HMAC chain, no rotation, no TPM sealing.
- **OS support.** macOS / Linux only. Windows ACL TODO; not production in v1.2.0.
- **Distributed scope.** Single-machine. No distributed crawl.
- **Known flake.** `auth_login_with_allow_no_vpn_skips_probe` races on process-wide `REV_SCRAPING_REQUIRE_VPN` env at `--test-threads=4`. CI uses `--no-fail-fast`.

---

## Project process

v1.2.0 landed **30 sub-phases** across 6 lanes (A: VPS, B: Config UX, C: Agentability, D: Hermes, E: Docs/CI, F: Injection defense) via an Opus 4.7-high coder × Codex gpt-5.5-high reviewer loop:

- Canonical wrapper: `scripts/codex-wrapper.sh --role reviewer --stdin` (raw `codex exec` prohibited).
- Slice ≤ 2 KB / max 3 review rounds per slice.
- Evidence: `.agent/active/prompts/*.md` (committed) + `REV_HARNESS_DELEGATION_METRIC` line per round.

CI (8 jobs, [`.github/workflows/ci.yml`](.github/workflows/ci.yml)):

- `rust-test` — `cargo test --workspace --locked --no-fail-fast`
- `rust-clippy` — `cargo clippy --workspace --all-targets -- -D warnings`
- `rust-fmt-check` — `cargo fmt --check`
- `mcp-schema-lint` — `cargo run -p stealth-mcp --bin gen_reference -- --check` (freshness gate)
- `config-cli-smoke` — `rev-stealth config init --target=policy --non-interactive --force` in tmpdir
- `hermes-contract` — `python3 -m unittest discover dist/hermes/rev-scraping-mcp/tests` (20 PASS)
- `systemd-analyze` — `systemd-analyze verify dist/systemd/system/*.{service,timer}` (Ubuntu 24.04 / systemd 255)
- `headless-auth` — placeholder skip (Xvfb-dependent; future Linux job)

### Test suite

- **Workspace**: 776 PASS / 0 fail / 38 ignored (`cargo test --workspace --no-fail-fast`)
- **Python (Hermes)**: 20 PASS / 0 fail
- **Sanitize golden corpus**: 20 hostile + 20 benign → Critical 100%, High 100%, FP ≤ 1 Suspicious/page

### Security fixes called out in v1.2.0

1. UUID v4 forgery (transparent deserialize)
2. `Retry-After: u64::MAX` Instant overflow DoS
3. Idempotency expired-eviction TOCTOU race
4. `ConfigWriter` chmod-after permission window
5. systemd `ExecStart` missing `exec` (zombie reaping)
6. docker-compose `${VPN_USER}` interpolation collision
7. `doctor --vps` JSON shape (`{doctor, vps}` → top-level array)
8. Hermes Python `readline()` deadline bypass
9. Hermes `start()` fd leak on handshake-fail
10. Hermes `env=` ctor bypassed `filter_env` (smuggling)
11. `auth.rs` CLI `--python-check=false` parse regression
12. `stealth-sanitize` descendant pointer key-leak in canary reports

### ErrorEnvelope — the 26 closed `ErrorKind` variants

| # | Wire name | When emitted | Retriable | Hint |
|---|---|---|---|---|
| 1 | `aup` | AUP allow-list violation | no | Confirm AUP allow-list + robots.txt |
| 2 | `ssrf` | private/internal target | no | Do not request loopback/RFC1918/link-local |
| 3 | `vpn_leak` | VPN egress would have leaked | yes | Bring VPN up; re-run `doctor`; rotate |
| 4 | `rate_limit` | per-host / global rate limit exceeded | yes | Honor `retry_after_ms` |
| 5 | `timeout` | operation exceeded budget | yes | Retry with larger budget |
| 6 | `captcha` | captcha challenge not bypassable | no | Switch to authenticated flow |
| 7 | `auth` | auth/authz failure | no | Re-run `auth_login_start` |
| 8 | `not_found` | target resource not found | no | Verify URL / recipe / profile |
| 9 | `validation` | input validation failure | no | Inspect `message`; fix field |
| 10 | `network` | transport failure | yes | Retry with backoff |
| 11 | `internal` | unclassified internal error | no | Capture logs, file a bug |
| 12 | `recipe_not_found` | recipe lookup failed | no | `recipe_list` to see available |
| 13 | `recipe_invalid` | recipe schema/semantic invalid | no | Fix and re-import |
| 14 | `auth_session_expired` | `auth_login_complete` polled past timeout | yes | Re-run `auth_login_start` |
| 15 | `auth_session_not_found` | `session_token` unknown | no | Start new login flow |
| 16 | `auth_session_pending` | helper not yet finished | yes | Poll again after delay |
| 17 | `vpn_not_configured` | rotation requested but no backend | no | Configure in policy.toml |
| 18 | `vpn_all_instances_failed` | every instance failed | yes | Wait; check provider |
| 19 | `vpn_country_mismatch` | resolved country ≠ policy | yes | Retry rotation with different region |
| 20 | `cdp_protocol` | CDP unexpected error | yes | Retry; check Chrome version |
| 21 | `cdp_disconnected` | CDP WebSocket disconnected | yes | Retry; relaunch browser |
| 22 | `cdp_injection_failed` | stealth JS inject failed | yes | Re-run; verify obscura |
| 23 | `browser_crashed` | headless browser crashed | yes | Retry; capture core if reproducible |
| 24 | `browser_not_found` | binary not on PATH | no | Install Chrome or set `OBSCURA_BIN` |
| 25 | `cookie_decrypt_failed` | on-disk cookie store unreadable | no | Re-create auth profile |
| 26 | `aborted` | cancelled by caller | yes | Resume if still desired |

---

## License

MIT. See [LICENSE](LICENSE).

### Acknowledgments

- **obscura** ([h4ckf0r0day/obscura](https://github.com/h4ckf0r0day/obscura)) — CDP shim foundations.
- **Scrapling** ([D4Vinci/Scrapling](https://github.com/D4Vinci/Scrapling)) — adaptive selector resurrection design (BSD-3 reference).
- **chromiumoxide** — CDP transport.
- **Gluetun** — Surfshark / WireGuard container.
- **systemd-creds + TPM2** — credential sealing.

Built by a sole human operator + Opus 4.7-high coder + Codex gpt-5.5-high reviewer over ~8 hours of orchestrated parallel work.
