# RustSkills Knowledge Pack

- **Version**: `v0.1.2`
- **Snapshot date**: 2026-04-29 JST
- **Registry recheck**: 2026-05-06 JST spot-check via crates.io/cargo for stale watchlist items
- **Owner context**: REV-C Inc. / RustSkills / CCTeam / Social Psychometrics CRM / 高負荷送信基盤 / Leptos Web Builder / TUI AI Agent / E2EE Infrastructure

RustSkills Knowledge Pack v0.1.2 は、日本発の世界基準Rustエンジニアリングプラットフォームを作るための、技術選定・実装Skill・更新体制・ソース管理をまとめた5つの必須ファイルと `references/` 補助ファイルで構成するナレッジ基盤です。`rust-skills-master.md` が単一の真実源で、`references/` はMasterから切り出したレーン別詳細です。

---

## File Map

| File | Role | Use |
|---|---|---|
| `rust-skills-master.md` | 単一の真実源 | 技術体系、crate register、decision records、playbook、更新ルールを保持する親ファイル |
| `SKILL.md` | Codex / Claude / Gemini 実装Skill | AI coding agentへ渡す実装ルール、禁止パターン、canonical architecture、SLO |
| `rust-skills-update-prompt.md` | Deep Research更新用Prompt | ChatGPT/Claude/Gemini Web UIや高性能モデルに渡して、crate更新・リスク評価・patch案を作る |
| `rust-skills-sources.md` | Source Index | docs.rs、crates.io、公式標準、RustSecなどのURLと確認対象を管理する |
| `README.md` | このファイル | 全体の使い方、更新フロー、採用優先度を示す |

Audit files:

- `rust-skills-pack-audit-2026-04-29-v0.1.2.md` — current versioned audit.
- `rust-skills-pack-audit-2026-04-29.md` — historical input audit retained for context only.

### Reference Map

| Reference | Role |
|---|---|
| `references/async-io.md` | Tokio/reqwest/tower/hyper/bytesを中心にした標準Async I/Oレーン |
| `references/crawler-form-sender.md` | 許可済みクローラー、フォーム抽出、送信制御、監査、バックプレッシャー |
| `references/browser-automation-cdp.md` | `chromiumoxide` による許可済みJSレンダリング、SPA検証、スクリーンショット、QA |
| `references/extreme-io-linux.md` | `tokio-uring`、`monoio`、`hyper`、`simd-json` などLinux専用R&D/hot path |
| `references/leptos-wasm-builder.md` | Leptos/WASM、SSR、hydration、WASMサイズ、JS/WASM境界 |
| `references/tui-realtime-audio-agent.md` | Ratatui/CPAL/ringbuf/LLM streamingによるリアルタイム音声TUI |
| `references/e2ee-crypto.md` | rustls、X25519、Ed25519、AEAD、HPKE、Noise、provider監査 |
| `references/ai-data-search.md` | SQLx、SurrealDB、Polars、Qdrant、LanceDB、Tantivy、rkyv、DistX R&D |
| `references/memory-performance.md` | `Bytes`、`rkyv`、`simd-json`、allocator、cache、benchmark/profiling |
| `references/observability-update-governance.md` | tracing、cargo audit/deny/outdated、update cadence、decision rules |

### Master-first Roles

- `rust-skills-master.md` holds all authoritative crate versions, decisions, playbooks, watchlists, and maintenance rules.
- `SKILL.md` is the compact agent entrypoint and navigation layer.
- `references/*.md` are lane extracts for focused implementation work; if they conflict with the master, update the master first and regenerate or patch the reference.
- `rust-skills-sources.md` is the source registry for official docs, crates.io, RustSec, standards, and checked evidence.
- `rust-skills-update-prompt.md` drives Deep Research updates and must ask for patches that flow back into the master first.

---

## Target Domains

1. **超高負荷クローラー＆フォーム送信基盤**
   `tokio`, `reqwest`, `tower`, `governor`, `bytes`, `hyper`, `scraper`, `polars`, `tracing` を中心に、許可済み対象へ安全に高並行処理を行う。

2. **Leptos / WASM フルスタックWebビルダー**
   `leptos`, `leptos_router`, `wasm-bindgen`, `web-sys`, `gloo-net`, `tailwind_fuse`, `talc` を使い、薄いWASM・細粒度UI・SSR/route設計を作る。

3. **TUI + 生音声 + LLM インサイドセールスAIエージェント**
   `ratatui`, `crossterm`, `cpal`, `ringbuf`, `symphonia`, `reqwest-eventsource`, `quinn`, `tracing` でリアルタイム音声・LLMストリーム・TUI表示を構築する。

4. **秘匿E2EEインフラ**
   `rustls`, `x25519-dalek`, `ed25519-dalek`, `chacha20poly1305`, `aes-gcm`, `argon2`, `hpke`, `snow`, `graviola` を用途別に使い分ける。

5. **CCTeam / Social Psychometrics CRM / AI Data基盤**
   `sqlx`, `surrealdb`, `polars`, `qdrant-client`, `lancedb`, `tantivy`, `rkyv`, `simd-json` で状態・検索・特徴量・凍結snapshotを分離する。

---

## Core Architecture Principle

RustSkillsの核は、**標準レーンを強くし、hot pathだけ別レーンで焼き切る**ことです。

```text
Standard lane:
  tokio / reqwest / tower / leptos / ratatui / cpal / rustls / sqlx / surrealdb / tracing

Limit-break lane:
  bytes / hyper / simd-json / rkyv / ringbuf / tokio-uring / monoio / jemalloc / talc

Security & privacy lane:
  rustls / chacha20poly1305 / aes-gcm / x25519-dalek / ed25519-dalek / hpke / snow / graviola

AI & data lane:
  polars / surrealdb / sqlx / qdrant-client / lancedb / tantivy / rkyv
```

---

## Immediate Adoption Priority

### Phase 1: すぐ標準化

- `bytes`
- `tower-http`
- `governor`
- `tracing-subscriber`
- `thiserror`
- `serde_urlencoded`
- `ringbuf`
- `moka`
- `arc-swap`
- `dashmap`

### Phase 2: ベンチマーク導入

- `hyper`
- `simd-json`
- `rkyv`
- `tikv-jemallocator`
- `talc`
- `smallvec`
- `bumpalo`
- `criterion`
- `iai-callgrind`
- `pprof`

### Phase 3: セキュリティ/秘匿R&D

- `rustls-graviola`
- `graviola`
- `chacha20poly1305`
- `ed25519-dalek`
- `hpke` / `hpke-rs`
- `snow`
- `quinn`

### Phase 4: AI/Data検索R&D

- `qdrant-client`
- `lancedb`
- `tantivy`
- `distx`
- `distx-similarity`

### Phase 5: Linux専用限界突破R&D

- `tokio-uring`
- `monoio`
- `tikv-jemallocator`
- thread-per-core worker model

---

## Update Workflow

```text
1. rust-skills-update-prompt.md をAI Deep Researchへ渡す
2. 公式ソースを日本語・英語で調査する
3. Version Diff / Risk Diff / Project Impact / Required Tests を出す
4. cargo audit / deny / outdated / tree -e features を確認する
5. benchmark / WASM size / crypto tests を比較する
6. rust-skills-sources.md に根拠を登録する
7. rust-skills-master.md で Adopt / Hold / Reject / R&D を決める
8. references/*.md / SKILL.md / rust-skills-update-prompt.md / README.md へ派生反映する
```

---

## Safety & Compliance

- 高負荷通信は、許可済み業務・正当な負荷試験・自社管理対象に限定する。
- レート制限、監査ログ、停止スイッチ、バックプレッシャーを必ず設計する。
- PII、secret、token、鍵素材、心理推定データをログへ出さない。
- 暗号は自作しない。nonce再利用禁止、鍵用途分離、audit status確認を必須にする。
- Big Five / 心理推定は確率・仮説として扱い、人間レビュー、同意、削除要求、説明可能性を設計に含める。

---

## Recommended Usage

- **AI coding agentに実装させる**: `SKILL.md` を最初に渡し、必要な `references/*.md` だけを追加で読む。
- **技術選定を確認する**: `rust-skills-master.md` のCrate RegisterとDecision Recordsを見る。
- **アップデート調査をする**: `rust-skills-update-prompt.md` をDeep Researchへ渡す。
- **根拠リンクを確認する**: `rust-skills-sources.md` を見る。
- **全体像を説明する**: この `README.md` を使う。

---

## Maintenance Rule

Masterが親、他ファイルが派生です。意思決定やcrate versionを変える場合は、根拠を `rust-skills-sources.md` に残し、まず `rust-skills-master.md` を更新し、その後 `references/*.md`、`SKILL.md`、`rust-skills-update-prompt.md`、`README.md` に反映してください。


---

## Codex / Claudeへの配置例

Claude Codeではプロジェクトスキルとして次のように配置できます。

```text
.claude/skills/rust-skills-architecture/SKILL.md
```

CodexではAgent Skillsとして `SKILL.md` を含むskill directoryに置くか、repository guidanceとして `AGENTS.md` を併用します。`AGENTS.md` を作る場合は、この `SKILL.md` のGlobal Contractと禁止パターンだけを短く移植してください。


## v0.1.2 update

- `chromiumoxide` を Browser Automation/CDP レーンとして追加。JSレンダリング済みページ、SPAフォーム検証、スクリーンショット、QA用途に限定して採用する。
- 静的HTMLは引き続き `reqwest + scraper` を標準とし、Chromium起動はコストが高い処理としてプール・timeout・kill switch・監査ログを必須化する。
