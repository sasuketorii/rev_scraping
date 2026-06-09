## Skill: rustskills-observability-update-governance

## Table of Contents

- When to use
- Core principles
- Approved tools
- Forbidden patterns
- Canonical architecture
- Implementation recipes
- Benchmarks / SLOs
- Update checklist
- Sources
- Appendix A. Immediate Adoption Priority

### When to use

RustSkillsの依存更新、Deep Research、セキュリティ監査、ベンチマーク、README/Source Index/Master更新、CI整備を行うときに使う。

### Core principles

- Masterを単一の真実源にする。
- 更新は `Adopt / Hold / Reject / R&D` で判断する。
- 公式ドキュメント、docs.rs、crates.io、GitHub releases、RustSec、RFC/標準を優先する。
- 日本語と英語の両方で検索し、リンクと日付を残す。
- 更新前後のSLO比較を行う。

### Approved tools

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| E001 | tracing | 0.1.44 | Observability | Core | span/event | https://docs.rs/crate/tracing/latest |
| E002 | tracing-subscriber | 0.3.23 | Observability | Adopt | log/JSON/filter | https://docs.rs/crate/tracing-subscriber/latest |
| E003 | anyhow | 1.0.102 | Error | Core | app error handling | https://docs.rs/crate/anyhow/latest |
| E004 | thiserror | 2.0.18 | Error | Adopt | library typed error | https://docs.rs/crate/thiserror/latest |
| E005 | clap | 4.6.1 | CLI | Core | CLI parser | https://docs.rs/crate/clap/latest |
| E006 | indicatif | 0.18.4 | CLI | Core | progress UI | https://docs.rs/crate/indicatif/latest |
| U001 | cargo-audit | 0.22.1 | Update/Security | Tool | RustSec audit | https://docs.rs/crate/cargo-audit/latest |
| U002 | cargo-deny | 0.19.4 | Update/Security | Tool | license/advisory/bans | https://docs.rs/crate/cargo-deny/latest |
| U003 | cargo-outdated | 0.19.0 | Update | Tool | outdated deps | https://docs.rs/crate/cargo-outdated/latest |
| U004 | cargo-semver-checks | 0.47.0 | Update | Tool | semver break check | https://docs.rs/crate/cargo-semver-checks/latest |
| U005 | cargo-bloat | 0.12.1 | Perf/Size | Tool | binary size analysis | https://docs.rs/crate/cargo-bloat/latest |
| U006 | cargo-udeps | 0.1.60 | Hygiene | Tool | unused deps | https://docs.rs/crate/cargo-udeps/latest |
| U007 | cargo-nextest | 0.9.133 | Test | Tool | fast test runner | https://docs.rs/crate/cargo-nextest/latest |
| U008 | criterion | 0.8.2 | Benchmark | Tool | statistical benchmark | https://docs.rs/crate/criterion/latest |
| U009 | iai-callgrind | 0.16.1 | Benchmark | Tool | instruction-level benchmark | https://docs.rs/crate/iai-callgrind/latest |
| U010 | pprof | 0.15.0 | Profiling | Tool | CPU profiling | https://docs.rs/crate/pprof/latest |

### Forbidden patterns

- AIの記憶だけでversionを更新する。
- pre/alpha/beta/rcを安定版として扱う。
- yankedやadvisoryを見ずに更新する。
- 依存更新後にMaster/Sourcesを更新しない。

### Canonical architecture

```text
monthly update cycle
  -> collect official sources
  -> cargo audit/deny/outdated/tree
  -> benchmark and tests
  -> AI deep research report
  -> Master patch
  -> Skills/Sources/README regeneration
  -> PR review
```

### Implementation recipes

1. `cargo tree -e features` を更新前後でdiffする。
2. `cargo audit` / `cargo deny` はCI標準にする。
3. public API crateは `cargo-semver-checks` を使う。
4. hot pathは `criterion` / `iai-callgrind` / `pprof` で比較する。
5. 更新AIには `rustskills_update_prompt.md` を渡し、必ずsource URLつきで返させる。

### Benchmarks / SLOs

- build success。
- nextest pass。
- clippy/doc test pass。
- advisory zero or justified exception。
- benchmark no regression。
- WASM size no uncontrolled growth。

### Update checklist

- `rustskills_master.md` のCrate Register更新。
- `rustskills_sources.md` のsource/last_checked更新。
- `rustskills_skills.md` のApproved crates更新。
- `README.md` の導入順・注意点更新。

### Sources

- `rustskills_sources.md` の `U001-U010`, `E001-E006`。

---

## Appendix A. Immediate Adoption Priority

### Phase 1: すぐ標準化

`bytes`, `tower-http`, `governor`, `tracing-subscriber`, `thiserror`, `serde_urlencoded`, `ringbuf`, `moka`, `arc-swap`, `dashmap`

### Phase 2: ベンチマーク導入

`hyper`, `simd-json`, `rkyv`, `tikv-jemallocator`, `talc`, `smallvec`, `bumpalo`, `criterion`, `iai-callgrind`, `pprof`

### Phase 3: セキュリティ/秘匿R&D

`rustls-graviola`, `graviola`, `chacha20poly1305`, `ed25519-dalek`, `hpke`, `hpke-rs`, `snow`, `quinn`

### Phase 4: AI/Data検索R&D

`qdrant-client`, `lancedb`, `tantivy`, `distx`, `distx-similarity`

### Phase 5: Linux専用限界突破R&D

`tokio-uring`, `monoio`, `tikv-jemallocator`, thread-per-core worker model
