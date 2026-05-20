# RustSkills Sources Index

- **Document ID**: `rustskills-sources`
- **Version**: `v0.1.0`
- **Generated from**: `rustskills_master.md`
- **Snapshot date**: 2026-04-29 JST
- **Purpose**: RustSkillsのcrate/tool/standardに関する一次情報リンク、確認対象、更新頻度を管理する。

---

## Table of Contents

- 0. Source Priority
- 0.5 AI Agent / Skills / Prompting Sources
- 1. Crate / Tool Source Register
- 2. Standards / Advisory Sources
- 3. Special Watchlist
- 4. Source Record Template
- 5. Update Rule

---

## 0. Source Priority

1. 公式ドキュメント / official website
2. docs.rs latest crate page
3. crates.io crate page / versions / yanked status
4. GitHub repository releases / changelog / tags / issues
5. RustSec Advisory DB / GitHub Advisory
6. RFC / IETF / W3C / WHATWG / official standards
7. upstream PR / issue for breaking changes

---

## 0.5 AI Agent / Skills / Prompting Sources

| Source ID | Title | URL | Type | Covers / Function | Lane | Status | Last Checked | Update Frequency | Notes |
|---|---|---|---|---|---|---|---|---|---|
| SRC-AI001 | Codex Agent Skills | https://developers.openai.com/codex/skills | official-doc | Codex Skill構造、`SKILL.md`、progressive disclosure、optional scripts/references/assets | AI Agent Skills | Core | 2026-04-29 | monthly | Codex/Claude準拠Skill実体化の一次情報 |
| SRC-AI002 | Codex AGENTS.md Guide | https://developers.openai.com/codex/guides/agents-md | official-doc | `AGENTS.md` / `AGENTS.override.md`、project instruction discovery | AI Agent Instructions | Core | 2026-04-29 | monthly | repository-level coding instructions |
| SRC-AI003 | Codex Best Practices | https://developers.openai.com/codex/learn/best-practices | official-doc | review instructions、custom review、coding agent workflow | AI Agent Review | Context | 2026-04-29 | monthly | code_review.md連携など |
| SRC-AI004 | Skills in ChatGPT | https://help.openai.com/en/articles/20001066-skills-in-chatgpt | official-doc | ChatGPT Skills、reusable workflows、instructions/examples/code | ChatGPT Skills | Context | 2026-04-29 | monthly | ChatGPT用Skill化の一次情報 |
| SRC-AI005 | Claude Code Skills | https://code.claude.com/docs/en/skills | official-doc | Claude Code skills、Agent Skills open standard、slash invocation | Claude Skills | Core | 2026-04-29 | monthly | Claude Code対応の一次情報 |
| SRC-AI006 | Claude Prompting Best Practices | https://docs.anthropic.com/en/prompt-library/library | official-doc | Claude prompting、構造化出力、agentic systems | Claude Prompting | Context | 2026-04-29 | monthly | update prompt改善用 |
| SRC-AI007 | Claude Web Search Tool | https://docs.anthropic.com/en/docs/build-with-claude/tool-use/web-search-tool | official-doc | real-time web search、citations | Claude Research | Context | 2026-04-29 | monthly | Web調査前提の更新時に参照 |
| SRC-AI008 | Gemini Deep Research | https://support.google.com/gemini/answer/15719111 | official-doc | Gemini Apps Deep Research、Google Search、Drive、file、NotebookLM sources | Gemini Research | Context | 2026-04-29 | monthly | Gemini WebUI調査用 |
| SRC-AI009 | Gemini Prompt Design Strategies | https://ai.google.dev/gemini-api/docs/prompting-strategies | official-doc | Gemini prompt design、iterative prompting | Gemini Prompting | Context | 2026-04-29 | monthly | update prompt改善用 |
| SRC-AI010 | Gemini Grounding with Google Search | https://ai.google.dev/gemini-api/docs/google-search | official-doc | real-time web grounding、source citation | Gemini Research | Context | 2026-04-29 | monthly | API側のWeb grounding情報 |

---

## 1. Crate / Tool Source Register

| Source ID | Title | URL | Type | Covers / Function | Lane | Status | Last Checked | Update Frequency | Notes |
|---|---|---|---|---|---|---|---|---|---|
| SRC-A001 | tokio | https://docs.rs/crate/tokio/latest | docs.rs | 非同期ランタイム | Async I/O | Core | 2026-04-29 | monthly | version snapshot: 1.52.1 |
| SRC-A002 | reqwest | https://docs.rs/crate/reqwest/latest | docs.rs | 高レベルHTTPクライアント | Async HTTP | Core | 2026-04-29 | monthly | version snapshot: 0.13.3 |
| SRC-A003 | tower | https://docs.rs/crate/tower/latest | docs.rs | Service/Layer制御面 | Middleware | Core | 2026-04-29 | monthly | version snapshot: 0.5.3 |
| SRC-A004 | tower-http | https://docs.rs/crate/tower-http/latest | docs.rs | HTTP middleware | Middleware | Adopt | 2026-04-29 | monthly | version snapshot: 0.6.8 |
| SRC-A005 | axum | https://docs.rs/crate/axum/latest | docs.rs | API/SSR gateway | API Server | Adopt | 2026-04-29 | monthly | version snapshot: 0.8.9 |
| SRC-A006 | governor | https://docs.rs/crate/governor/latest | docs.rs | レート制御 | Rate Limit | Adopt | 2026-04-29 | monthly | version snapshot: 0.10.4 |
| SRC-A007 | bytes | https://docs.rs/crate/bytes/latest | docs.rs | I/O共通バッファ | Zero-copy Buffer | Adopt | 2026-04-29 | monthly | version snapshot: 1.11.1 |
| SRC-A008 | hyper | https://docs.rs/crate/hyper/latest | docs.rs | 高性能HTTP hot path | Low-level HTTP | Adopt | 2026-04-29 | monthly | version snapshot: 1.9.0 |
| SRC-A009 | tokio-uring | https://docs.rs/crate/tokio-uring/latest | docs.rs | Linux専用I/O | io_uring | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.5.0 |
| SRC-A010 | monoio | https://docs.rs/crate/monoio/latest | docs.rs | io_uring / shared-nothing | Thread-per-core | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.2.4 |
| SRC-A011 | rayon | https://docs.rs/crate/rayon/latest | docs.rs | CPU並列処理 | CPU Parallel | Core | 2026-04-29 | monthly | version snapshot: 1.12.0 |
| SRC-A012 | scraper | https://docs.rs/crate/scraper/latest | docs.rs | フォーム/HTML抽出 | HTML Parse | Core | 2026-04-29 | monthly | version snapshot: 0.26.0 |
| SRC-A013 | serde_urlencoded | https://docs.rs/crate/serde_urlencoded/latest | docs.rs | form body生成 | Encoding | Adopt | 2026-04-29 | monthly | version snapshot: 0.7.1 |
| SRC-A014 | polars | https://docs.rs/crate/polars/latest | docs.rs | 列指向バッチ分析 | DataFrame | Core | 2026-04-29 | monthly | version snapshot: 0.53.0 |
| SRC-W001 | leptos | https://docs.rs/crate/leptos/latest | docs.rs | Rust fullstack UI | Web/WASM | Core | 2026-04-29 | monthly | version snapshot: 0.8.19 |
| SRC-W002 | leptos_router | https://docs.rs/crate/leptos_router/latest | docs.rs | Leptos routing | Web/WASM | Core | 2026-04-29 | monthly | version snapshot: 0.8.13 |
| SRC-W003 | wasm-bindgen | https://docs.rs/crate/wasm-bindgen/latest | docs.rs | Rust-JS boundary | Web/WASM | Core | 2026-04-29 | monthly | version snapshot: 0.2.120 |
| SRC-W004 | web-sys | https://docs.rs/crate/web-sys/latest | docs.rs | Browser API binding | Web/WASM | Core | 2026-04-29 | monthly | version snapshot: 0.3.97 |
| SRC-W005 | gloo-net | https://docs.rs/crate/gloo-net/latest | docs.rs | WASM HTTP | Web/WASM | Core | 2026-04-29 | monthly | version snapshot: 0.7.0 |
| SRC-W006 | tailwind_fuse | https://docs.rs/tailwind_fuse | docs.rs | Tailwind class merge | UI | Core | 2026-04-29 | monthly | version snapshot: 0.3.2 |
| SRC-W007 | talc | https://docs.rs/crate/talc/latest | docs.rs | no_std/WASM allocator | Allocator/WASM | Adopt | 2026-04-29 | monthly | version snapshot: 5.0.3 |
| SRC-W008 | smallvec | https://docs.rs/crate/smallvec/latest | docs.rs | 小Vecのstack最適化 | Memory | Adopt | 2026-04-29 | monthly | version snapshot: 1.15.1 |
| SRC-W009 | bytemuck | https://docs.rs/crate/bytemuck/latest | docs.rs | POD byte casting | Byte Cast | Adopt | 2026-04-29 | monthly | version snapshot: 1.25.0 |
| SRC-T001 | ratatui | https://docs.rs/crate/ratatui/latest | docs.rs | TUI rendering | TUI | Core | 2026-04-29 | monthly | version snapshot: 0.30.0 |
| SRC-T002 | crossterm | https://docs.rs/crate/crossterm/latest | docs.rs | terminal backend | TUI | Core | 2026-04-29 | monthly | version snapshot: 0.29.0 |
| SRC-T003 | cpal | https://docs.rs/crate/cpal/latest | docs.rs | cross-platform audio I/O | Audio | Core | 2026-04-29 | monthly | version snapshot: 0.17.3 |
| SRC-T004 | ringbuf | https://docs.rs/crate/ringbuf/latest | docs.rs | lock-free SPSC FIFO | Audio | Adopt | 2026-04-29 | monthly | version snapshot: 0.4.8; crates.io 0.4.9 is yanked and must not be adopted |
| SRC-T005 | symphonia | https://docs.rs/crate/symphonia/latest | docs.rs | pure Rust audio decode | Audio | Adopt | 2026-04-29 | monthly | version snapshot: 0.5.5 |
| SRC-T006 | audio_thread_priority | https://docs.rs/crate/audio_thread_priority/latest | docs.rs | audio RT priority | Audio | Adopt | 2026-04-29 | monthly | version snapshot: 0.35.1 |
| SRC-T007 | tokio-util | https://docs.rs/crate/tokio-util/latest | docs.rs | cancellation/codec | Async Utility | Core | 2026-04-29 | monthly | version snapshot: 0.7.18 |
| SRC-T008 | reqwest-eventsource | https://docs.rs/crate/reqwest-eventsource/latest | docs.rs | SSE client | Streaming | Core | 2026-04-29 | monthly | version snapshot: 0.6.0 |
| SRC-T009 | flume | https://docs.rs/crate/flume/latest | docs.rs | sync/async MPMC | Channel | Adopt | 2026-04-29 | monthly | version snapshot: 0.12.0 |
| SRC-T010 | crossbeam | https://docs.rs/crate/crossbeam/latest | docs.rs | queues/epoch/channel | Concurrency | Adopt | 2026-04-29 | monthly | version snapshot: 0.8.4 |
| SRC-T011 | quinn | https://docs.rs/crate/quinn/latest | docs.rs | QUIC transport, streams, datagrams | QUIC | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.11.9; verify transitive quinn-proto advisory status |
| SRC-C001 | rustls | https://docs.rs/crate/rustls/latest | docs.rs | TLS 1.2/1.3 | TLS | Core | 2026-04-29 | monthly | version snapshot: 0.23.40 |
| SRC-C002 | ring | https://docs.rs/crate/ring/latest | docs.rs | 既存TLS/crypto依存 | Crypto | Conditional | 2026-04-29 | monthly | version snapshot: 0.17.14 |
| SRC-C003 | graviola | https://docs.rs/graviola | docs.rs | Rustls provider candidate | Crypto Provider | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.3.4 |
| SRC-C004 | rustls-graviola | https://docs.rs/rustls-graviola | docs.rs | rustls integration | Crypto Provider | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.3.4 |
| SRC-C005 | aes-gcm | https://docs.rs/crate/aes-gcm/latest | docs.rs | AES-GCM | AEAD | Core | 2026-04-29 | monthly | version snapshot: 0.10.3 |
| SRC-C006 | chacha20poly1305 | https://docs.rs/crate/chacha20poly1305/latest | docs.rs | ChaCha20-Poly1305 | AEAD | Adopt | 2026-04-29 | monthly | version snapshot: 0.10.1 |
| SRC-C007 | x25519-dalek | https://docs.rs/crate/x25519-dalek/latest | docs.rs | X25519鍵交換 | KEX | Core | 2026-04-29 | monthly | version snapshot: 2.0.1 |
| SRC-C008 | ed25519-dalek | https://docs.rs/crate/ed25519-dalek/latest | docs.rs | Ed25519署名 | Signature | Adopt | 2026-04-29 | monthly | version snapshot: 2.2.0 |
| SRC-C009 | argon2 | https://docs.rs/crate/argon2/latest | docs.rs | password hashing/KDF | KDF | Core | 2026-04-29 | monthly | version snapshot: 0.5.3 |
| SRC-C010 | hpke | https://docs.rs/crate/hpke/latest | docs.rs | Pure Rust HPKE | HPKE | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.13.0 |
| SRC-C011 | hpke-rs | https://docs.rs/hpke-rs | docs.rs | flexible backend HPKE | HPKE | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.6.1 |
| SRC-C012 | snow | https://docs.rs/crate/snow/latest | docs.rs | Noise protocol | Noise | Adopt/R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.10.0 |
| SRC-C013 | jsonwebtoken | https://docs.rs/crate/jsonwebtoken/latest | docs.rs | JWT | Auth | Core | 2026-04-29 | monthly | version snapshot: 10.3.0 |
| SRC-D001 | serde | https://docs.rs/crate/serde/latest | docs.rs | 型付きserde | Serialization | Core | 2026-04-29 | monthly | version snapshot: 1.0.228 |
| SRC-D002 | serde_json | https://docs.rs/crate/serde_json/latest | docs.rs | JSON baseline | JSON | Core | 2026-04-29 | monthly | version snapshot: 1.0.149 |
| SRC-D003 | simd-json | https://docs.rs/crate/simd-json/latest | docs.rs | JSON hot path | JSON/SIMD | Adopt | 2026-04-29 | monthly | version snapshot: 0.17.0 |
| SRC-D004 | rkyv | https://docs.rs/crate/rkyv/latest | docs.rs | frozen snapshot | Zero-copy Serde | Adopt | 2026-04-29 | monthly | version snapshot: 0.8.16 |
| SRC-D005 | zerocopy | https://docs.rs/crate/zerocopy/latest | docs.rs | fixed binary header | Binary View | Adopt | 2026-04-29 | monthly | version snapshot: 0.8.48 |
| SRC-D006 | surrealdb | https://docs.rs/crate/surrealdb/latest | docs.rs | document-graph DB | DB | Core | 2026-04-29 | monthly | version snapshot: 3.0.5 |
| SRC-D007 | sqlx | https://docs.rs/crate/sqlx/latest | docs.rs | async SQL | SQL | Core | 2026-04-29 | monthly | version snapshot: 0.8.6 |
| SRC-D008 | qdrant-client | https://docs.rs/crate/qdrant-client/latest | docs.rs | Qdrant client | Vector DB | Adopt | 2026-04-29 | monthly | version snapshot: 1.17.0 |
| SRC-D009 | lancedb | https://docs.rs/crate/lancedb/latest | docs.rs | local/serverless vector DB | Vector DB | Adopt/R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.27.2 |
| SRC-D010 | tantivy | https://docs.rs/crate/tantivy/latest | docs.rs | 検索エンジン | Full-text | Adopt | 2026-04-29 | monthly | version snapshot: 0.26.1 |
| SRC-D011 | distx | https://crates.io/crates/distx/0.2.5 | crates.io | Qdrant compatible vector DB | Vector/Similarity | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.2.5 |
| SRC-D012 | distx-similarity | https://docs.rs/distx-similarity | docs.rs | explainable structured similarity | Similarity | R&D | 2026-04-29 | monthly / R&D review | version snapshot: 0.2.5 |
| SRC-M001 | tikv-jemallocator | https://docs.rs/crate/tikv-jemallocator/latest | docs.rs | Linux server allocator | Allocator | Adopt/Measure | 2026-04-29 | monthly | version snapshot: 0.6.1 |
| SRC-M002 | bumpalo | https://docs.rs/crate/bumpalo/latest | docs.rs | 一括破棄arena | Arena | Adopt | 2026-04-29 | monthly | version snapshot: 3.20.2 |
| SRC-M003 | ahash | https://docs.rs/crate/ahash/latest | docs.rs | internal fast hash | Hashing | Adopt | 2026-04-29 | monthly | version snapshot: 0.8.12 |
| SRC-M004 | dashmap | https://docs.rs/crate/dashmap/latest | docs.rs | sharded map | Concurrent Map | Adopt | 2026-04-29 | monthly | version snapshot: 6.1.0 |
| SRC-M005 | parking_lot | https://docs.rs/crate/parking_lot/latest | docs.rs | lightweight lock | Lock | Adopt | 2026-04-29 | monthly | version snapshot: 0.12.5 |
| SRC-M006 | arc-swap | https://docs.rs/crate/arc-swap/latest | docs.rs | hot reload config | Lock-free Config | Adopt | 2026-04-29 | monthly | version snapshot: 1.9.1 |
| SRC-M007 | moka | https://docs.rs/crate/moka/latest | docs.rs | async cache | Cache | Adopt | 2026-04-29 | monthly | version snapshot: 0.12.15 |
| SRC-M008 | once_cell | https://docs.rs/crate/once_cell/latest | docs.rs | static selectors/config | Lazy Init | Adopt | 2026-04-29 | monthly | version snapshot: 1.21.4 |
| SRC-E001 | tracing | https://docs.rs/crate/tracing/latest | docs.rs | span/event | Observability | Core | 2026-04-29 | monthly | version snapshot: 0.1.44 |
| SRC-E002 | tracing-subscriber | https://docs.rs/crate/tracing-subscriber/latest | docs.rs | log/JSON/filter | Observability | Adopt | 2026-04-29 | monthly | version snapshot: 0.3.23 |
| SRC-E003 | anyhow | https://docs.rs/crate/anyhow/latest | docs.rs | app error handling | Error | Core | 2026-04-29 | monthly | version snapshot: 1.0.102 |
| SRC-E004 | thiserror | https://docs.rs/crate/thiserror/latest | docs.rs | library typed error | Error | Adopt | 2026-04-29 | monthly | version snapshot: 2.0.18 |
| SRC-E005 | clap | https://docs.rs/crate/clap/latest | docs.rs | CLI parser | CLI | Core | 2026-04-29 | monthly | version snapshot: 4.6.1 |
| SRC-E006 | indicatif | https://docs.rs/crate/indicatif/latest | docs.rs | progress UI | CLI | Core | 2026-04-29 | monthly | version snapshot: 0.18.4 |
| SRC-U001 | cargo-audit | https://docs.rs/crate/cargo-audit/latest | docs.rs | RustSec audit | Update/Security | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.22.1 |
| SRC-U002 | cargo-deny | https://docs.rs/crate/cargo-deny/latest | docs.rs | license/advisory/bans | Update/Security | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.19.4 |
| SRC-U003 | cargo-outdated | https://docs.rs/crate/cargo-outdated/latest | docs.rs | outdated deps | Update | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.19.0 |
| SRC-U004 | cargo-semver-checks | https://docs.rs/crate/cargo-semver-checks/latest | docs.rs | semver break check | Update | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.47.0 |
| SRC-U005 | cargo-bloat | https://docs.rs/crate/cargo-bloat/latest | docs.rs | binary size analysis | Perf/Size | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.12.1 |
| SRC-U006 | cargo-udeps | https://docs.rs/crate/cargo-udeps/latest | docs.rs | unused deps | Hygiene | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.1.60 |
| SRC-U007 | cargo-nextest | https://docs.rs/crate/cargo-nextest/latest | docs.rs | fast test runner | Test | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.9.133 |
| SRC-U008 | criterion | https://docs.rs/crate/criterion/latest | docs.rs | statistical benchmark | Benchmark | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.8.2 |
| SRC-U009 | iai-callgrind | https://docs.rs/crate/iai-callgrind/latest | docs.rs | instruction-level benchmark | Benchmark | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.16.1 |
| SRC-U010 | pprof | https://docs.rs/crate/pprof/latest | docs.rs | CPU profiling | Profiling | Tool | 2026-04-29 | weekly / release-triggered | version snapshot: 0.15.0 |

---

## 2. Standards / Advisory Sources

| Source ID | Title | URL | Type | Covers / Function | Update Frequency |
|---|---|---|---|---|---|
| SRC-STANDARD-RUSTSEC | RustSec Advisory Database | https://rustsec.org/advisories/ | advisory | Rust crate security advisories | weekly / urgent |
| SRC-STANDARD-RUSTSEC-DB | RustSec advisory-db GitHub | https://github.com/RustSec/advisory-db | advisory | machine-readable advisory DB | weekly / urgent |
| SRC-STANDARD-IETF-HPKE | RFC 9180: Hybrid Public Key Encryption | https://www.rfc-editor.org/rfc/rfc9180 | standard | HPKE protocol reference | release-triggered |
| SRC-STANDARD-IETF-X25519 | RFC 7748: Elliptic Curves for Security | https://www.rfc-editor.org/rfc/rfc7748 | standard | X25519/X448 reference | rare / security review |
| SRC-STANDARD-NOISE | Noise Protocol Framework | https://noiseprotocol.org/ | standard | Noise handshake patterns | monthly / security review |
| SRC-STANDARD-TLS13 | RFC 8446: TLS 1.3 | https://www.rfc-editor.org/rfc/rfc8446 | standard | TLS 1.3 reference | rare / security review |
| SRC-STANDARD-WASM | WebAssembly official site | https://webassembly.org/ | official-doc | WASM platform reference | monthly |
| SRC-STANDARD-WHATWG-FETCH | WHATWG Fetch Standard | https://fetch.spec.whatwg.org/ | standard | browser fetch behavior | monthly |
| SRC-ADVISORY-QUINN-PROTO-2026-0037 | RUSTSEC-2026-0037: quinn-proto DoS | https://rustsec.org/advisories/RUSTSEC-2026-0037.html | advisory | quinn-proto patched >=0.11.14 | release-triggered |
| SRC-ADVISORY-HPKE-RS-2026-0069-0072 | RUSTSEC hpke-rs / hpke-rs-rust-crypto advisory set | https://rustsec.org/advisories/ | advisory | hpke-rs advisories patched >=0.6.0; hpke-rs-rust-crypto patched >=0.6.0 | release-triggered |

---

## 3. Special Watchlist


| Target | Watch reason | Required action |
|---|---|---|
| ringbuf | docs.rs/latestとcrates.io latestに差異が出る可能性 | 採用前にdocs build状態、crates.io version、changelogを確認 |
| distx / distx-core | yanked情報・version整合性の確認が必要 | crates.io versions/yankedとGitHub releasesを確認し、R&D扱いを維持 |
| graviola / rustls-graviola | 新しいCryptoProvider候補。CPU featureとproduction readinessに注意 | canary、interop、audit status、fallbackを確認 |
| hpke / hpke-rs / snow | 暗号・E2EEに関わるためaudit statusが重要 | RFC整合、test vector、advisory、dependency treeを確認 |
| quinn / quinn-proto | RUSTSEC-2026-0037 patched at quinn-proto >=0.11.14 | cargo audit and Cargo.lock transitive version gate before any QUIC rollout |
| tokio-uring / monoio | Linux限定、runtime interop、成熟度に注意 | 標準Tokio fallbackとbenchmarkを必須化 |
| talc | WASM/no_std allocator。効果はアプリ依存 | Leptos実アプリでbundle size/RSS/allocをA/B test |
| ring / aws-lc-rs indirectly | C/assembly/native build依存の可能性 | 秘匿バイナリではCargo featureと依存ツリー監査 |

---

## 4. Source Record Template


```yaml
source_id: SRC-<ID>
title: <official title>
url: <url>
type: docs.rs | crates.io | github | advisory | standard | official-doc
covers:
  - latest version
  - feature flags
  - changelog
  - security
last_checked: 2026-04-29
update_frequency: monthly | weekly | release-triggered
trusted_level: primary | secondary | context
notes: ...
```

---

## 5. Update Rule


`rustskills_sources.md` は、単なるURL集ではなく、Masterの意思決定根拠。crate更新・採用判断・R&D昇格のたびに、必ず `last_checked`、`version snapshot`、`notes` を更新する。
