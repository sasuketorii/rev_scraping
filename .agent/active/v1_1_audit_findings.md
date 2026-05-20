# v1.1.0 GA — P1 Repo Audit Findings

> **Phase:** P1 (Repo audit — foundational, 0.25d, 🟡 medium)
> **Date:** 2026-05-18 JST
> **Auditor:** P1 coder agent
> **Scope:** baseline metrics + README/Cargo.toml inconsistency catalogue (no source edits).

---

## 1. Workspace member crates (cargo metadata, authoritative)

`cargo metadata --no-deps --format-version 1` → `/tmp/v1_1_audit_metadata.json`

**Workspace members = 11** (matches `Cargo.toml [workspace].members`).

| # | Crate path | package.name | bin target | version | edition | rust-version | license |
|---|------------|--------------|------------|---------|---------|--------------|---------|
| 1 | crates/stealth-core    | `stealth-core`    | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 2 | crates/mobile-fp       | `mobile-fp`       | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 3 | crates/vpn-rotate      | `vpn-rotate`      | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 4 | crates/captcha-bypass  | `captcha-bypass`  | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 5 | crates/stealth-cli     | `stealth-cli`     | **`rev-stealth`** | 1.0.0-dev | 2021 | 1.83 | MIT |
| 6 | crates/obscura-bridge  | `obscura-bridge`  | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 7 | crates/stealth-cf      | `stealth-cf`      | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 8 | crates/stealth-parse   | `stealth-parse`   | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 9 | crates/stealth-mcp     | `stealth-mcp`     | **`stealth-mcp`** | 1.0.0-dev | 2021 | 1.83 | MIT |
| 10| crates/stealth-sites   | `stealth-sites`   | —              | 1.0.0-dev | 2021 | 1.83 | MIT |
| 11| crates/stealth-auth    | `stealth-auth`    | **`rev-auth`**    | 1.0.0-dev | 2021 | 1.83 | MIT |

Three published binaries: `rev-stealth`, `rev-auth`, `stealth-mcp` (per `[[bin]]` in each crate).

> Workspace excludes: `vendor/obscura/` (Apache-2.0, separate Cargo project).

## 2. README ↔ Cargo.toml inconsistency catalogue (Q8)

Hand-graded for P9 (naming reconciliation). **No fixes applied in P1.**

| # | Location | README states | Reality | Severity | Recommended P9 action |
|---|---|---|---|---|---|
| Q8-1 | README §12 "Crates" table (L137–149) | **9 crates** listed (`stealth-cli`, `obscura-bridge`, `stealth-cf`, `stealth-parse`, `stealth-mcp`, `mobile-fp`, `vpn-rotate`, `captcha-bypass`, `stealth-core`) | **11 crates** in workspace; missing from README: `stealth-sites`, `stealth-auth` | **HIGH** (user-visible) | Add 2 rows; renumber any references |
| Q8-2 | README "Project layout" (L47–69) | tree shows 9 crates (same omission) | same as above | **HIGH** | Add `stealth-sites/` + `stealth-auth/` entries |
| Q8-3 | README §12 Crates table | `stealth-mcp` row says "rmcp 0.1 stdio server" | `stealth-mcp/Cargo.toml` does **NOT** depend on `rmcp` (custom stdio impl) | MEDIUM | Either adopt rmcp (intended) or correct doc |
| Q8-4 | `Cargo.toml [workspace.dependencies]` (L83–84) | `wreq = "=6.0.0-rc.28"` declared | **Zero workspace crate consumes `wreq`** (grep of all `crates/*/Cargo.toml` → 0 hits; not present in `Cargo.lock`); only a code comment in `crates/obscura-bridge/src/bridge.rs:265` mentions the obscura-internal wreq client | MEDIUM | Either wire `wreq` into a crate that needs it, or remove the dangling workspace decl |
| Q8-5 | `Cargo.toml [workspace.dependencies]` | `rmcp = "0.1"` declared | **Zero workspace crate consumes `rmcp`**; not in `Cargo.lock`. (Phase-0 TODO comment confirms uncertainty.) | MEDIUM | Resolve TODO: adopt rmcp 0.1 / 0.2 in `stealth-mcp` or drop the decl |
| Q8-6 | README §14 (L466) | "headed browser via the **rev-auth** helper subprocess" | matches `crates/stealth-auth/[[bin]] name = "rev-auth"` | OK | none |
| Q8-7 | README §13 / §14 — no §15-§20 yet | N/A | distribution sections missing | (handled by P/B7) | not P9 |

## 3. Baseline sanity checks (must hold before any sub-phase merges)

| Check | Command | Result |
|---|---|---|
| Workspace test count | `cargo test --workspace --no-fail-fast` | **459 PASS**, 0 failed, 110 ignored (live/`#[ignore]` gated). Matches v1.0.0-dev baseline expected = 459. ✅ |
| Clippy clean | `cargo clippy --workspace --all-targets -- -D warnings` | **0 warnings, 0 errors** ✅ |
| SPDX / source guard | `bash scripts/check_source_and_spdx.sh` | **PASS** ✅ |

## 4. Workspace dependency versions (resolved, from `Cargo.lock`)

Critical security crates — these are the v1.0.0-dev baseline for B7/P11 (SECURITY.md) and the supply-chain SHOULD-item:

| Crate | Cargo.toml decl | Cargo.lock resolved | Purpose | Note |
|---|---|---|---|---|
| `keyring` | `3` | **3.6.3** | OS keychain (rev-auth profile encryption key) | Linux uses libsecret backend — P6 must verify |
| `secrecy` | `0.10` | **0.10.3** | redact-on-Drop wrappers | OK |
| `zeroize` | `1` (`derive`) | **1.8.2** | clear memory of sensitive buffers | OK |
| `chacha20poly1305` | `0.10` | **0.10.1** | AEAD for auth profile sealed-box | RustCrypto, stable |
| `argon2` | `0.5` | **0.5.3** | KDF | OK |
| `rusqlite` | `0.32` (`bundled`) | **0.32.1** | parse cache | bundled libsqlite — no host dep |
| `chromiumoxide` | `0.9` | **0.9.1** | CDP client | matches obscura's pinned Chrome-145 |
| `bollard` | `0.21` | **0.21.0** | Docker API (vpn-rotate Gluetun) | OK |
| `reqwest` | `0.13` (`rustls`,`json`,`cookies`) | **0.13.3** | HTTP client (auth profile + cf-evaluate) | no native-tls — good |
| `wreq` | `=6.0.0-rc.28` | **(unresolved — no consumer)** | obscura wreq client glue | ⚠ Q8-4 |
| `rmcp` | `0.1` | **(unresolved — no consumer)** | MCP protocol | ⚠ Q8-5 |

Other top-level workspace deps (full list captured in `/tmp/v1_1_audit_metadata.json`):
`tokio "1" (full)`, `futures 0.3`, `async-trait 0.1`, `serde 1`, `serde_json 1`, `chrono 0.4`, `anyhow 1`, `thiserror 1`, `tracing 0.1`, `tracing-subscriber 0.3 (env-filter)`, `clap 4 (derive,env)`, `uuid 1 (v4,serde)`, `strsim 0.11`, `regex 1`, `url 2`, `dirs 5`, `tempfile 3`, `tokio-tungstenite 0.26`, `scraper 0.20`, `sha2 0.10`, `rand 0.8`, `base64 0.22`, `parking_lot 0.12`.

## 5. MSRV / toolchain

- `[workspace.package].rust-version = "1.83"` ✅ matches expected.
- **No `rust-toolchain.toml` at repo root.** The ExecPlan B5 / CI matrix (1.83 + stable) implies CI sets the toolchain explicitly. Whether to add a pinned `rust-toolchain.toml` for local determinism is a P11 (CI YAML) decision; flagging here as `INFO` only.

## 6. Secret-config audit (best effort, no values printed)

- `.gitignore` (root) excludes: `/target`, `/_refs/`, `Cargo.lock.bak`, `*.tmp`, `~/.rev_scraping/`, `.DS_Store`, `.env`, `.env.local`, `.env.*.local`. ✅
- Repo root: `.env.example` (mode 0644, committed-safe template), `.env.local` (mode 0600, gitignored). ✅
- `~/.rev_scraping/` exists (mode 0700) with: `auth/` (0700), `sites/` (0700), `policy.toml` (0600), `authorized.toml` (0600), `vpn_status.json` (0600), `parse.sqlite` (0644 — cache, no secrets), `sessions/`. ✅ All sensitive files are tightly permissioned.
- **No `.git/` directory found at repo root** → unable to run `git log -p` secret-scan. Either this is a working copy without VCS metadata, or the agent invocation stripped it. **P9 / P11 should re-confirm in the real release repo.**

## 7. Cross-phase hand-off list (carried into other sub-phases)

| Origin | Issue | Receiving sub-phase |
|---|---|---|
| Q8-1 / Q8-2 | README crate count + tree out of date | **P9** (naming reconciliation) |
| Q8-3 | `stealth-mcp` README mentions rmcp but crate doesn't link it | **P9** + check with P3/P4 owner |
| Q8-4 | `wreq` declared but unused | **P9** + Phase-0 decision review |
| Q8-5 | `rmcp` declared but unused | **P9** + decide rmcp vs custom stdio for v1.1 MCP |
| §5 | No `rust-toolchain.toml` | **P11** (CI YAML) — decide pin or skip |
| §6 | Re-verify secret scan in real git history | **P9** / **P11** |

---

**P1 verdict:** baseline locked. 459 tests PASS, clippy clean, SPDX PASS. 5 documentation/declaration inconsistencies catalogued for P9; **none block parallel start of P5/P6/P10/P2/P3**.
