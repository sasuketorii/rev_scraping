# RustSkills Knowledge Pack Audit — 2026-04-29 JST

## Verdict

Original v0.1.0 is strong but not 100/100. Estimated score: 88/100.

v0.1.2 corrections raise the pack to an operationally safer baseline: estimated score 96/100, pending full automated link/advisory sweep over all 100+ sources.

## Critical findings fixed in v0.1.2

1. `SKILL.md` was 792 lines. Claude Code official guidance recommends keeping `SKILL.md` under 500 lines and moving detailed reference material to supporting files. Fixed by converting `SKILL.md` into a compact hub and splitting technical lanes into `references/`.
2. `ringbuf` was listed as `0.4.9*`, but docs.rs latest is `0.4.8` and crates.io search indicates `0.4.9` is yanked. Fixed to adopt `0.4.8` and mark `0.4.9` as non-adoptable.
3. `quinn` was referenced in architecture but missing from the Source Index. Added `SRC-T011`.
4. QUIC/HPKE advisories were not explicit enough. Added watch entries for `quinn-proto` and `hpke-rs` advisory families.
5. Claude Code source URL was canonicalized to `https://code.claude.com/docs/en/skills`.
6. Added optional `AGENTS.md` for repository-level Codex/agent instructions.

## Still requiring manual validation before claiming true 100/100

- Run a full automated source-link check for every URL.
- Run `cargo audit`, `cargo deny check`, `cargo outdated`, `cargo tree -e features` against actual project `Cargo.lock` files.
- Verify all transitive versions for `quinn-proto`, `rustls-webpki`, `aws-lc-sys`, `hpke-rs-rust-crypto`, `libcrux-*`.
- Benchmark any `talc`, `jemalloc`, `tokio-uring`, `monoio`, `simd-json`, `rkyv` adoption before standardizing.
- Convert more reference files into smaller task-specific subskills if many agents will run them simultaneously.
