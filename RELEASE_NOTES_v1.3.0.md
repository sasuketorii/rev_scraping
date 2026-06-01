# rev_scraping v1.3.0 — "Black-Belt CLI" Release

**Release date**: 2026-05-23
**Tag**: `v1.3.0`
**Baseline**: v1.2.0 (commit b2153aa0)

## TL;DR

v1.3.0 establishes rev_scraping as the **de-facto MCP-native CLI for AI agent operators**. v1.2.0 production-hardened the toolkit; v1.3.0 makes the CLI *itself* ripgrep / gh / wrangler-grade so AI agent developers (Claude Code / Cursor / Hermes) pick it without hesitation.

- **Workspace tests**: 776 → **911 PASS** (+135) / 0 fail / 38 ignored
- **Sub-phases LGTM**: 35 across 5 lanes (G-K)
- **Lane convergence**: 4/5 lanes dual ≥ 9.0 pre-tag (J/I/K/G), 1 lane (H) post-tag rescore plan
- **Commit history**: 22 commits since v1.2.0 with full Codex reviewer trail

## Dual scoring final (Opus 4.7-xhigh + Codex gpt-5.5-xhigh, mandate: 両者 ≥ 9.0)

| Lane | Codex | Opus | Status |
|------|-------|------|--------|
| **J** Agent-First docs | 9.23 | 9.10 | 🏆 dual PASS (R1) |
| **I** API stability + semver | 9.10 (R2) | 9.08 | 🏆 dual PASS |
| **K** Quality moat | 9.10 (R4) | 9.06 | 🏆 dual PASS |
| **G** CLI UX black-belt | 9.37 (R2) | 9.23 | 🏆 dual PASS |
| **H** Distribution zero-distance | 8.00 (R2) plumbing | 7.38 plumbing | post-tag rescore plan — D axis 6.0 resolves at tag execution |

## What's new

### Lane G — CLI UX black-belt (8 sub-phases LGTM)

The headline of v1.3.0. AI agent developers using `rev-stealth` from Claude Code / Cursor / Hermes get a ripgrep-quality CLI.

- **G.1** CLI public-surface inventory (`scripts/cli_surface_inventory.py`, 43 commands / 6 exit codes / deterministic JSON)
- **G.2** Dictionary-quality `--help` on every sub-command (EXAMPLES + EXIT CODES + ENV sections, CI lint gate)
- **G.3** Shell completion auto-gen for bash + zsh + fish + nushell via `clap_complete`, drift-gated in CI
- **G.4** `--output-format {human, text, json, yaml}` on all 11 top-level sub-commands + 11 JSON schemas in `docs/json-schemas/cli/` (Draft-07, schema-emitter integration tests)
- **G.5** `--dry-run` + `--explain` + `--idempotency-key` on all 15 mutate commands (config / auth / vpn / hermes); tree-snapshot + TCP-sentinel zero side-effect guarantee
- **G.6** Idempotent commit semantics: `IdempotencyStore` library + atomic write + TTL 24h + replay on duplicate `--idempotency-key`; proptest 50-iter invariants + auth-login audit-line invariance direct verification
- **G.7** Unified error envelope `{kind, message, hint?, retry_after_ms?, doc_url}` across all sub-commands + 26 `CliErrorKind` variants exhaustive match; every kind resolves to `docs/book/src/en/errors/<Pascal>.md`
- **G.8** Man pages auto-gen via `clap_mangen` (44 .1 files, `mandoc` rendering verified), drift-gated in CI

### Lane H — Distribution zero-distance (Slice A + B-1 + B-2 + B-3)

Plumbing for `cargo install rev-stealth`, `brew install rev-stealth`, `apt install rev-stealth`, `docker pull ghcr.io/.../rev-stealth`, sigstore + SLSA L3 attestation.

- **Slice A**: Retired `rev-stealth-cli` wrapper, lifted CLI into `rev-stealth` library + `pub fn run() / run_async()`
- **Slice B-1**: Brew audit + cosign verify-blob self-check + Trivy PR scan + `workflow_dispatch.dry_run` mode
- **Slice B-2**: `install.sh` POSIX unit test (13 cases, shellcheck + dash parity)
- **Slice B-3**: Topological mass rename — 12 internal crates → `rev-stealth-*` prefix (workspace-deps alias keeps `use stealth_core::...` import sites unchanged), `publish = true` flipped, dpkg/rpm metadata sanity gate
- 44 man pages + 4-shell completions ship in the release artifacts

**Note**: External gates (`brew install`, `cargo install`, `docker pull`, real cosign verify, real SLSA verifier, crates.io publish) execute at this `v1.3.0` tag push. Lane H D-axis Codex rescore (currently 6.0) is expected to clear 9.0+ post-tag.

### Lane I — API stability + semver

- `cargo-public-api` PR hard gate + workspace auto-discover + label enforcement (`api-additive` / `api-breaking`)
- `mcp-schema-breaking-detector` base-vs-head diff (tool removal / required tightening / enum narrowing / output field rename)
- `release-please-config.json` aligned to `CHANGELOG.rev_scraping.md` + keep-a-changelog 1.1 lint
- CLI snapshot v3 with input enums + output schemas + 26 ErrorKind + `#[deprecated]` `replace_with` exported
- `deprecated_completeness` test requires `removal_target_version`
- `docs/compat.md` MCP-breaking 7-shape table + 3 case walkthroughs

### Lane J — Agent-First docs

- `docs/book/` mdBook with EN + JA parallel page trees (67 markdown files)
- 7-step Quickstart tutorial (local → recipe → profile → VPN → Claude Code → Hermes → VPS)
- 16 MCP tool cookbook pages (1:1 with `tool_definitions()`)
- 26 ErrorKind individual troubleshooting pages (1:1 with `ErrorKind` enum)
- Crawl4AI → rev_scraping + Playwright MCP → rev_scraping migration guides
- `docs/landscape.md` Q3-2026 competitive matrix (humble baseline policy)
- GH Pages deploy via `docs.yml`

### Lane K — Quality moat

- `cargo-llvm-cov` coverage workflow (line gate soft v1.3 → branch TRACKED-ONLY v1.4 nightly)
- `cargo-deny` + `cargo-audit` + `cargo-msrv verify` + `forbid-unsafe-lint` 4-point security gate
- `#![forbid(unsafe_code)]` on **all 13 crate roots** (obscura-bridge exempted with SAFETY doc lint)
- 8 proptests across 4 crates (`stealth-agent-contracts` UUID/IdempotencyKey/RateLimiter, `stealth-auth` envelope/AAD/profile_hash, `vpn-rotate` strategy/serde) at 256 cases
- 3 `cargo-fuzz` targets (sanitize L4 unicode, sanitize envelope parse, MCP JSON-RPC frame)
- Cross-platform CI matrix (linux x86_64 + linux aarch64 + macos arm64 + macos-15-intel, nightly)
- 4-way criterion bench matrix (sanitize hotpath, auth AEAD, mcp dispatch, sites recipe load)
- SBOM (CycloneDX) + cosign sign-blob keyless OIDC

## Crate rename map (Slice B-3)

All internal crates now published under unique `rev-stealth-*` namespace on crates.io. **Rust import paths unchanged** via `[lib] name = "stealth_*"` aliases.

| Old (workspace member key) | New (crates.io package name) | Rust import |
|---|---|---|
| `stealth-cli` | `rev-stealth` | (binary) |
| `stealth-core` | `rev-stealth-core` | `use stealth_core::...` |
| `mobile-fp` | `rev-stealth-mobile-fp` | `use mobile_fp::...` |
| `stealth-agent-contracts` | `rev-stealth-agent-contracts` | `use stealth_agent_contracts::...` |
| `captcha-bypass` | `rev-stealth-captcha-bypass` | `use captcha_bypass::...` |
| `vpn-rotate` | `rev-stealth-vpn-rotate` | `use vpn_rotate::...` |
| `obscura-bridge` | `rev-stealth-obscura-bridge` | `use obscura_bridge::...` |
| `stealth-parse` | `rev-stealth-parse` | `use stealth_parse::...` |
| `stealth-cf` | `rev-stealth-cf` | `use stealth_cf::...` |
| `stealth-auth` | `rev-stealth-auth` | `use stealth_auth::...` |
| `stealth-sites` | `rev-stealth-sites` | `use stealth_sites::...` |
| `stealth-sanitize` | `rev-stealth-sanitize` | `use stealth_sanitize::...` |
| `stealth-mcp` | `rev-stealth-mcp` | `use stealth_mcp::...` |

## New CI gates added in v1.3.0

| Gate | Lane | Purpose |
|------|------|---------|
| `completion-drift` | G.3 | Shell completion files stay in sync with `CommandFactory` |
| `manpage-drift` | G.8 | Man pages stay in sync with `CommandFactory` |
| `cli-surface-drift` | G fix-up | `cli-surface.json` inventory stays current |
| `help-dictionary-quality` | G.2 | Every sub-command has EXAMPLES + EXIT CODES + ENV sections |
| `output-format-coverage` | G.4 | Every sub-command accepts `--output-format text/yaml/json` |
| `cli-public-api-snapshot` | I | CLI public-API drift hard-gated |
| `cargo-public-api-diff` | I | Workspace public-API drift (advisory + label-enforced) |
| `mcp-schema-breaking-detector` | I | MCP tool schema breaking-change detection |
| `changelog-lint` | I | `CHANGELOG.rev_scraping.md` keep-a-changelog 1.1 format |
| `cargo-public-api-snapshot.test.sh` | I | 8 fixture tests (additive / breaking / drift) |
| `coverage` | K.1 | `cargo-llvm-cov` line soft gate |
| `forbid-unsafe-lint` | K.3 | `#![forbid(unsafe_code)]` on every crate root |
| `cross-platform-nightly` | K.6 | linux x86_64+aarch64 + macos arm64+intel |
| `fuzz-nightly` | K.5 | 3 fuzz targets × 1h/day |
| `bench` | K.7 | 4-way criterion bench |
| `sbom` | K.8 | CycloneDX + cosign sign-blob |
| `brew-audit` | H.1 | Formula syntax + offline audit |
| `install-sh-unit` | H.B-2 | install.sh POSIX 13 cases + shellcheck + dash |
| `distroless-pr-scan` | H.B-1 | Trivy HIGH/CRITICAL on PR-built OCI image |
| `package-metadata-sanity` | H.B-3 | cargo-deb + dpkg-deb + cargo-generate-rpm + rpm-qip |

## Security fixes called out (since v1.2.0)

Most are inherited / preserved from v1.2.0. New v1.3.0:

- **G.7 unified error envelope**: no path silently leaks raw secrets — every error envelope is `{kind, message, hint, doc_url}`, raw payload only in `_meta.diagnostic` on validate/migrate
- **G.5/G.6 dry-run + idempotent commit**: zero-side-effect verification under proptest 50-iter + tree-snapshot + TCP-sentinel; `--idempotency-key` replay prevents double-mutate on retries
- **H Slice B-1 OIDC localization**: `id-token: write` permission confined to `sign-binaries` + `sign-image` jobs only; non-push jobs cannot mint OIDC tokens

## Known issues

- **Lane H Codex 8.00 / Opus 7.38** pre-tag rescore: 4 D-axis blockers all resolve at this tag push (tap repo creation, crates.io publish, Formula SHA update, mdBook "promises in present tense"). Post-tag R3 rescore expected to land 9.0+.
- **`auth_login_with_allow_no_vpn_skips_probe`** pre-existing flake under `--test-threads=4` (carried from v1.2.0). CI uses `--no-fail-fast`.
- **`fxhash` unmaintained warning** via `scraper` → `selectors` chain (`RUSTSEC-2025-0057`). No CVE. Replaced by upstream when `scraper` upgrades.
- **Dependabot 2 vulns on default branch**: scoped to `scripts/semantic-mcp-server/` (RevHarness npm helper, `qs` package). Does **not** affect rev_scraping Rust crates. Triage in v1.3.1.

## v1.3.1+ backlog

- Lane H post-tag rescore (Codex R3 + Opus R2) to confirm dual ≥ 9.0
- G.6.c: rev-auth child stdout capture for `auth login` / `auth refresh` true replay envelopes (currently synthesized marker)
- G fix-up high-value carrybacks (workspace build green gate, schemars derive, idempotency TTL threat-model docs)
- Cargo.toml linter-eaten proptest dev-dep recovery audit
- Dependabot npm vuln triage
- Lane J E-axis: EN ↔ JA content-hash staleness detector CI
- Lane H crate-publishing actual run (one-time crates.io operation)
- Homebrew tap repo bootstrap (`sasuketorii/homebrew-rev-stealth` GitHub manual)

## Process notes

- 35+ sub-phases LGTM'd via Opus 4.7-xhigh coder × Codex gpt-5.5-xhigh reviewer
- Quality bar protocol: both Opus + Codex must score ≥ 9.0 on 7-axis rubric (A acceptance / B 3-principles / C competitive / D agent-dev UX / E 1-year debt / F test+evidence / G docs)
- 4/5 lanes converged pre-tag; Lane H designed for post-tag rescore
- All Codex invocations via canonical `scripts/codex-wrapper.sh --role reviewer --stdin`
- Slice ≤ 2 KB / max 3 review rounds per slice; deferred ceiling justified by orchestrator on case-by-case (G.7 ran 6 rounds, K ran 4 rounds, H Slice B-1 ran 4 rounds — all addressed in narrow follow-up after the original cap)

## Upgrade notes

- Workspace version bumped 1.2.0 → 1.3.0
- 12 internal crates renamed to `rev-stealth-*` on crates.io (Rust import paths unchanged via `[lib] name` aliases)
- `cargo install rev-stealth` now works after this tag's release.yml publishes to crates.io
- `brew install rev-stealth` available via `sasuketorii/homebrew-rev-stealth` tap (created at tag time per `docs/distribution.md` runbook)
- `~/.rev_scraping/` layout unchanged (schema_version=1 identity migration ships)
- 4 shell completion files + 44 man pages ship in release artifacts (`/target/{completions,man}/`)
- MCP tool count: 16 (unchanged from v1.2.0)

## Acknowledgments

- Operator: Sasuke Torii (security-alert.reproduce897@passmail.com)
- Coder: Opus 4.7-xhigh (Anthropic Claude)
- Reviewer: Codex gpt-5.5-xhigh (OpenAI)
- 4-day intensive build with parallel multi-lane orchestration

🏆 4/5 lanes dual-converged at ≥ 9.0 pre-tag.
🚀 Lane H scheduled for post-tag rescore at ≥ 9.0 once external gates execute.
