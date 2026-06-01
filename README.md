<!--
  rev_scraping — README.md
  Agent-native, stealth-oriented scraping toolkit (Rust).
  This README is written to be honest: every capability is marked
  "works today / feature-gated / roadmap" so first-time readers and
  AI agents alike know exactly what they get. A Japanese mirror lives in README.ja.md.
-->

# rev_scraping

> **An AI-agent-native, stealth-oriented web-scraping toolkit, written entirely in Rust.**
> A single `rev-stealth` CLI **and** an MCP server expose the same operations, so a Claude / Codex
> agent can scrape, manage authenticated sessions, and evaluate anti-bot surfaces **as native tools** —
> while an encrypted cookie vault and a prompt-injection sanitizer treat the open web as hostile by default.

[![workspace tests](https://img.shields.io/badge/workspace_tests-911%20PASS-success)](#engineering)
[![rust](https://img.shields.io/badge/rust-1.83%2B-orange)](https://www.rust-lang.org/)
[![unsafe](https://img.shields.io/badge/unsafe__code-forbid-success)](#engineering)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![MCP](https://img.shields.io/badge/MCP-stdio_JSON--RPC_2.0-purple)](#mcp-server--claude-code-integration)

---

## Table of contents

- [What is rev_scraping?](#what-is-rev_scraping)
- [Why this project exists](#why-this-project-exists)
- [Why it's different (for AI-agent developers)](#why-its-different-for-ai-agent-developers)
- [Feature overview](#feature-overview)
- [Honest capability status](#honest-capability-status) ← **read this first**
- [Quickstart (build from source)](#quickstart-build-from-source)
- [Manual: command reference](#manual-command-reference)
- [MCP server & Claude Code integration](#mcp-server--claude-code-integration)
- [Security & responsible use](#security--responsible-use)
- [How it compares](#how-it-compares)
- [Roadmap](#roadmap)
- [Engineering](#engineering)
- [License](#license)

---

## What is rev_scraping?

rev_scraping is a **Rust workspace (13 crates, `#![forbid(unsafe_code)]` everywhere)** that turns web
scraping into something an AI agent can drive safely. At its core is a real **fetch → render → parse →
dump** pipeline powered by a *vendored Rust headless browser* (`obscura`) with a transparent `reqwest`
HTTP fallback. Around that core it adds the things agent workflows actually need: a **stable CLI** with
JSON/YAML output and a documented exit-code taxonomy, an **MCP server** that exposes the same operations
as callable tools, an **encrypted credential vault**, and a **prompt-injection sanitizer** that fences
untrusted page content before it can reach your model.

It is strongest as an **agent-callable, security-conscious scraping engine you build from source**. It is
**not** a turnkey anti-bot / captcha-bypass product — see the [capability status](#honest-capability-status).

## Why this project exists

The faster AI advances, the closer every one of us moves to the blast radius of a new generation of
automated attacks. Most people — and most organizations — invest only in the **fundamentals of defense**.
That is necessary, but it is not sufficient: **if you have never seen how an attacker actually operates,
you cannot see where your own walls have gaps.**

rev_scraping was built to close that blind spot. It is a stealth-capable scraping toolkit made
*deliberately legible* — so that defenders, researchers, and builders can study offensive web-automation
techniques first-hand, in the open, on systems they are authorized to test. You cannot defend against a
technique you have never examined.

Real adversaries already operate with stealth many times more sophisticated than anything shipped here,
and they are already pointed at us. The aim of this project is **not** to out-hide them — it is to put
credible, inspectable offensive tooling in the hands of the people building the next generation of
defenses, and to contribute, in a small way, to the security technology the AI era now demands.

> **This is defensive security research.** Every network operation is gated behind an explicit
> `--i-have-authorization` flag and a VPN-required posture. Use it only against systems you own or are
> contracted to test. See [Security & responsible use](#security--responsible-use).

## Why it's different (for AI-agent developers)

- **MCP-native out of the box.** Point Claude Code (or any MCP client) at the `stealth-mcp` stdio server
  and the agent gets 16 tools — scrape, re-locate drifted elements, manage logins, evaluate challenge
  surfaces — with **no glue code**.
- **Treats scraped data as hostile.** Untrusted HTML is wrapped in an `<<<UNTRUSTED_CONTENT>>>` envelope,
  scanned for prompt-injection canaries, unicode-normalized, and length-clamped before it reaches a model.
  Most scrapers hand raw page text straight to your LLM; this one does not.
- **Structured, dependable outputs.** Every command emits a uniform JSON envelope and a stable exit code
  (`0` ok / `1` user / `2` transient / `3` permanent / `4` auth-expired / `7` leak), so agent retry /
  escalation loops can branch deterministically. Errors carry a `doc_url` to a per-error page.
- **Memory-safe single binary.** All-Rust, `forbid(unsafe)`, bundled SQLite + crypto, vendored browser —
  drops cleanly into a CI sandbox.

## Feature overview

**Core scraping**
- **`spider`** — fetch a URL through the obscura browser (real navigation + JS) or pure HTTP, and dump the
  rendered HTML. Auto-falls back to `reqwest` when the browser path fails.
- **Site recipes** (`stealth-sites`) — per-domain cache of *how* to scrape a site (endpoints, render mode,
  anti-bot posture), reusable across runs.
- **Adaptive parsing** (`stealth-parse`) — fingerprints DOM nodes and re-locates them by similarity when a
  page's markup drifts, backed by a SQLite (WAL) cache.

**Browser & stealth**
- **`obscura-bridge`** — supervises the vendored `obscura` headless browser over CDP, with its own SSRF guard.
- **`mobile-fp`** — six mobile fingerprint presets (iPhone 15 Pro / Pro Max, iPad Pro M4, Pixel 9 Pro / 8a,
  Galaxy S24 Ultra) materialized into UA / viewport / touch / WebGL / Sec-CH-UA patches.

**Security**
- **`stealth-auth`** — encrypted cookie/session vault: XChaCha20-Poly1305 with AAD bound to the profile name,
  OS keyring + Argon2 key handling, crash-safe write-then-rename storage. Cookies never leave the vault.
- **`stealth-sanitize`** — prompt-injection defense: envelope wrap + canary detection + unicode strip +
  length clamp, with a `_meta.sanitize` report so the model can see what was stripped.
- **`vpn-rotate`** — Surfshark + Gluetun (Docker) IP-rotation with leak monitoring *(feature-gated; see table)*.

**Agent integration**
- **`stealth-mcp`** — JSON-RPC 2.0 MCP server (2024-11-05 schema) over stdio, exposing 16 tools.
- **CLI UX** — shell completions (bash/zsh/fish/nushell), generated man pages, `human|json|yaml` output,
  `--dry-run` / `--explain`, `--idempotency-key` replay, unified error envelope.

**Quality infrastructure**
- 911 workspace tests; `#![forbid(unsafe_code)]` on all 13 crates; proptests; criterion benchmarks;
  completion / man-page drift gates in CI.

## Honest capability status

> rev_scraping is an **advanced, well-tested prototype**. The scraping core, agent integration, and security
> layers are real and runnable today. The "offensive" anti-bot features and one-command distribution are
> **not** finished — this table is the source of truth.

| Capability | Status | Notes |
|---|---|---|
| Fetch → render → HTML dump (`spider`) | ✅ **Works today** | obscura browser + `reqwest` fallback; real navigation |
| Adaptive parse / element relocation | ✅ **Works today** | `stealth-parse`, SQLite-backed |
| MCP server (16 agent tools) | ✅ **Works today** | hand-rolled JSON-RPC 2.0 over stdio |
| Prompt-injection sanitizer | ✅ **Works today** | envelope + canary + unicode + clamp |
| Encrypted cookie vault | ✅ **Works today** | XChaCha20-Poly1305 + OS keyring + Argon2 |
| CLI UX (json/yaml, dry-run, idempotency, completions, man pages) | ✅ **Works today** | — |
| Cloudflare handling (`cf-evaluate`) | 🟡 **Detect-only by design** | measures the challenge surface; **no bypass solver** |
| VPN IP rotation (`vpn`) | 🟡 **Feature-gated (off)** | build with `--features docker` + run Docker/Gluetun |
| VPS egress probe (`measure --enable-egress-probe`) | 🟡 **Feature-gated (off)** | network I/O only when explicitly enabled |
| Captcha solving (`captcha solve`, live) | ⛔ **Stub in this repo** | `--dry-run` returns a synthetic token; the live path needs a `sidecar` feature + a Node sidecar **not shipped here** |
| JA4 / TLS fingerprint (`measure`) | ⛔ **Synthetic placeholder** | deterministic stub string, not a real JA4 |
| `cargo install` / Homebrew / OCI image / cosign | 🗺️ **Roadmap — not published** | release pipeline exists but has **never run a real publish**. No installable artifact yet — **build from source** |

## Quickstart (build from source)

> This is the path that works today. `cargo install rev-stealth`, Homebrew, and Docker images are on the
> [roadmap](#roadmap) but **not published yet** — do not use them.

**Requirements:** Rust **1.83+** and a C toolchain (bundled SQLite + crypto compile from source). The
`obscura` browser is vendored under `vendor/obscura/` and builds with the workspace — no separate Chromium
download is needed for `spider`. (The optional `browser` subcommand additionally uses a host Chrome/Chromium.)

```bash
git clone https://github.com/sasuketorii/rev_scraping.git
cd rev_scraping
cargo build --release            # builds rev-stealth + the vendored obscura browser

./target/release/rev-stealth --version
./target/release/rev-stealth --help
```

Your first scrape (pure-HTTP path, no VPN required):

```bash
./target/release/rev-stealth --format json \
  spider --url https://example.com --http-only --i-have-authorization --allow-no-vpn
```

```jsonc
{"ok":true,"operation":"spider","result":{
  "session_id":"…","fetcher":"http-only","http_status":200,"html_size":1256, "…":"…"}}
```

> Add `./target/release` to your `PATH` (or `cargo install --path crates/stealth-cli`) to drop the
> `./target/release/` prefix from the commands below.

---

## Manual: command reference

`rev-stealth` groups operations into subcommands. Full tree:

| Command | Purpose | Status |
|---|---|---|
| `spider` | AUP-gated browse + scrape + optional CF eval + adaptive relocate | ✅ |
| `relocate` | Re-find a fingerprinted element in saved HTML or a fresh URL | ✅ |
| `doctor` | Pre-flight leak checks (kill-switch / DNS / IPv6 / WebRTC) | ✅ |
| `auth` | Authenticated session lifecycle | ✅ |
| `config` | Layered config inspect / mutate (incl. `profile`) | ✅ |
| `measure` | Local fingerprint diagnostics (external probe opt-in) | 🟡 synthetic |
| `cf-evaluate` | Cloudflare Turnstile resilience evaluation (no solver) | 🟡 detect-only |
| `captcha` | reCAPTCHA / hCaptcha / Turnstile `solve` / `verify` | ⛔ live = stub |
| `vpn` | Exit-IP `rotate` / `status` | 🟡 needs Docker |
| `browser` | Launch a stealth profile / run a stealth-test sweep | 🟡 needs Chrome |
| `hermes` | Hermes MCP plugin scaffold (`install` / `verify`) | ✅ |
| `completions` | Emit a shell completion script | ✅ |
| `manpages` | Emit roff man pages | ✅ |

> There is **no** `rev-stealth mcp` subcommand — the MCP server is a separate `stealth-mcp` binary
> ([see below](#mcp-server--claude-code-integration)). "Scrape" is `spider`; "recipes" are managed via
> `spider` flags and the MCP `recipe_*` tools.

### Global options

| Flag | Values | Default | Notes |
|---|---|---|---|
| `--format` | `human` (alias `text`) · `json` · `yaml` | `human` | Global. JSON is clean on **stdout** (logs go to stderr) |
| `-v, --verbose` | repeatable (`-v` / `-vv` / `-vvv`) | — | logs → stderr |
| `-h, --help` / `-V, --version` | — | — | on every subcommand |

Mutating subcommands (`vpn rotate`, `auth login`, `config set/init/…`, `hermes install`) also accept
**`--dry-run`** (side-effect-free), **`--explain`** (emit a `result.plan`), and
**`--idempotency-key <KEY>`** (replay the prior result for the same key + operation + payload).

### Output formats, exit codes & error envelope

**Success** (clean JSON on stdout):
```json
{"ok":true,"operation":"vpn.rotate","result":{ "...": "..." }}
```
**Failure**:
```json
{"ok":false,"operation":"captcha.solve","kind":"captcha","exit_code":1,
 "error":"unknown captcha type \"bogus\"","message":"...","hint":null,
 "retry_after_ms":null,
 "doc_url":"https://github.com/sasuketorii/rev_scraping/blob/main/docs/book/src/en/errors/Captcha.md"}
```

| Exit | Name | Meaning |
|---|---|---|
| 0 | Ok | success |
| 1 | UserError | bad args / AUP rejection / validation |
| 2 | TransientError | network / provider flap — **retryable** |
| 3 | PermanentError | unsupported / missing dependency |
| 4 | AuthExpired | stored auth profile missing or expired |
| 7 | Leak | a leak was detected — **fail-closed** |
| 9 / 10 | (command-specific) | cache-only miss / ambiguous relocate match |

### `spider` — scrape a page

AUP-gated: you must pass `--i-have-authorization`. By default it also enforces the VPN guard (exit `7`
unless a VPN container is up or you pass `--allow-no-vpn`).

```bash
# Pure HTTP (no browser), no VPN:
rev-stealth --format json spider \
  --url https://example.com --http-only --i-have-authorization --allow-no-vpn

# Browser-rendered (obscura), bound to a session + mobile fingerprint:
rev-stealth --format json spider \
  --url https://example.com --i-have-authorization --allow-no-vpn \
  --session-id my-run --mobile-preset iphone15pro
```

Key flags: `--url <URL>` (required) · `--http-only` (skip browser) · `--i-have-authorization` (AUP) ·
`--allow-no-vpn` · `--session-id <ID>` · `--mobile-preset <preset>` · `--cf-evaluate` · `--cache-only`.

### `doctor` — pre-flight leak checks

Verifies kill-switch / DNS / IPv6 / WebRTC posture. Exits `7` if any leak is detected (fail-closed).

```bash
rev-stealth doctor --output-format json --skip-exit-ip
```

### `relocate` — drift-resistant element lookup

Re-find a previously fingerprinted element by its `stable_id`, even after the page markup changed.

```bash
rev-stealth --format json relocate \
  --session-id my-run --stable-id checkout-button --html-file saved.html
```

### `auth` — authenticated sessions

Cookies are encrypted in the vault; the CLI / MCP only ever surface metadata, never raw cookies.

```bash
rev-stealth --format json auth list
rev-stealth --format json auth status --profile my-site
rev-stealth auth login --profile my-site --url https://my-site.example/login   # needs the rev-auth helper
```

### `config` — layered configuration

```bash
REV_SCRAPING_HOME=/tmp/rs rev-stealth config init --target all
rev-stealth config --output-format json get policy.require_vpn   # → {"key":"…","value":true}
rev-stealth config set policy.require_vpn false --dry-run --explain
```

### `captcha` — captcha operations

> **Live solving is a stub in this repo.** `--dry-run` returns a synthetic token (for CI plumbing); the
> live path requires building with the `sidecar` Cargo feature and a Node sidecar that is **not shipped
> here**. `verify` makes a real call to the provider's `siteverify` endpoint.

```bash
# Plumbing smoke (no network, no secret):
rev-stealth --format json captcha solve --type recaptcha-v3 \
  --site-url https://example.com --dry-run

# Verify a token against the provider (needs --secret / env):
rev-stealth --format json captcha verify --type recaptcha-v3 --token "<TOKEN>" --secret "<SECRET>"
```

### `vpn` — IP rotation

> Requires building with `--features docker` **and** a running Docker + Gluetun (Surfshark) container.
> Without it the leak guard fails closed (exit `7`). `--dry-run` shows the plan offline.

```bash
rev-stealth --format json vpn status
rev-stealth --format json vpn rotate --dry-run --explain   # offline, side-effect-free plan
```

### `browser` / `cf-evaluate` / `measure`

```bash
rev-stealth browser stealth-test                                   # stealth sweep (needs a host Chrome/Chromium)
rev-stealth --format json cf-evaluate --url https://example.com    # detect-only, no solver
rev-stealth --format json measure --url https://example.com        # local-only; JA4 is a synthetic stub
```

### `completions` & `manpages`

```bash
rev-stealth completions zsh > ~/.zfunc/_rev-stealth     # bash | zsh | fish | nushell
rev-stealth manpages ./man && man -M ./man rev-stealth
```

---

## MCP server & Claude Code integration

The MCP server is a **separate binary**, `stealth-mcp`. It speaks line-delimited JSON-RPC 2.0 over stdio
and shells out to the `rev-stealth` CLI for each tool call.

```bash
cargo build --release --bin stealth-mcp --bin rev-stealth
./target/release/stealth-mcp        # waits for JSON-RPC on stdin
```

**Wire it into Claude Code:**
```bash
claude mcp add stealth-mcp -- /abs/path/to/target/release/stealth-mcp
```
or in `.mcp.json` (works for Cursor too):
```json
{
  "mcpServers": {
    "stealth-mcp": {
      "command": "/abs/path/to/target/release/stealth-mcp",
      "args": [],
      "env": { "REV_SCRAPING_CLI_PATH": "/abs/path/to/target/release/rev-stealth" }
    }
  }
}
```
Setting `REV_SCRAPING_CLI_PATH` makes the server independent of CWD / PATH.

**The 16 tools** (each ships a draft-07 input *and* output schema; responses are sanitizer-filtered):

| Tool | Purpose |
|---|---|
| `spider` | Stealth scrape + optional CF eval + adaptive relocate (AUP-gated) |
| `relocate` | Re-find a recorded element via `stable_id` |
| `cf_evaluate` | Cloudflare Turnstile resilience eval (detect-only) |
| `doctor` | Leak-guard / VPN / captcha-sidecar health |
| `recipe_list` / `recipe_show` / `recipe_remove` | Inspect / manage site recipes |
| `recipe_propose_endpoint` | Append an endpoint to a recipe (secret-leak rejected) |
| `recipe_export` / `recipe_import` | Move recipes as base64 JSON (path-traversal guarded) |
| `auth_login_start` / `auth_login_complete` | Two-phase login (returns a session token, never cookies) |
| `auth_list` / `auth_status` | Profile inventory / freshness |
| `session_show` | Persisted session metadata (VPN binding, recipe hits) |
| `vpn_rotate` | Rotate the VPN exit (needs Docker / Gluetun) |

Sample handshake:
```jsonc
// → {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"probe","version":"0.1"}}}
// ← {"jsonrpc":"2.0","id":1,"result":{"serverInfo":{"name":"stealth-mcp","version":"1.3.0"},"protocolVersion":"2024-11-05","capabilities":{"tools":{"listChanged":false}}}}
// → {"jsonrpc":"2.0","id":2,"method":"tools/list"}     // ← 16 tools
```

Shared wire types live in `stealth-agent-contracts` (published as `rev-stealth-agent-contracts`):
a 26-variant `ErrorKind`, `ErrorEnvelope`, `IdempotencyKey`, `PerHostRateLimiter`, and `SessionId`.

---

## Security & responsible use

- **Authorized targets only.** `spider` is gated behind `--i-have-authorization`; the toolkit is meant for
  scraping you are permitted to perform (your own sites, contracted engagements, public data within ToS).
- **VPN-required by default.** Network commands fail closed (exit `7`) unless a VPN egress is verified or you
  explicitly opt out with `--allow-no-vpn`.
- **Secrets stay encrypted.** Cookies / sessions live in the XChaCha20-Poly1305 vault; the CLI and MCP surface
  only metadata. Recipe import/export and endpoint proposals reject embedded secrets.
- **Untrusted content is fenced.** Scraped HTML passed toward a model is sanitized (`<<<UNTRUSTED_CONTENT>>>`
  envelope + injection-canary detection) first.

## How it compares

| | rev_scraping | Playwright / Browserless | Crawl4AI | Scrapy |
|---|---|---|---|---|
| Agent / MCP-native | ✅ built-in stdio MCP | ✖ (glue needed) | ◯ LLM-oriented | ✖ |
| Prompt-injection sanitizer | ✅ | ✖ | ✖ | ✖ |
| Encrypted credential vault | ✅ | ✖ | ✖ | ✖ |
| Runtime | single Rust binary + vendored browser | Node + Chromium | Python | Python |
| Anti-bot / captcha **bypass** | ✖ (detect-only / stub) | partial via plugins | external services | ✖ |
| Maturity / ecosystem | young | very mature | growing | very mature |
| One-command install | ✖ (build from source) | ✅ | ✅ | ✅ |

**Honest take:** rev_scraping wins on agent-native integration and the security envelope, and ships as a
clean single Rust binary. It is behind on anti-bot bypass, ecosystem maturity, and published distribution.

## Roadmap

- Publish artifacts so `cargo install` / Homebrew / OCI images / cosign signatures actually work
- Land a working captcha sidecar (the bridge + interfaces already exist)
- Real TLS / JA4 fingerprinting (replace the synthetic stub)
- Default-on VPN rotation without a manual Docker step

## Engineering

13-crate Rust workspace · `#![forbid(unsafe_code)]` on every crate · 911 workspace tests · proptests ·
criterion benchmarks · completion & man-page drift gates. Build everything with `cargo build --release`
and run tests with `cargo test --workspace`.

## Author & contact

Built by **Sasuke Torii (鳥居 佐助)** — **REV-C Inc.** (株式会社 REV-C, Tokyo).
Security reports & responsible disclosure: **`security-alert.reproduce897@passmail.com`**.

## License

MIT — see [LICENSE](LICENSE). Repository: <https://github.com/sasuketorii/rev_scraping>.

> 🇯🇵 A Japanese version of this README lives at [README.ja.md](README.ja.md).
