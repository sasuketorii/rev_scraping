# RustSkills Update Prompt: ChatGPT / Claude / Gemini Deep Research 用

- **Document ID**: `rustskills-update-prompt`
- **Version**: `v0.1.0`
- **Generated from**: `rustskills_master.md`
- **Snapshot date**: 2026-04-29 JST
- **用途**: ChatGPT、Claude、GeminiなどのWeb UI / Deep Research / 高性能モデルへ渡し、RustSkillsの技術情報・crateバージョン・リスク・採用判断を更新する。

---

## Table of Contents

- 0. 使い方
- 1. Copy-ready Prompt
- 2. Update Cadence Template
- 3. Local Command Checklist
- 4. Decision Rubric
- 5. Must-update Artifacts

---

## 0. 使い方

このファイルの `1. Copy-ready Prompt` をそのままAIモデルへ貼り付ける。可能なら以下も添付する。

- `rustskills_master.md`
- `SKILL.md`
- `rustskills_sources.md`
- 現在の `Cargo.toml`
- 現在の `Cargo.lock`
- `cargo metadata` 結果
- `cargo tree -e features` 結果
- `cargo audit` / `cargo deny check` / `cargo outdated` 結果
- benchmark baseline
- 変更したいcrate名、理由、対象プロジェクト

---

## 1. Copy-ready Prompt

```markdown
# Role
あなたは、世界トップ1%のRustシニア・システムアーキテクト、パフォーマンスエンジニア、セキュリティレビューア、技術調査リードです。
日本発の世界基準Rustエンジニアリングプラットフォーム「RustSkills」と、REV-C Inc. の実プロダクト群のために、Rust crate / architecture / security / performance情報を更新してください。

# Important Context
対象プロジェクトは次の通りです。

1. 超高負荷クローラー＆フォーム送信基盤
2. Leptos / WASM フルスタックWebビルダー
3. Ratatui + CPAL + LLM streaming のインサイドセールスAIエージェント
4. OpenSSL等C依存を抑えた秘匿E2EEインフラ
5. CCTeam / Social Psychometrics CRM / 自律型エージェント＆データ基盤
6. あなたが保持しているREV-C Inc.に関するメモリや文脈のうち、上記に関連するサービス・構想・制約・好みに寄与するもの

高負荷通信・秘匿通信・心理推定・AIエージェントに関する提案は、許可済み業務、同意済みデータ処理、正当な負荷試験、自社管理対象、法令・規約遵守、監査可能性、レート制御、安全な暗号運用を前提にしてください。

# Research Requirements
必ず日本語と英語の両方で調査してください。
AIの学習済み知識だけで判断せず、最新情報をWebで確認してください。
優先ソースは以下です。

1. 公式ドキュメント
2. docs.rs latest crate page
3. crates.io crate page / versions / yanked status
4. GitHub repository releases / changelog / tags / issues
5. RustSec Advisory DB / GitHub Advisory
6. RFC / IETF / W3C / WHATWG / official standards
7. upstream PR / issue for breaking changes

個人ブログ、SNS、Qiita/Zenn、Reddit等は補助情報として扱い、採用判断の根拠にする場合は公式ソースで裏取りしてください。

# Stability Rules
- pre / alpha / beta / rc / dev は最新安定版として扱わない。
- yanked versionは採用しない。
- docs.rs latestとcrates.io latestが異なる場合は、両方を明記し、どちらを採用候補にすべきか理由を書く。
- RustCrypto、TLS、Noise、HPKE、暗号Provider、E2EE関連は、audit status、C/FFI依存、test vector、nonce/key separation、side-channel注意点を確認する。
- `ring`, `aws-lc-rs`, `graviola`, `rustls-graviola`, `hpke`, `hpke-rs`, `hpke-rs-rust-crypto`, `snow`, `quinn`, `quinn-proto`, `rustls-webpki`, `tokio-uring`, `monoio`, `distx`, `distx-core`, `ringbuf`, `talc` は特に注意して確認する。
- direct dependencyだけでなくtransitive dependencyのadvisoryも確認する。特に `quinn-proto`, `rustls-webpki`, `aws-lc-sys`, `hpke-rs-rust-crypto` はCargo.lock上の実解決versionで判断する。

# Current Target
今回更新したい対象は以下です。

- 対象crate / tool / architecture:
- 更新理由:
- 対象プロジェクト:
- 現在のversion:
- 現在の懸念:

# Expected Output Format
必ず次の形式で出力してください。

## 1. Executive Decision
- Target:
- Decision: Adopt / Hold / Reject / R&D
- One-line reason:
- Confidence: High / Medium / Low

## 2. Version Diff
| crate/tool | current in RustSkills | latest stable | release date | yanked? | docs.rs status | source URL |

## 3. Source Index
| source_id | title | URL | type | what it proves | last checked |

## 4. Risk Diff
- MSRV changes:
- Feature/default feature changes:
- Dependency changes:
- C/FFI/native dependency changes:
- Security advisories:
- License changes:
- Maintenance / release cadence:
- Production readiness:
- Breaking changes:

## 5. Project Impact
- High-load crawler/form sender:
- Leptos/WASM Web Builder:
- TUI realtime audio agent:
- E2EE infrastructure:
- CCTeam / Social Psychometrics CRM / AI data:
- Other Project Owner / REV-C memory-based project impact:

## 6. Performance Impact
- Expected improvement:
- Expected regression risk:
- Required benchmark:
- Metrics to compare:

## 7. Security / Compliance Impact
- PII / secret handling:
- Crypto risk:
- Supply-chain risk:
- Abuse prevention / rate limiting / audit impact:

## 8. Required Tests
- Compile:
- Unit/integration:
- nextest:
- clippy/doc:
- cargo audit/deny:
- cargo tree feature diff:
- benchmark:
- WASM size if relevant:
- crypto/vector/fuzz tests if relevant:

## 9. Cargo Patch Proposal
```toml
# Cargo.toml diff or dependency proposal here
```

## 10. Master Patch Proposal
```diff
# rustskills_master.md に反映すべき差分
```

## 11. Skills Patch Proposal
```diff
# SKILL.md に反映すべき差分
```

## 12. Sources Patch Proposal
```diff
# rustskills_sources.md に反映すべき差分
```

## 13. README Patch Proposal
```diff
# README.md に反映すべき差分
```

## 14. Final Recommendation
- Ship now / Canary / Benchmark first / Research only / Reject
- Next action:
```

---

## 2. Update Cadence Template

### Weekly security sweep

```markdown
対象: RustSec / GitHub Advisory / cargo-audit / cargo-deny
目的: critical/high advisoryとyanked versionの検出
出力: 即時対応リスト、保留理由、Master/Sources patch
```

### Monthly crate sweep

```markdown
対象: Core / Adopt / R&D crate全体
目的: latest stable、MSRV、feature、license、C/FFI、docs build、release cadence確認
出力: Version Diff、Risk Diff、Project Impact、Master Patch
```

### Release-triggered review

```markdown
対象: tokio, reqwest, hyper, tower, leptos, rustls, sqlx, surrealdb, cpal, ratatui, rkyv, simd-json, qdrant/lancedb/tantivy
目的: 大型releaseやsecurity fixの即時評価
出力: Adopt/Hold/Reject/R&D判断と必要テスト
```

### Performance regression review

```markdown
対象: bytes/hyper/simd-json/rkyv/jemalloc/talc/ringbuf/tokio-uring/monoio
目的: p95/p99/RSS/alloc/WASM size/callback durationの退行検出
出力: benchmark report、flamegraph summary、fallback判断
```

---

## 3. Local Command Checklist

AI調査前に可能なら実行する。

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

hot path更新時:

```bash
cargo bench
# optional
cargo install cargo-bloat
cargo bloat --release --crates
```

WASM更新時:

```bash
trunk build --release
wasm-bindgen --version
# wasm-opt if installed
```

---

## 4. Decision Rubric

### Adopt

- latest stableでyankedなし。
- official changelogでbreaking riskが低い。
- MSRV / feature / dependency / licenseが許容範囲。
- benchmark退行なし。
- security advisoryなし、または修正済み。
- fallback不要または容易。

### Hold

- MSRV上昇、feature変更、依存増、docs build不安定、bench退行などがある。
- 本番SLOに不確実性がある。
- migration costが高い。

### Reject

- advisory未修正。
- yanked / unmaintained / license incompatible。
- 既存SLOを壊す。
- 秘匿/安全/法令遵守要件に反する。

### R&D

- 性能上の魅力はあるが成熟度、監査、互換性、運用実績、fallbackに課題がある。
- `tokio-uring`, `monoio`, `graviola`, `rustls-graviola`, `hpke-rs`, `distx` などは原則R&Dから開始する。

---

## 5. Must-update Artifacts

調査後、必ず次の5ファイルへの影響を明示する。

1. `rustskills_master.md`: crate register / decision / playbook / update governance
2. `SKILL.md`: approved crates / forbidden patterns / implementation recipes
3. `rustskills_update_prompt.md`: prompt内の注意crateやrubric
4. `rustskills_sources.md`: source URL / last_checked / source note
5. `README.md`: file map / priority / adoption phase
