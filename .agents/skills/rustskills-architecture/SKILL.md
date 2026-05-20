---
name: rustskills-architecture
description: RustSkills / REV-C Inc. systems architecture and implementation skill. Use when designing, reviewing, implementing, benchmarking, or updating high-load Rust async HTTP workers, Leptos/WASM builders, Ratatui+CPAL realtime audio agents, E2EE/privacy infrastructure, autonomous AI/data/search platforms, and Rust dependency governance.
---

# RustSkills Skill Hub

- **Document ID**: `rustskills-skills`
- **Version**: `v0.1.1`
- **Snapshot date**: 2026-04-29 JST
- **Generated from**: `references/rustskills_master.md`
- **Target context**: REV-C Inc. / RustSkills / CCTeam / Social Psychometrics CRM / 高負荷送信基盤 / Leptos Web Builder / TUI AI Agent / E2EE Infrastructure

この `SKILL.md` は Codex / Codex loader が読む入口。詳細資料は `references/` に分割し、このファイルはナビゲーションと最重要ルールだけを保持する。

---

## 1. Non-negotiable rules

- 高負荷クローラー、フォーム送信、秘匿通信、AIエージェントは、**許可済み業務、同意済みデータ処理、正当な負荷試験、自社管理対象** に限定する。
- 外部サービスへ負荷をかける処理は、必ずレート制限、監査ログ、バックプレッシャー、停止スイッチ、失敗分類を持つ。
- PII、secret、token、鍵素材、音声データ、心理推定データはログへ出さない。
- 匿名性・暗号化は、プライバシー、機密性、耐障害性、検閲耐性、内部統制のために使う。
- 無制限 `spawn`、unbounded channel、requestごとの `Client` 作成、callback内alloc、lock保持中await、巨大JSON一括deserializeを禁止する。
- 速さはp50/p95/p99、RSS、allocations/op、WASM size、callback duration、handshake latency、vector search latencyで判断する。
- pre / alpha / beta / rc / dev は最新安定版として扱わない。
- yanked versionは採用しない。
- 暗号・TLS・Noise・HPKE・QUICは `cargo audit` / `cargo deny` と transitive dependency を必ず確認する。

---

## 2. Lane decision map

| Lane | Use when | Load reference |
|---|---|---|
| Async I/O | tokio/reqwest/tower/hyper/bytes設計、API、ジョブ、LLM通信 | `references/async_io.md` |
| Crawler/Form Sender | 許可済み大量HTTP処理、フォーム抽出、送信制御 | `references/crawler_form_sender.md` |
| Extreme Linux I/O | tokio-uring/monoio/io_uring/thread-per-core検証 | `references/extreme_io_linux.md` |
| Leptos/WASM | Web Builder、SSR、hydration、WASMサイズ最適化 | `references/leptos_wasm_builder.md` |
| TUI Realtime Audio | ratatui/cpal/ringbuf/音声callback/LLM stream | `references/tui_realtime_audio_agent.md` |
| E2EE/Crypto | rustls、x25519、ed25519、hpke、snow、graviola | `references/e2ee_crypto.md` |
| AI/Data/Search | SurrealDB、SQLx、Polars、Qdrant、LanceDB、Tantivy、rkyv | `references/ai_data_search.md` |
| Memory/Perf | rkyv、simd-json、jemalloc、talc、smallvec、bumpalo、dashmap | `references/memory_performance.md` |
| Observability/Update | tracing、cargo audit/deny/outdated、source governance | `references/observability_update_governance.md` |

Normal use starts with the narrow lane reference above. Do not load the master/source/update/audit files for ordinary implementation work.

For packaging, update, audit, or source-traceability work, load `references/packaging_navigation.md` first. It explains when to read `references/rustskills_master.md`, `references/rustskills_sources.md`, `references/rustskills_update_prompt.md`, and `references/rustskills_pack_audit_2026-04-29.md`.

---

## 3. Canonical architecture patterns

### 3.1 High-load HTTP

```text
input stream
  -> bounded queue
  -> per-key governor limiter
  -> tower Service stack
  -> reqwest standard client or hyper hotpath client
  -> response classifier
  -> audit/event sink
  -> retry/dead-letter queue
```

Use `reqwest` for business HTTP. Use `hyper + bytes` only for measured hot paths. Never create a new `reqwest::Client` per request.

### 3.2 Realtime audio

```text
cpal callback
  -> ringbuf SPSC
  -> frame aggregator
  -> VAD/resample/encode worker
  -> LLM/ASR stream
  -> TUI state reducer
  -> ratatui render loop
```

Callback code must be allocation-free, non-blocking, and must not perform network I/O or JSON parsing.

### 3.3 E2EE / privacy

```text
public edge: rustls / mTLS / short-lived certs
payload layer: hpke or snow, R&D-gated
identity: ed25519-dalek
key exchange: x25519-dalek
AEAD: chacha20poly1305 or aes-gcm
storage: argon2 + AEAD + zeroize discipline
```

For HPKE and QUIC, check advisories on both direct crates and transitive crates such as `hpke-rs-rust-crypto`, `quinn-proto`, `rustls-webpki`, and `aws-lc-sys`.

### 3.4 AI/Data

```text
PostgreSQL/sqlx: auth, billing, audit, strong consistency
SurrealDB: document-graph state, agents, workflows
Qdrant/LanceDB: vector retrieval
Tantivy: full-text search
Polars: offline/batch features
rkyv: frozen snapshots and context bundles
```

Do not store raw PII in vector payloads. Keep deletion and consent boundaries explicit.

---

## 4. Current critical watchlist

| Target | Status | Required action |
|---|---|---|
| `ringbuf` | adopt `0.4.8`; `0.4.9` is yanked | never pin yanked version; verify docs.rs/latest and crates.io before update |
| `quinn` / `quinn-proto` | `quinn` latest docs show `0.11.9`; `quinn-proto` advisory patched at `>=0.11.14` | lockfile must resolve patched `quinn-proto`; otherwise hold QUIC rollout |
| `hpke-rs` / `hpke-rs-rust-crypto` | `0.6.1` is latest; advisories are patched at `>=0.6.0` | R&D only until audit, test vectors, provider choice, and cargo audit pass |
| `graviola` / `rustls-graviola` | promising Rustls provider candidate | R&D only; verify CPU feature, interop, fallback, advisory status |
| `tokio-uring` / `monoio` | Linux-specific extreme I/O | benchmark first; standard Tokio fallback required |
| `distx` / `distx-core` | R&D similarity engine | verify yanked/version history and production readiness |
| `talc` | WASM/no_std allocator | A/B test WASM size, allocation behavior, runtime stability |

---

## 5. Update workflow

1. Run local checks when a repo exists:

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

2. Use `references/rustskills_update_prompt.md` for ChatGPT / Codex / Gemini Deep Research.
3. Update `references/rustskills_sources.md` first, then `references/rustskills_master.md`, then lane references.
4. Every dependency decision must include: version diff, yanked status, advisory status, feature/default-feature diff, MSRV, license, benchmark impact, and project impact.

---

## 6. Minimal answer format for agents

When asked to make or review an implementation, respond with:

```text
Decision: Adopt / Hold / Reject / R&D
Reason:
Required crates:
Forbidden patterns:
Architecture:
Tests:
Observability:
Security/compliance:
Files to change:
```

For deep research updates, follow the full format in `references/rustskills_update_prompt.md`.
