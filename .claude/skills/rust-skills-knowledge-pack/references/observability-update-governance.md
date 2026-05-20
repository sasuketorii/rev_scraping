# Observability / Update Governance Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates/tools**: `tracing`, `tracing-subscriber`, `anyhow`, `thiserror`, `clap`, `indicatif`, `cargo-audit`, `cargo-deny`, `cargo-outdated`, `cargo-semver-checks`, `cargo-nextest`, `criterion`, `iai-callgrind`, `pprof`

## Observability Rules

- Use `tracing` spans/events for async causality.
- Include job/conversation/request IDs, attempt, status, latency, host/account/campaign where relevant.
- Keep logs JSON-capable and filterable with `tracing-subscriber`.
- Use `anyhow` at binary/app boundaries and `thiserror` for library/API boundaries.
- Do not log PII, secrets, tokens, keys, raw audio, or sensitive inference data.
- Throttle progress UI and high-volume logs.

## Update Cadence

| Target | Cadence | Action |
|---|---:|---|
| Security advisories | weekly / urgent | `cargo audit`, RustSec, GitHub Advisory, upstream security notes |
| Core crates | monthly | docs.rs, crates.io, GitHub releases, MSRV, features |
| R&D crates | monthly to biweekly | maturity, yanked status, audit, issues, benchmark readiness |
| WASM stack | monthly | bundle size, Leptos/wasm-bindgen/web-sys compatibility |
| Crypto stack | monthly and release-triggered | audit status, dependency tree, provider, CPU constraints |
| Perf-sensitive crates | before/after update | criterion/iai/pprof, RSS, p99 comparison |

## Required Local Checks

```bash
cargo metadata --format-version 1 > target/rustskills-cargo-metadata.json
cargo tree -e features > target/rustskills-cargo-tree-features.txt
cargo audit > target/rustskills-cargo-audit.txt || true
cargo deny check > target/rustskills-cargo-deny.txt || true
cargo outdated > target/rustskills-cargo-outdated.txt || true
cargo nextest run
cargo clippy --all-targets --all-features -- -D warnings
cargo test --doc
```

## Decision Rules

- **Adopt**: stable, not yanked, advisory-clean or patched, acceptable MSRV/features/license, benchmark safe.
- **Hold**: uncertain MSRV, feature, dependency, docs, benchmark, or migration risk.
- **Reject**: unresolved advisory, yanked/unmaintained, license incompatible, SLO-breaking, or compliance-breaking.
- **R&D**: promising but immature, unaudited, not portable, or lacking fallback.

## Artifact Update Order

1. Gather and register evidence in `../rust-skills-sources.md`.
2. Make the decision in `../rust-skills-master.md`.
3. Propagate changed lane details to `references/*.md`.
4. Update `../SKILL.md`, `../rust-skills-update-prompt.md`, and `../README.md` if navigation, workflow, or watchlists changed.
