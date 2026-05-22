# v1.3 Uplift ExecPlan — "Black-Belt CLI" Release

**Status**: GO (user approved synthesis)
**Baseline**: v1.2.0 (commit b2153aa0, 776 PASS / 0 fail / 38 ignored)
**Target**: 2026 Q3, ~5-7 calendar weeks (solo @ ~25 h/week)
**Synthesis sources**:
- `v1_3_plan_a_opus_raw.md` (Opus 4.7-xhigh, 54.5 dev-day realistic)
- `v1_3_plan_b_codex_raw.md` (Codex gpt-5.5-xhigh, 50-139 dev-day)
- User pivot 2026-05-22: "CLI ツールとして権威 / AI エージェント開発者向け / CLI UX 黒帯化"

## Positioning

> v1.3 ships the **de-facto CLI for AI agents that scrape**. The reference
> users are Claude Code / Cursor / Hermes operators who need to spawn an MCP
> server and a CLI in one motion. Everything in v1.3 is judged against:
> *"would a sophisticated AI agent developer pick this CLI over Crawl4AI /
> Playwright MCP without hesitation?"*

Stealth tier-2 (TLS/H2/H3 fingerprinting) and Crypto tier-2 (TPM2/FIDO2/audit chain)
are explicit v1.4+ scope. Both add no immediate value for the v1.3 target user.

## Lane G — CLI UX Black-Belt (the headline)

The new lane neither Plan A nor Plan B proposed, anchored to the user's pivot.
Targets: every comparison axis ripgrep / fd / gh / wrangler win on.

| ID | Sub-phase | dev-day | Acceptance |
|----|-----------|---------|------------|
| G.1 | CLI public surface inventory + naming consistency review (`rev-stealth <noun> <verb>` shape) | 0.6 | `.agent/v1.3/cli-surface.json` machine-readable; review note in PR |
| G.2 | All sub-command `--help` upgraded to dictionary quality (description + 1-3 examples + exit codes + env vars consumed) | 1.0 | `cargo test --test help_dictionary_quality` PASS; CI lint blocks regressions |
| G.3 | Shell completion auto-gen for bash / zsh / fish / nushell + CI completion-drift gate | 0.7 | `target/completions/*` committed; CI fails on stale |
| G.4 | `--output-format {json\|yaml\|text}` on every sub-command + per-command JSON schema in `docs/json-schemas/cli/` | 0.8 | Each command's JSON output validates against schema; integration test |
| G.5 | `--dry-run` and `--explain` on every mutating sub-command | 0.7 | mutating commands enumerated; integration test ensures no FS / network side effect under --dry-run |
| G.6 | Idempotent-commit semantics: same input + same `--idempotency-key` returns identical output, no duplicate write | 0.8 | proptest 50-iter; `rev-stealth auth login --idempotency-key X` twice = 1 audit entry |
| G.7 | Unified error output template: `{kind, message, hint, retry_after_ms?, doc_url}` everywhere (matches ErrorEnvelope) | 0.6 | regression test: every error path emits all required fields; doc-url resolves |
| G.8 | man page (mdoc/roff) auto-generated; `man rev-stealth` + `man rev-stealth-spider` available after `make install` | 0.5 | `man rev-stealth-spider \| col -bx \| grep -c '\.SH'` ≥ 6 (NAME/SYNOPSIS/DESCRIPTION/OPTIONS/EXAMPLES/EXIT STATUS) |

**Lane G total: 5.7 dev-day**

## Lane H — Distribution to zero-distance

Take from Plan A axis 2 sub-phases 2.1-2.6 + 2.16; drop IaC (2.7-2.8) and observability
(2.9-2.11) to v1.4.

| ID | Sub-phase | dev-day | Acceptance |
|----|-----------|---------|------------|
| H.1 | Homebrew tap `sasuketorii/homebrew-rev-stealth` + formula | 0.5 | `brew tap sasuketorii/rev-stealth && brew install rev-stealth` works on macOS arm64 + x86_64 |
| H.2 | `cargo-deb` setup → Debian 12 / Ubuntu 22.04+24.04 build matrix | 0.7 | `.deb` artifact on GH release; `dpkg -i` installs to /usr/local/bin |
| H.3 | `cargo-generate-rpm` → RHEL 9 / Fedora 41 | 0.5 | `.rpm` artifact; `rpm -i` installs |
| H.4 | Distroless multi-arch OCI image (amd64+arm64), Chromium separated | 0.9 | `docker pull ghcr.io/sasuketorii/rev-stealth:v1.3.0`; `trivy image --severity HIGH,CRITICAL --exit-code 1` PASS |
| H.5 | `cargo install rev-stealth` via crates.io publish (workspace member publish-permission check) | 0.6 | `cargo install --locked rev-stealth` works fresh; LICENSE / README on crates.io |
| H.6 | `curl \| sh` installer + sigstore cosign signing + SLSA L3 build provenance attestation via `actions/attest-build-provenance` | 0.7 | `cosign verify-blob --certificate-identity=...` PASS; SLSA L3 verifier passes |
| H.7 | `release-please` automation (tag → matrix build → SBOM → cosign → GH release) | 0.8 | one-tag release: deb+rpm+brew+OCI+cargo all populated in single workflow run |

**Lane H total: 4.7 dev-day**

## Lane I — API stability & semver

Plan A 2.14-2.15 + Lane I from my pre-pivot draft.

| ID | Sub-phase | dev-day | Acceptance |
|----|-----------|---------|------------|
| I.1 | CLI public surface machine-readable snapshot (every flag, every env var, every output field) | 0.4 | `.agent/v1.3/cli-public-api.snapshot.json` committed |
| I.2 | `cargo-public-api` PR gate (workspace member crates) | 0.4 | PR adds new pub item → CI requires label `api-additive` or `api-breaking` |
| I.3 | `docs/compat.md` semver policy: MCP schema = 2-major guarantee / CLI flag = 1-major / internal types = no guarantee | 0.4 | document committed; linked from README |
| I.4 | `CHANGELOG.md` keep-a-changelog format + automation hook from `release-please` | 0.3 | machine-parseable; CI verifies on every PR |
| I.5 | MCP tool schema breaking-change detector (extend `mcp-schema-lint`) | 0.5 | schema change in `tools.rs` → fail unless `mcp-schema-breaking` label |
| I.6 | `#[deprecated(...)]` lint customization: forces `since`, `note`, and `replace_with` populated | 0.4 | clippy custom lint denies missing fields |

**Lane I total: 2.4 dev-day**

## Lane J — Agent-First documentation

Plan A axis 5 (subset), reframed for AI-agent-dev audience.

| ID | Sub-phase | dev-day | Acceptance |
|----|-----------|---------|------------|
| J.1 | `mdbook` scaffold (`docs/book/`) + `mdbook-i18n-helpers` + GH Pages deploy on tag push | 0.5 | https://sasuketorii.github.io/rev_scraping/ live, EN+JA toggle |
| J.2 | Quickstart 7-step tutorial (local → recipe → profile → VPN → Claude Code → Hermes → VPS) | 1.0 | `mdbook test` PASS; each step has runnable code block (stub OK for VPN/Hermes) |
| J.3 | 16 MCP tool × cookbook: real JSON-RPC request + response + failure example per tool | 1.0 | 16 sub-pages under `docs/book/src/tools/`; each shows happy path + 1 error variant |
| J.4 | Migration guide: Crawl4AI MCP → rev_scraping; Playwright MCP → rev_scraping | 0.6 | 2 sub-pages with side-by-side examples |
| J.5 | `rustdoc --document-private-items` GH Pages auto-publish + `#![warn(missing_docs)]` (warning only first, gate later) | 0.5 | https://sasuketorii.github.io/rev_scraping/api/ live |
| J.6 | 26 ErrorKind individual troubleshooting pages (reproduction code + fix + related Issues) | 0.8 | 26 sub-pages; each has 3 sections |
| J.7 | `docs/landscape.md` competitive matrix with Q3-2026 timestamp (Playwright / Puppeteer / Crawl4AI / Browserless / Scrapling / Bright Data / obscura) — refresh quarterly | 0.4 | committed; rev_scraping has at least 1 "losing" cell per row (humble baseline) |

**Lane J total: 4.8 dev-day**

## Lane K — Quality moat

Plan A axis 4 essentials + Plan B J essentials, no overreach.

| ID | Sub-phase | dev-day | Acceptance |
|----|-----------|---------|------------|
| K.1 | `cargo-llvm-cov` CI job; soft gate at 80% line / 70% branch for v1.3, hardened to 85% / 75% in v1.4 | 0.5 | CI artifact; PR comment with delta |
| K.2 | `cargo-deny` + `cargo-audit` + `cargo-msrv verify` three-point CI gate | 0.5 | `deny.toml` extended (license allowlist, banned-crates, advisory deny); failures block merge |
| K.3 | `#![forbid(unsafe_code)]` on every crate root; `obscura-bridge` exempted with `#![deny(unsafe_op_in_unsafe_fn)]` + SAFETY doc lint | 0.4 | grep verification CI step; SAFETY doc check on every unsafe block |
| K.4 | proptest expansion: stealth-auth (envelope roundtrip + AAD mismatch) + stealth-agent-contracts (UUID v4 + IdempotencyKey + RateLimiter) + vpn-rotate (rotation invariants) | 0.8 | each crate has ≥1 prop test; 256 iter standard / 1024 iter nightly |
| K.5 | `cargo-fuzz` 3 targets: `sanitize::layer4_unicode::normalize`, `sanitize::layer2_envelope::parse`, MCP JSON-RPC frame parser | 0.7 | targets build; nightly GH cron 1h/day; crash artifacts pinned as seed |
| K.6 | Cross-platform CI matrix: Linux x86_64 + Linux aarch64 (QEMU) + macOS x86_64 + macOS arm64 | 0.6 | `cargo test --release` PASS on all 4 |
| K.7 | criterion benchmarks on 5 hot paths (sanitize walk / canary scan / AAD encrypt-decrypt / MCP dispatch / recipe load) + per-PR diff via `bencher.dev` | 0.6 | regression > 10% triggers PR comment + label |
| K.8 | SBOM (CycloneDX) + sigstore cosign sign-blob + SLSA L3 attestation (deduplicate with H.6 — both share infra) | 0.3 (shared) | `.spdx.json` + `.cdx.json` attached to GH release |

**Lane K total: 4.4 dev-day**

## Critical-path & schedule

| Lane | Internal critical path | dev-day |
|------|-----------------------|---------|
| G    | G.1 → G.2 → G.7       | 2.2 |
| H    | H.2 → H.7             | 1.5 |
| I    | I.1 → I.2 → I.5       | 1.3 |
| J    | J.1 → J.2 → J.3       | 2.5 |
| K    | K.4 → K.5             | 1.5 |

**Global critical path: Lane J (J.1 → J.2 → J.3) ≈ 2.5d**

Sub-phase total: **35**. dev-day total: **22.0** (sum) — Opus realistic-equivalent
**~28 dev-day** when adding integration / review overhead. Solo at 25 h / week = **5-6 weeks**.

**Lane dependencies** (mostly independent):
- H.6 ↔ K.8 share SBOM/cosign infra (do once, reference twice)
- I.5 ↔ K.6 share `cargo-public-api` (define once)
- G.4 ↔ J.3 ↔ I.5: JSON output schema is the cross-cut spec; G.4 produces schema, J.3 documents, I.5 gates breaking changes

Recommended execution: dispatch all 5 lanes in parallel (one driver per lane,
same Opus-coder × Codex-reviewer loop as v1.2.0). Mid-week sync to resolve the
3 cross-cut points above.

## Acceptance summary for v1.3.0 cut

A reviewer who picks up rev_scraping at v1.3.0 must be able to:

1. **Install in < 60 s**: `brew install rev-stealth` OR `cargo install rev-stealth` OR `curl ... | sh`
2. **Discover via help**: `rev-stealth --help` shows dictionary-quality output with examples
3. **Pipe to jq**: every command supports `--output-format json` with a published schema
4. **Diff before commit**: `rev-stealth config set --dry-run` shows what would change
5. **Safe to retry**: same `--idempotency-key` produces identical output
6. **Read the man page**: `man rev-stealth`
7. **Integrate with Claude Code in 5 min** following `docs/book/.../tutorial/05-claude-code.md`
8. **Trust the supply chain**: SBOM + cosign-verified release artifact
9. **Confidence in semver**: `docs/compat.md` + `cargo-public-api` snapshot
10. **Read in their language**: EN + JA mdBook live on GH Pages

## v1.4+ backlog (explicit)

- **Lane L — Stealth tier-2**: boring-sys + JA4/JA3 + H2 SETTINGS + HTTP/3 + CreepJS bench + Cloudflare/DataDome fixture (Plan A axis 3 / 11.5-25 dev-day)
- **Lane M — Crypto tier-2**: TPM2 sealed KEK + FIDO2 hmac-secret + HMAC-chain audit + external cryptographer review (Plan A axis 1 / 10-14 dev-day; review lead time +2-4 weeks)
- **Lane N — IaC + observability**: Ansible role + Terraform module + Prometheus exporter + Grafana dashboard + OTel (Plan A 2.7-2.11 / 4.6 dev-day)
- **Lane O — i18n + Playground**: zh-Hans + ko translation + WASM sanitize playground + video walkthrough (Plan A 5.8-5.11 / 2.5 dev-day)
- **Lane P — Mutation testing + Chaos**: cargo-mutants on security crates + chaos test for VPN tunnel drop / Chromium SIGKILL (Plan A 4.13/4.17 / 1.6 dev-day)

## Risks & mitigations

| Risk | Lane | Mitigation |
|------|------|------------|
| `crates.io` publish requires legal name on author field — author check | H.5 | Verify Cargo.toml authors field before publish |
| Homebrew tap audit requirements (no curl-pipe-bash inside formula) | H.1 | Formula uses GitHub release URL directly |
| Distroless image breaks if Chromium needs glibc deps | H.4 | Chromium runs in separate image; rev-stealth binary is static (musl) |
| `mdbook` GH Pages requires Pages enabled in repo settings | J.1 | One-time manual step; documented in workflow file |
| `cargo-public-api` snapshot churn over normal refactors | I.2 | Use `--simplified` flag; auto-bless on label `api-additive-ok` |
| QEMU aarch64 CI 5-10x slower | K.6 | aarch64 runs nightly-only; per-PR is x86_64 + macOS |
| Solo developer 5-6 week sprint fatigue | all | Lane G+I+J can ship as v1.3.0-beta first (4 weeks), Lane H+K as v1.3.0 GA (+2 weeks) |

## Reviewer assignment

| Lane | Reviewer | Why |
|------|----------|-----|
| G | Codex (gpt-5.5-high) + ripgrep/fd/gh CLI style reference | Codex understands clap semantics; cross-reference de-facto Rust CLI conventions |
| H | Codex + Homebrew formula audit checklist | Mechanical: each artifact builds + signs + installs |
| I | Codex with semver semantic guide | `cargo-public-api` diffs are mechanical |
| J | Codex (structure) + Opus (narrative voice) for tutorial copy | Codex for code-block correctness, Opus for readability |
| K | Codex for proptest / fuzz target design | proptest strategies and fuzz harnesses are well-suited to Codex review |

All reviewer invocations use `./scripts/codex-wrapper.sh --role reviewer --stdin`
(canonical wrapper, raw `codex exec` prohibited per RevHarness §16.8/§16.9).
Slice ≤ 2 KB, max 3 review rounds per slice.

## Evidence trail

- `.agent/active/prompts/v1_3_g[1-8]_review[_round{2,3}].md` (Lane G)
- `.agent/active/prompts/v1_3_h[1-7]_review*.md` (Lane H)
- `.agent/active/prompts/v1_3_i[1-6]_review*.md` (Lane I)
- `.agent/active/prompts/v1_3_j[1-7]_review*.md` (Lane J)
- `.agent/active/prompts/v1_3_k[1-8]_review*.md` (Lane K)
- Reviewer responses: `.agent/active/reviews/v1_3_*.out`
- `REV_HARNESS_DELEGATION_METRIC` line emitted per round (CI ingests for telemetry)

## v1.3.0 release-cut criteria

- Workspace test: 776 → projected **~870 PASS** (sanitize prop + new lane tests)
- Python (Hermes): 20 PASS (unchanged in v1.3, may rise with J.3 cookbook tests)
- Critical CI gates green: cargo test / clippy / fmt / mcp-schema-lint /
  config-cli-smoke / hermes-contract / systemd-analyze / **new**: completion-drift /
  cargo-public-api / cargo-deny / cargo-llvm-cov / criterion-bench
- Tag `v1.3.0` after 24-72 h soak with `rev-stealth-doctor.timer` clean run
- Update RELEASE_NOTES_v1.3.0.md (CLI-authority framing) + README badge bump
- Push to GitHub + announce on r/rust + Hacker News (optional)

---

## Decision log

| Decision | Why | Source |
|----------|-----|--------|
| Defer stealth tier-2 to v1.4 | User pivot: CLI authority for AI dev priority over fingerprint arms race | User 2026-05-22 |
| Defer crypto tier-2 to v1.4 | External cryptographer review lead time (2-4w) makes v1.3 cut unpredictable | Plan A §1.6, accepted |
| Defer IaC to v1.4 | Ansible/Terraform serves SRE, not AI dev audience | User pivot reframing |
| Defer observability to v1.4 | Prometheus exporter useful but not load-bearing for "CLI authority" | Same |
| Adopt Lane G (CLI UX black-belt) | Neither Plan A nor Plan B explicitly covered this; user pivot mandated | User 2026-05-22 |
| Keep critical path < 3 calendar weeks per lane | Solo developer sustainability | Plan A §6.4 + Codex Section 8 |
| `release-please` over manual release.yml | Reduces release fatigue, ships SBOM/cosign in one workflow | Plan A 2.16 |
