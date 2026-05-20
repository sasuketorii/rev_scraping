<!-- SPDX-License-Identifier: MIT -->

# Changelog

All notable changes to `rev_scraping` are documented in this file.

The format is based on [Keep a Changelog 1.1.0](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning 2.0.0](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [1.1.0] - 2026-05-19

This is the first **release-candidate-quality** cut after the v1.0.0-dev
scaffold. It hardens the supply chain, adds two new crates
(`stealth-sites`, `stealth-auth`), and validates the toolkit on Linux.

### Added
- **`stealth-sites`** crate (P11): recipe-driven site adapters with a
  pluggable per-site selector registry. Default recipes are bundled;
  external recipes load from `~/.rev_scraping/recipes/`.
- **`stealth-auth`** crate (Phase 9): encrypted cookie jar
  (ChaCha20-Poly1305, Argon2id KDF, keyring-backed) and the `rev-auth`
  helper binary for headed manual login.
- `rev-stealth auth login --allow-no-vpn` CLI flag, in addition to
  the pre-existing `REV_SCRAPING_REQUIRE_VPN=1` env override (env wins).
- `ProfileStatus::Stale` and `ProfileStatus::Revoked` variants.
- JSON output envelope `warn_level` field (`"info" | "warn" | "error"`).
- Linux baseline coverage (Ubuntu 22.04 / 24.04 LTS) — P6.
- CI matrix for Linux + macOS, with `cargo-deny`, `cargo-audit`, and
  `gitleaks` gating every PR (P10 security hardening).
- Project meta files: `CHANGELOG.md`, `CONTRIBUTING.md`, `SECURITY.md`,
  `docs/CODE_OF_CONDUCT.md`, `docs/release-checklist.md`.
- README §15 Troubleshooting, §16 Production deployment, §17
  Performance tuning, §18 Privacy & compliance, §19 Upgrading,
  §20 Contributing.

### Changed
- README §12 crate table and Project layout tree now list all 11
  workspace crates (Q8-1, Q8-2 reconciliation).
- README rewords `stealth-mcp` as a hand-rolled JSON-RPC 2.0 stdio
  server pinned to the MCP 2024-11-05 schema (no `rmcp` dep). Q8-3.
- Workspace `Cargo.toml` documents (in comments) the deliberate
  exclusion of `wreq` and `rmcp` workspace deps (P10).
- `stealth-parse` SQLite WAL autocheckpoint tuned for long sweeps;
  recipe cache LRU is now configurable via `REV_SCRAPING_PARSE_CACHE`.

### Fixed
- **hotfix-2**: obscura native `javascript:` / `beforeunload` dialogs
  no longer race CDP attach; the bridge proactively dismisses them
  before enabling Network domain.
- `auth login` previously refused to run on VPN-less authorized
  localhost targets — added `--allow-no-vpn` opt-in.
- Eliminated the dangling `wreq` and `rmcp` workspace dependency
  declarations that no crate consumed (Q8-4, Q8-5).

### Security
- `cargo-deny` (licenses, advisories, bans, sources) wired into CI.
- `cargo-audit` runs on every PR.
- `gitleaks` scans the working tree for credentials on every PR.
- `#![forbid(unsafe_code)]` is enforced workspace-wide via
  `[workspace.lints.rust] unsafe_code = "forbid"`.
- `stealth-auth` AAD now binds each blob to
  `rev_scraping:stealth-auth:v1:<profile>` so cross-profile cookie
  paste attacks fail decryption.

### Removed
- Unused workspace deps `wreq = "=6.0.0-rc.28"` and `rmcp = "0.1"`
  (never wired into any crate; obscura ships its own `wreq` client
  internally and `stealth-mcp` uses a hand-rolled JSON-RPC layer).

## [1.0.0-dev] - 2026-XX-XX

Initial development snapshot. Workspace scaffold, vendored
`rev_stealth` crates, obscura subprocess bridge, Cloudflare Turnstile
resilience evaluator, adaptive relocator with SQLite WAL persistence,
and a stdio MCP server. See `.agent/active/plan_v1.0.0.md` for the
phase-by-phase ExecPlan.

[Unreleased]: https://example.invalid/rev_scraping/compare/v1.1.0...HEAD
[1.1.0]: https://example.invalid/rev_scraping/compare/v1.0.0-dev...v1.1.0
[1.0.0-dev]: https://example.invalid/rev_scraping/releases/tag/v1.0.0-dev
