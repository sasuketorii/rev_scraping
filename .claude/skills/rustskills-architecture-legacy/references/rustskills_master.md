# RustSkills Master: 世界基準Rustエンジニアリング・コア技術体系

- **Document ID**: `rustskills-master`
- **Master Version**: `v0.1.0`
- **作成日**: 2026-04-29 JST
- **対象**: REV-C Inc. / RustSkills / CCTeam / Social Psychometrics CRM / 高負荷送信基盤 / Leptos Web Builder / TUI AI Agent / E2EE Infrastructure
- **位置づけ**: 後続で作る `Skills(codex/claude準拠)`、`Update Prompt`、`Source Index`、`README.md` の親ファイル。以後の更新はこのMasterを単一の真実源として扱う。
- **重要な前提**: 高負荷クローラー・フォーム送信・秘匿通信の設計は、許可済み業務、正当な負荷試験、同意済みデータ処理、法令・利用規約・robots/レート制限・監査ログを守る用途に限定する。匿名性や暗号化はプライバシー、機密保護、耐障害性、検閲耐性のために設計し、違法行為、スパム、回避行為、第三者への過負荷を目的としない。

---

## Table of Contents

- 0. このMasterのゴール
- 1. 対象プロジェクト・ドメイン
- 2. 全体アーキテクチャの基本原則
- 3. 技術レーン設計
- 4. Crate Register: 2026-04-29 Snapshot
- 5. Core Library Decision Records
- 6. RustSkills Workspace Blueprint
- 7. Project-specific Implementation Playbooks
- 8. Update Governance
- 9. AI Deep Research Update Protocol
- 10. Source Policy
- 11. Benchmark & SLO Master
- 12. Skills化マップ
- 13. README抽出方針
- 14. Immediate Adoption Priority
- 15. Master Maintenance Rules
- 16. Open Questions
- 17. Current Decision Summary

---

## 0. このMasterのゴール

RustSkillsは、Rustを単なる「安全で速い言語」として教える場ではなく、REV-Cの実プロダクト群を支える**実戦型Rustアーキテクチャ体系**として作る。目的は次の4つ。

1. **全プロジェクト横断の技術判断を一元化する**
   高負荷I/O、WASM、TUI音声、E2EE、AI/DB、観測性、更新体制を1つの地図にまとめる。

2. **更新に強い構造へする**
   Rust crateは更新が速い。バージョン、MSRV、feature、セキュリティ、性能退行、C/FFI依存、ライセンスを定期的に再検証する。

3. **Skills化しやすい粒度に分解する**
   後で `skills/async-io.md`、`skills/wasm-leptos.md`、`skills/e2ee.md` のようにCodex/Claude/Gemini向けの実行可能な知識単位へ切り出せるよう、章立てとIDを固定する。

4. **世界トップ1%の実装思想を明文化する**
   ゼロコピー、SIMD、ロックフリー、メモリアロケーション最小化、バックプレッシャー、SLO、ベンチマーク駆動、サプライチェーン監査まで含める。

---

## 1. 対象プロジェクト・ドメイン

### D1. 超高負荷クローラー＆フォーム送信基盤

- **目的**: 許可済みの大量ターゲットリスト、業務フォーム、検証対象エンドポイントへ高並行でHTTP処理を行う。
- **主要課題**:
  - 50万件以上の入力を無制限spawnせず処理する。
  - ドメイン別・キャンペーン別・アカウント別のレート制御。
  - 接続プール、タイムアウト、リトライ、監査ログ、失敗分類。
  - HTMLフォーム抽出、hidden token、CSRF token、入力検証。
  - 送信先を壊さないバックプレッシャー。
- **中核レーン**: `tokio`, `reqwest`, `tower`, `governor`, `bytes`, `hyper`, `scraper`, `serde_urlencoded`, `tracing`。
- **限界突破レーン**: `tokio-uring`, `monoio`, `simd-json`, `tikv-jemallocator`, `moka`, `dashmap`。

### D2. フルスタックWebビルダー

- **目的**: `Leptos` / WASM中心で、React以上の体感性能を狙うWeb Builder / CRM UI / RustSkills UI。
- **主要課題**:
  - WASMバイナリ肥大化の抑制。
  - JS/WASM境界回数の削減。
  - signal粒度の制御。
  - SSR / hydration / island 的設計。
  - UI状態とサーバー状態の分離。
- **中核レーン**: `leptos`, `leptos_router`, `wasm-bindgen`, `web-sys`, `gloo-net`, `tailwind_fuse`。
- **限界突破レーン**: `talc`, `smallvec`, `bytemuck`, `rkyv`, `console_error_panic_hook`候補、`wasm-opt`外部ツール。

### D3. インサイドセールスAIエージェント / TUI + 生音声 + LLM

- **目的**: `Ratatui`上でOSマイク音声を拾い、ASR/LLMとストリーミング通信し、リアルタイムにトークスクリプトを出す。
- **主要課題**:
  - 音声callback内でalloc/lock/I/Oをしない。
  - CPAL callback → ring buffer → VAD/ASR/LLM → TUI表示の段分離。
  - SSE/WebSocket/QUICなど複数ストリームの扱い。
  - TUI描画頻度の制御。
  - 会話ごとのtrace-id、レイテンシ予算管理。
- **中核レーン**: `ratatui`, `crossterm`, `cpal`, `tokio-util`, `reqwest-eventsource`, `tracing`。
- **限界突破レーン**: `ringbuf`, `symphonia`, `audio_thread_priority`, `quinn`, `flume`, `crossbeam`。

### D4. 秘匿E2EEインフラ

- **目的**: OpenSSL等への依存を避け、Pure Rust寄りで安全な暗号通信・ペイロード暗号化・署名・鍵交換を構築する。
- **主要課題**:
  - TLS公開エッジとアプリケーションE2EEの役割分離。
  - C/FFI依存監査。
  - nonce再利用禁止、鍵用途分離、前方秘匿性、zeroize。
  - Noise/HPKE/QUICの適切な組み合わせ。
  - 暗号実装の監査状況と成熟度を明示する。
- **中核レーン**: `rustls`, `x25519-dalek`, `aes-gcm`, `argon2`, `jsonwebtoken`, `serde`。
- **限界突破レーン**: `graviola`, `rustls-graviola`, `chacha20poly1305`, `ed25519-dalek`, `hpke`, `hpke-rs`, `snow`, `quinn`, `zeroize`候補。

### D5. 自律型エージェント＆データ基盤

- **目的**: CCTeam的な自律型動的組織AI、Social Psychometrics CRM、Big Five/行動経済学ベースの状態管理・検索・RAGを支える。
- **主要課題**:
  - RDB、document-graph、vector、全文検索の責務分離。
  - エージェント状態スナップショットの高速読み出し。
  - PII分離と削除要求対応。
  - structured similarity / explainable similarity。
  - 監査可能なtool call / decision log。
- **中核レーン**: `surrealdb`, `sqlx`, `polars`, `serde`, `serde_json`, `tracing`。
- **限界突破レーン**: `rkyv`, `qdrant-client`, `lancedb`, `tantivy`, `distx`, `distx-similarity`, `moka`, `arc-swap`, `dashmap`。

---

## 2. 全体アーキテクチャの基本原則

### P1. 標準レーンと限界突破レーンを分離する

RustSkillsでは、すべてを最初から `io_uring` やロックフリーで書かない。標準レーンは保守性、移植性、採用速度を優先し、ホットパスだけ限界突破レーンへ逃がす。

- **標準レーン**: `tokio + reqwest + tower + axum + rustls + sqlx + surrealdb`
- **限界突破レーン**: `hyper + bytes + simd-json + rkyv + tokio-uring/monoio + jemalloc + ringbuf`
- **研究レーン**: `distx`, `graviola`, `hpke-rs`, `monoio`, `tokio-uring` など、成熟度・移植性・監査状況を見ながら採用するもの。

### P2. 一枚岩DBにしない

- **PostgreSQL / SQLx**: 課金、認証、監査、同意、権限、正規化テーブル。
- **SurrealDB**: document-graph、動的組織、エージェント状態、関係性。
- **Qdrant / LanceDB / DistX**: vector / semantic / structured similarity。
- **Tantivy**: 全文検索、通話ログ、ナレッジ、監査検索。
- **Polars**: バッチ分析、特徴量生成、CSV/Parquet/Arrow処理。
- **rkyv**: 静的・凍結状態の高速スナップショット。

### P3. バッファ境界は `Bytes` を第一候補にする

HTTP、SSE、暗号ペイロード、音声フレーム、ログ転送など、I/O境界では `String` / `Vec<u8>` の無駄なcloneを避ける。`Bytes` / `BytesMut` を共通バッファ形式に寄せる。

### P4. callback内・lock内・hot path内でやってはいけないこと

- `cpal` callback内でのalloc、mutex、JSON parse、HTTP送信、ログ大量出力。
- `DashMap` guard保持中の `.await`。
- `Mutex` guard保持中のDBアクセス、ネットワークI/O、重いformat処理。
- requestごとの `reqwest::Client::new()`。
- `tokio::spawn` の無制限連打。
- 大量データへの `fetch_all` / `collect()` の早すぎる呼び出し。
- 暗号nonceの再利用、鍵用途混同、秘密鍵のDebug出力。

### P5. 更新は「速く上げる」ではなく「測って上げる」

Rust crateは進化が速い。update時は次を必ず確認する。

- MSRV変更
- default features変更
- C/FFI依存増減
- advisory / CVE / RUSTSEC
- API break / semver break
- p95/p99 latency
- RSS / allocation count
- bundle size / wasm size
- cryptographic audit status
- license / dual license

---

## 3. 技術レーン設計

### L1. Async I/O 標準レーン

**採用セット**: `tokio`, `reqwest`, `tower`, `tower-http`, `axum`, `governor`, `bytes`, `tracing`, `tracing-subscriber`

**役割**:

- 全APIサーバー、標準HTTPクライアント、LLM通信、DBアクセス、TUIイベント処理の基盤。
- 高負荷フォーム送信の制御プレーン。
- `tower::Service` を共通抽象として、timeout / retry / concurrency limit / rate limit / traceを合成する。

**基本構成**:

```text
Input Source
  -> bounded queue
  -> domain/account/campaign limiter
  -> tower Service stack
  -> reqwest or hyper sender
  -> result classifier
  -> audit log / metrics / retry queue
```

**実装ルール**:

- `Client` は長寿命で共有。
- 同時実行数は `Semaphore` / `tower::limit` / `governor` で三層制御。
- すべての外部I/Oにtimeoutを付与。
- `tracing` spanに `job_id`, `target_host`, `attempt`, `status`, `latency_ms` を入れる。
- unbounded channelは禁止。理由がある場合のみ例外申請。

### L2. Extreme I/O / Linux専用限界突破レーン

**採用セット**: `hyper`, `bytes`, `tokio-uring`, `monoio`, `simd-json`, `tikv-jemallocator`, `moka`, `dashmap`

**役割**:

- Linux専用の高密度HTTP送信ワーカー。
- 大量JSON/HTML/ログ処理。
- NVMe / file cache / response spool / batch ingest。

**標準レーンとの差分**:

- portabilityよりtail latencyとthroughputを優先。
- `reqwest`の便利機能を捨て、`hyper`で薄く作る。
- `Bytes`でpayloadを持ち回す。
- `simd-json`はJSONがボトルネックになった箇所だけ。
- `tokio-uring` / `monoio` はR&Dから始め、測定で勝つ場合だけ本番化。

**採用条件**:

- Linux kernel / deployment targetを固定できる。
- p95/p99・RSS・CPU使用率・syscall countで標準レーンに勝つ。
- 本番障害時に標準レーンへフォールバックできる。

### L3. Web / WASM / Leptos レーン

**採用セット**: `leptos`, `leptos_router`, `wasm-bindgen`, `web-sys`, `gloo-net`, `tailwind_fuse`, `talc`, `smallvec`, `bytemuck`

**役割**:

- RustSkills Web UI。
- Web Builder。
- CRM dashboard。
- Agent orchestration console。

**実装ルール**:

- WASMにはDBクライアントや重い暗号処理を載せない。
- JS/WASM境界はバルク転送。
- `web-sys` featureは必要APIだけ有効化。
- signalの粒度は小さくし、巨大なglobal stateで全画面を揺らさない。
- SSR / server function / API gateway を優先し、client bundleを薄くする。

### L4. TUI / Realtime Audio / LLM レーン

**採用セット**: `ratatui`, `crossterm`, `cpal`, `ringbuf`, `symphonia`, `audio_thread_priority`, `tokio-util`, `flume`, `crossbeam`, `reqwest-eventsource`, `quinn`

**役割**:

- 通話中のリアルタイム支援。
- LLMストリーミング表示。
- ASR/VAD/音声チャンク処理。
- TUI操作と音声処理の分離。

**理想パイプライン**:

```text
OS mic
  -> cpal callback
  -> lock-free SPSC ring buffer
  -> frame normalizer / VAD / encoder
  -> LLM/ASR streaming client
  -> event reducer
  -> ratatui render buffer
```

**実装ルール**:

- callback内alloc禁止。
- callback内mutex禁止。
- callback内HTTP禁止。
- 描画はtoken到着ごとではなくtickで間引く。
- 会話単位でtrace-idを持つ。

### L5. E2EE / Crypto / Privacy レーン

**採用セット**: `rustls`, `rustls-graviola`, `graviola`, `ring`, `aes-gcm`, `chacha20poly1305`, `x25519-dalek`, `ed25519-dalek`, `argon2`, `hpke`, `hpke-rs`, `snow`, `jsonwebtoken`

**役割**:

- 公開APIのTLS。
- アプリケーション層E2EE。
- エージェント/ノード署名。
- 鍵交換、署名、暗号化、パスワードKDF。

**設計原則**:

- 公開TLSと真のE2EE payload暗号化を分ける。
- `ring`は実績と速度が強いが、C/assembly依存・ビルド要件を監査対象にする。
- `graviola` / `rustls-graviola` はCコンパイラなしのrustls CryptoProvider候補。ただし新しさとCPU制約を評価する。
- payload暗号は `X25519/HPKE + ChaCha20Poly1305/AES-GCM` を用途別に選ぶ。
- 署名は `ed25519-dalek` を軸にし、決定ログや設定ファイルに署名を付ける。

### L6. AI / Data / Search レーン

**採用セット**: `serde`, `serde_json`, `simd-json`, `rkyv`, `surrealdb`, `sqlx`, `polars`, `qdrant-client`, `lancedb`, `tantivy`, `distx`, `distx-similarity`, `moka`, `arc-swap`, `dashmap`

**役割**:

- エージェント状態管理。
- CRM分析。
- Big Five / behavioral features。
- RAG / vector search / full-text search。
- 高速snapshot。

**責務分離**:

```text
Postgres/sqlx       -> hard state, auth, billing, consent, audit
SurrealDB           -> dynamic graph/document state
Qdrant/LanceDB      -> embedding/vector retrieval
Tantivy             -> full-text and audit search
DistX               -> explainable structured similarity, R&D
Polars              -> batch feature engineering
rkyv                -> frozen snapshots / static rule sets
```

---

## 4. Crate Register: 2026-04-29 Snapshot

> Versionは2026-04-29 JST時点で、docs.rs / crates.io / 公式ページを中心に確認したスナップショット。pre / alpha / beta / rc は原則採用対象外。ただし研究レーンでは別枠で監視する。

| ID | Crate / Tool | Snapshot Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A001 | tokio | 1.52.1 | Async I/O | Core | 非同期ランタイム | https://docs.rs/crate/tokio/latest |
| A002 | reqwest | 0.13.3 | Async HTTP | Core | 高レベルHTTPクライアント | https://docs.rs/crate/reqwest/latest |
| A003 | tower | 0.5.3 | Middleware | Core | Service/Layer制御面 | https://docs.rs/crate/tower/latest |
| A004 | tower-http | 0.6.8 | Middleware | Adopt | HTTP middleware | https://docs.rs/crate/tower-http/latest |
| A005 | axum | 0.8.9 | API Server | Adopt | API/SSR gateway | https://docs.rs/crate/axum/latest |
| A006 | governor | 0.10.4 | Rate Limit | Adopt | レート制御 | https://docs.rs/crate/governor/latest |
| A007 | bytes | 1.11.1 | Zero-copy Buffer | Adopt | I/O共通バッファ | https://docs.rs/crate/bytes/latest |
| A008 | hyper | 1.9.0 | Low-level HTTP | Adopt | 高性能HTTP hot path | https://docs.rs/crate/hyper/latest |
| A009 | tokio-uring | 0.5.0 | io_uring | R&D | Linux専用I/O | https://docs.rs/crate/tokio-uring/latest |
| A010 | monoio | 0.2.4 | Thread-per-core | R&D | io_uring / shared-nothing | https://docs.rs/crate/monoio/latest |
| A011 | rayon | 1.12.0 | CPU Parallel | Core | CPU並列処理 | https://docs.rs/crate/rayon/latest |
| A012 | scraper | 0.26.0 | HTML Parse | Core | フォーム/HTML抽出 | https://docs.rs/crate/scraper/latest |
| A013 | serde_urlencoded | 0.7.1 | Encoding | Adopt | form body生成 | https://docs.rs/crate/serde_urlencoded/latest |
| A014 | polars | 0.53.0 | DataFrame | Core | 列指向バッチ分析 | https://docs.rs/crate/polars/latest |
| W001 | leptos | 0.8.19 | Web/WASM | Core | Rust fullstack UI | https://docs.rs/crate/leptos/latest |
| W002 | leptos_router | 0.8.13 | Web/WASM | Core | Leptos routing | https://docs.rs/crate/leptos_router/latest |
| W003 | wasm-bindgen | 0.2.120 | Web/WASM | Core | Rust-JS boundary | https://docs.rs/crate/wasm-bindgen/latest |
| W004 | web-sys | 0.3.97 | Web/WASM | Core | Browser API binding | https://docs.rs/crate/web-sys/latest |
| W005 | gloo-net | 0.7.0 | Web/WASM | Core | WASM HTTP | https://docs.rs/crate/gloo-net/latest |
| W006 | tailwind_fuse | 0.3.2 | UI | Core | Tailwind class merge | https://docs.rs/tailwind_fuse |
| W007 | talc | 5.0.3 | Allocator/WASM | Adopt | no_std/WASM allocator | https://docs.rs/crate/talc/latest |
| W008 | smallvec | 1.15.1 | Memory | Adopt | 小Vecのstack最適化 | https://docs.rs/crate/smallvec/latest |
| W009 | bytemuck | 1.25.0 | Byte Cast | Adopt | POD byte casting | https://docs.rs/crate/bytemuck/latest |
| T001 | ratatui | 0.30.0 | TUI | Core | TUI rendering | https://docs.rs/crate/ratatui/latest |
| T002 | crossterm | 0.29.0 | TUI | Core | terminal backend | https://docs.rs/crate/crossterm/latest |
| T003 | cpal | 0.17.3 | Audio | Core | cross-platform audio I/O | https://docs.rs/crate/cpal/latest |
| T004 | ringbuf | 0.4.8 | Audio | Adopt | lock-free SPSC FIFO | https://docs.rs/crate/ringbuf/latest |
| T005 | symphonia | 0.5.5 | Audio | Adopt | pure Rust audio decode | https://docs.rs/crate/symphonia/latest |
| T006 | audio_thread_priority | 0.35.1 | Audio | Adopt | audio RT priority | https://docs.rs/crate/audio_thread_priority/latest |
| T007 | tokio-util | 0.7.18 | Async Utility | Core | cancellation/codec | https://docs.rs/crate/tokio-util/latest |
| T008 | reqwest-eventsource | 0.6.0 | Streaming | Core | SSE client | https://docs.rs/crate/reqwest-eventsource/latest |
| T009 | flume | 0.12.0 | Channel | Adopt | sync/async MPMC | https://docs.rs/crate/flume/latest |
| T010 | crossbeam | 0.8.4 | Concurrency | Adopt | queues/epoch/channel | https://docs.rs/crate/crossbeam/latest |
| C001 | rustls | 0.23.40 | TLS | Core | TLS 1.2/1.3 | https://docs.rs/crate/rustls/latest |
| C002 | ring | 0.17.14 | Crypto | Conditional | 既存TLS/crypto依存 | https://docs.rs/crate/ring/latest |
| C003 | graviola | 0.3.4 | Crypto Provider | R&D | Rustls provider candidate | https://docs.rs/graviola |
| C004 | rustls-graviola | 0.3.4 | Crypto Provider | R&D | rustls integration | https://docs.rs/rustls-graviola |
| C005 | aes-gcm | 0.10.3 | AEAD | Core | AES-GCM | https://docs.rs/crate/aes-gcm/latest |
| C006 | chacha20poly1305 | 0.10.1 | AEAD | Adopt | ChaCha20-Poly1305 | https://docs.rs/crate/chacha20poly1305/latest |
| C007 | x25519-dalek | 2.0.1 | KEX | Core | X25519鍵交換 | https://docs.rs/crate/x25519-dalek/latest |
| C008 | ed25519-dalek | 2.2.0 | Signature | Adopt | Ed25519署名 | https://docs.rs/crate/ed25519-dalek/latest |
| C009 | argon2 | 0.5.3 | KDF | Core | password hashing/KDF | https://docs.rs/crate/argon2/latest |
| C010 | hpke | 0.13.0 | HPKE | R&D | Pure Rust HPKE | https://docs.rs/crate/hpke/latest |
| C011 | hpke-rs | 0.6.1 | HPKE | R&D | flexible backend HPKE | https://docs.rs/hpke-rs |
| C012 | snow | 0.10.0 | Noise | Adopt/R&D | Noise protocol | https://docs.rs/crate/snow/latest |
| C013 | jsonwebtoken | 10.3.0 | Auth | Core | JWT | https://docs.rs/crate/jsonwebtoken/latest |
| D001 | serde | 1.0.228 | Serialization | Core | 型付きserde | https://docs.rs/crate/serde/latest |
| D002 | serde_json | 1.0.149 | JSON | Core | JSON baseline | https://docs.rs/crate/serde_json/latest |
| D003 | simd-json | 0.17.0 | JSON/SIMD | Adopt | JSON hot path | https://docs.rs/crate/simd-json/latest |
| D004 | rkyv | 0.8.16 | Zero-copy Serde | Adopt | frozen snapshot | https://docs.rs/crate/rkyv/latest |
| D005 | zerocopy | 0.8.48 | Binary View | Adopt | fixed binary header | https://docs.rs/crate/zerocopy/latest |
| D006 | surrealdb | 3.0.5 | DB | Core | document-graph DB | https://docs.rs/crate/surrealdb/latest |
| D007 | sqlx | 0.8.6 | SQL | Core | async SQL | https://docs.rs/crate/sqlx/latest |
| D008 | qdrant-client | 1.17.0 | Vector DB | Adopt | Qdrant client | https://docs.rs/crate/qdrant-client/latest |
| D009 | lancedb | 0.27.2 | Vector DB | Adopt/R&D | local/serverless vector DB | https://docs.rs/crate/lancedb/latest |
| D010 | tantivy | 0.26.1 | Full-text | Adopt | 検索エンジン | https://docs.rs/crate/tantivy/latest |
| D011 | distx | 0.2.5 | Vector/Similarity | R&D | Qdrant compatible vector DB | https://crates.io/crates/distx/0.2.5 |
| D012 | distx-similarity | 0.2.5 | Similarity | R&D | explainable structured similarity | https://docs.rs/distx-similarity |
| M001 | tikv-jemallocator | 0.6.1 | Allocator | Adopt/Measure | Linux server allocator | https://docs.rs/crate/tikv-jemallocator/latest |
| M002 | bumpalo | 3.20.2 | Arena | Adopt | 一括破棄arena | https://docs.rs/crate/bumpalo/latest |
| M003 | ahash | 0.8.12 | Hashing | Adopt | internal fast hash | https://docs.rs/crate/ahash/latest |
| M004 | dashmap | 6.1.0 | Concurrent Map | Adopt | sharded map | https://docs.rs/crate/dashmap/latest |
| M005 | parking_lot | 0.12.5 | Lock | Adopt | lightweight lock | https://docs.rs/crate/parking_lot/latest |
| M006 | arc-swap | 1.9.1 | Lock-free Config | Adopt | hot reload config | https://docs.rs/crate/arc-swap/latest |
| M007 | moka | 0.12.15 | Cache | Adopt | async cache | https://docs.rs/crate/moka/latest |
| M008 | once_cell | 1.21.4 | Lazy Init | Adopt | static selectors/config | https://docs.rs/crate/once_cell/latest |
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

\* `ringbuf` はdocs.rs/latestが0.4.8を返す一方、crates.ioでは0.4.9が確認されるため、採用前にcrate release / docs build状態を再確認する。

---

## 5. Core Library Decision Records

### A001: tokio

- **役割**: RustSkills標準非同期ランタイム。
- **採用理由**: ecosystemの厚さ、`reqwest`/`sqlx`/`axum`/`tower`との相性、`select!`, `Semaphore`, `mpsc`, `JoinSet`, `time`, `spawn_blocking` による制御性。
- **使用プロジェクト**: 全領域。
- **実装ルール**:
  - 無制限spawn禁止。
  - I/OタスクとCPUタスクを分離。
  - CPU-heavy処理は `rayon` / `spawn_blocking` / 専用workerへ。
  - shutdownは `CancellationToken` で構造化。
- **更新チェック**: MSRV、runtime behavior、feature、io_uring関連、scheduler変更。

### A002: reqwest

- **役割**: 標準HTTPクライアント。
- **採用理由**: 接続プール、TLS、redirect、header、JSON/form、proxy、streamingを高レベルに扱える。
- **使用プロジェクト**: 高負荷送信の標準レーン、LLM API、外部CRM/API。
- **実装ルール**:
  - `Client` は再利用。
  - requestごとのbuilder乱立を避ける。
  - form bodyは可能なら事前encode。
  - hot pathは `hyper + bytes` へ切り出し可能にする。
- **更新チェック**: `rustls`/TLS feature、HTTP/2 behavior、WASM compatibility、cookie/proxy feature。

### A003: tower / A004: tower-http

- **役割**: 横断制御面。
- **採用理由**: timeout、retry、rate limit、concurrency limit、trace、request id、compressionをService/Layerで合成可能。
- **使用プロジェクト**: API gateway、送信worker、LLM gateway。
- **実装ルール**:
  - layer順序を設計レビュー対象にする。
  - retryは失敗分類器とセットにする。
  - rate limitはhost/account/campaign/globalの三層。
  - request body size limitを標準装備。

### A007: bytes / A008: hyper

- **役割**: 限界突破HTTP・ゼロコピーI/O。
- **採用理由**: `Bytes`で基底バッファ共有、`hyper`で低抽象HTTP制御。
- **使用プロジェクト**: 高負荷送信のhot path、LLM streaming gateway、E2EE payload proxy。
- **実装ルール**:
  - bodyを一括collectしない。
  - `BytesMut -> freeze` で共有化。
  - 解析、送信、監査で同じ基底バッファを使える設計へ寄せる。

### A009: tokio-uring / A010: monoio

- **役割**: Linux専用R&Dレーン。
- **採用理由**: `io_uring`、single-thread runtime、thread-per-core、syscall削減の可能性。
- **使用プロジェクト**: 高密度送信worker、spool/log/cache I/O、将来のproxy。
- **制約**:
  - Linux専用。
  - portability低下。
  - ライブラリ成熟度を継続監視。
- **採用条件**:
  - 標準Tokioレーンより、同一SLOでCPU/RSS/p99に明確な勝ちがある。
  - 本番切替時に標準レーンへfallbackできる。

### W001: leptos / W002: leptos_router

- **役割**: Rust full-stack UI / routing。
- **採用理由**: fine-grained reactivity、SSR、server functions、Rust型システムとの整合。
- **使用プロジェクト**: RustSkills Web、Web Builder、CRM dashboard、Agent console。
- **実装ルール**:
  - client bundleを薄くする。
  - dynamic islandだけをhydrate。
  - route dataを親/子で分割。
  - signal粒度を小さく保つ。

### W003: wasm-bindgen / W004: web-sys / W005: gloo-net

- **役割**: WASM境界、ブラウザAPI、WASM HTTP。
- **採用理由**: RustからJS/Web APIへの型安全なアクセス。
- **実装ルール**:
  - JS/WASM境界を細かく跨がない。
  - `web-sys` featureは最小化。
  - TypedArray / buffer bulk transferを基本にする。

### W007: talc

- **役割**: WASM/no_std allocator候補。
- **採用理由**: WASMバイナリサイズとalloc性能改善の余地。
- **採用条件**: Leptos/WASM bundle size、alloc count、runtime memoryで標準より勝つこと。
- **注意**: 全面導入せず、Web Builderやclient-heavy moduleでA/B testing。

### T001: ratatui / T002: crossterm

- **役割**: TUI表示・端末イベント。
- **採用理由**: SSH越し運用、軽量、terminal-native dashboard。
- **実装ルール**:
  - token到着ごとに描画しない。
  - render tickで間引く。
  - pre-format bufferを使う。
  - I/O, LLM, key input, renderを別タスクに分ける。

### T003: cpal / T004: ringbuf

- **役割**: 音声入力とロックフリーSPSC経路。
- **採用理由**: CPALは低レベル音声I/O、ringbufはcallback内ロック回避。
- **実装ルール**:
  - callback内alloc禁止。
  - callback内I/O禁止。
  - fixed frame sizeで下流へ渡す。
  - underflow/overflowをメトリクス化。

### T005: symphonia / T006: audio_thread_priority

- **役割**: pure Rust audio decode、リアルタイム優先度。
- **採用理由**: FFmpeg依存を避けたい音声処理、低レイテンシ優先。
- **採用条件**: format要件、OS権限、CPU負荷、音切れ率で評価。

### C001: rustls

- **役割**: 公開TLS標準。
- **採用理由**: TLS 1.2/1.3、modern TLS、OpenSSL回避、CryptoProvider差し替え。
- **実装ルール**:
  - 公開API/mTLSはrustls標準。
  - 秘匿payload暗号は別レイヤで設計。
  - feature / provider / C依存を監査。

### C002: ring

- **役割**: 既存依存やTLS周辺の高性能暗号。
- **採用判断**: 実績は強いが、C/assembly由来を含むため「C依存排除」領域ではconditional。
- **方針**:
  - 公開エッジでは許容する場合あり。
  - 秘匿バイナリでは代替候補を優先。

### C003/C004: graviola / rustls-graviola

- **役割**: rustls CryptoProvider候補。
- **採用理由**: Rust compilerのみでbuild可能、rustls向け、形式検証済みs2n-bignum routine利用。
- **注意**:
  - docs上も新しいprojectと明記される。
  - CPU architecture/features制約あり。
  - production採用はcanaryと互換性テスト必須。

### C005/C006: aes-gcm / chacha20poly1305

- **役割**: AEAD暗号。
- **方針**:
  - AES-NIが確実ならAES-GCM。
  - 汎用CPU/モバイル/匿名ノードではChaCha20-Poly1305を優先候補。
- **実装ルール**:
  - nonce再利用禁止。
  - associated dataにversion/sender/recipient/message_idを含める。
  - key separationを型で表現する。

### C007/C008: x25519-dalek / ed25519-dalek

- **役割**: 鍵交換と署名。
- **方針**:
  - ephemeral X25519でsession key合意。
  - Ed25519でnode/agent/config/decision logに署名。
  - identity keyとsession keyを混同しない。

### C010/C011/C012: hpke / hpke-rs / snow

- **役割**: application-level E2EE / Noise mesh。
- **方針**:
  - HPKEは封筒暗号・受信者公開鍵暗号化。
  - Snow/Noiseは秘匿mesh handshake。
  - 採用時はaudit statusとpattern固定を必須にする。

### D003: simd-json

- **役割**: JSON hot path高速化。
- **採用理由**: SIMD parser、Borrowed/Tape API、Serde連携。
- **採用条件**:
  - `serde_json` がボトルネックであることをprofileで確認。
  - mutable buffer所有権設計ができていること。

### D004: rkyv

- **役割**: zero-copy snapshot。
- **採用理由**: エージェント状態、ルール、静的辞書、CRM特徴量スナップショットを高速ロード。
- **実装ルール**:
  - schema versionを必ず持つ。
  - mutable domain modelを直接archiveしない。
  - `bytecheck`等の検証を標準にし、uncheckedは測定済みhot path限定。

### D006: surrealdb / D007: sqlx

- **役割**: graph/document state と hard SQL state。
- **方針**:
  - 課金/同意/監査/権限はSQLx + Postgres。
  - エージェント関係/組織/会話/タスクはSurrealDB。
  - 一方を万能DBにしない。

### D008/D009/D010/D011/D012: qdrant-client / lancedb / tantivy / distx / distx-similarity

- **役割**: vector/full-text/structured similarity。
- **方針**:
  - Qdrant: production vector searchの第一候補。
  - LanceDB: local/serverless vector data、R&D/edge候補。
  - Tantivy: full-text search。
  - DistX: explainable structured similarityのR&D候補。`distx-core 0.2.7` yanked情報があるため採用前に強い検証が必要。

### M001-M008: memory/concurrency utilities

- **tikv-jemallocator**: Linux serverでallocation pressureが高いworkerに限定導入。
- **bumpalo**: page/lead/batch単位のarena。
- **ahash**: 外部攻撃者がkeyを制御しない内部hot path用。
- **dashmap**: concurrent map。guard保持中await禁止。
- **parking_lot**: short critical section向けlock。
- **arc-swap**: immutable config hot reload。
- **moka**: TTL/cache/async cache。
- **once_cell**: static selector/config。

### E001-E006: observability / errors / CLI

- **tracing**: 全非同期処理の因果関係。
- **tracing-subscriber**: JSON log、filter、layer。
- **anyhow**: binary/app layer。
- **thiserror**: library/API boundary。
- **clap**: CLI standard。
- **indicatif**: long job progress。ただし更新頻度を間引く。

---

## 6. RustSkills Workspace Blueprint

```text
rustskills/
  Cargo.toml
  crates/
    rs-core/                 # shared types, IDs, config, errors
    rs-observability/        # tracing, metrics, log conventions
    rs-http-control/         # tower layers, rate limit, retry policies
    rs-crawler/              # crawler/form extraction/control plane
    rs-crawler-hotpath/      # hyper/bytes/tokio-uring experiments
    rs-web/                  # leptos app
    rs-web-components/       # UI components, tailwind_fuse
    rs-tui-agent/            # ratatui/cpal runtime
    rs-audio-pipeline/       # ringbuf, VAD/codec boundary
    rs-crypto/               # key types, AEAD, HPKE/Noise wrappers
    rs-e2ee-node/            # quinn/snow/rustls integration
    rs-data/                 # sqlx/surrealdb repositories
    rs-vector/               # qdrant/lancedb/distx/tantivy adapters
    rs-snapshot/             # rkyv snapshots
    rs-bench/                # criterion/iai-callgrind/pprof harnesses
  skills/
    # 後続生成: Codex/Claude準拠のskill files
  docs/
    master.md
    sources.md
    update_prompt.md
    README.md
```

### Feature設計のルール

```toml
[features]
default = ["std", "tokio-runtime", "rustls-provider"]
std = []
tokio-runtime = ["tokio", "tokio-util"]
extreme-io = ["hyper", "bytes", "simd-json"]
linux-uring = ["tokio-uring"]
monoio-runtime = ["monoio"]
wasm = ["wasm-bindgen", "web-sys", "gloo-net"]
wasm-allocator = ["talc"]
audio = ["cpal", "ringbuf", "symphonia"]
e2ee-noise = ["snow", "ed25519-dalek", "x25519-dalek", "chacha20poly1305"]
e2ee-hpke = ["hpke", "hpke-rs"]
crypto-graviola = ["graviola", "rustls-graviola"]
vector-qdrant = ["qdrant-client"]
vector-lance = ["lancedb"]
vector-distx = ["distx", "distx-similarity"]
```

**重要**: featureは「全部入り」を避ける。binary単位で必要なfeatureだけを有効化し、WASM/E2EE/Linux専用ワーカーなどの責務を分ける。

---

## 7. Project-specific Implementation Playbooks

### 7.1 高負荷送信基盤 Playbook

**標準構成**:

```text
CSV/Parquet/DB input
  -> Polars lazy preprocess
  -> bounded async queue
  -> per-host/per-account governor limiter
  -> tower Service stack
  -> reqwest Client pool
  -> response classifier
  -> sqlx audit / surrealdb state
  -> retry/dead-letter queue
```

**限界突破構成**:

```text
prepared payloads
  -> BytesMut template expansion
  -> hyper sender shard
  -> per-core worker
  -> simd-json response parse if needed
  -> mmap/spool via tokio-uring if measured beneficial
```

**禁止事項**:

- 許可のない対象への大量送信。
- レート制限回避や防御回避を目的にした設計。
- unbounded queue。
- requestごとのClient作成。
- ログにPIIやsecretを出す。

**KPI**:

- p50/p95/p99 latency
- success/failure/retry/skipped counts
- per-host concurrency
- queue depth
- RSS and allocation count
- timeout rate
- external backoff reason

### 7.2 Leptos Web Builder Playbook

**構成**:

```text
SSR shell
  -> route-level data loading
  -> small reactive islands
  -> server functions for heavy logic
  -> gloo-net only for client API
  -> wasm-bindgen/web-sys minimal feature
```

**KPI**:

- WASM compressed size
- hydration time
- first interaction time
- route transition latency
- signal invalidation count
- JS/WASM boundary calls

**最適化**:

- server functionで重い処理をサーバーへ。
- Tailwind classは`tailwind_fuse`で安全に合成。
- 小さな配列は`smallvec`。
- allocatorは`talc`をA/B test。

### 7.3 TUI AI Agent Playbook

**構成**:

```text
cpal callback
  -> ringbuf SPSC
  -> audio worker
  -> ASR/LLM stream
  -> event reducer
  -> ratatui render tick
```

**KPI**:

- audio callback duration
- ring buffer occupancy
- underrun/overrun
- ASR chunk latency
- LLM first-token latency
- render FPS / dropped frames

**最適化**:

- callback内ではサンプルcopyのみ。
- `audio_thread_priority`はOSごとの権限・安定性を検証。
- `symphonia`は圧縮音声を扱う場合のみ。
- `quinn`は多ストリーム通信が必要な時に採用。

### 7.4 E2EE Infrastructure Playbook

**構成**:

```text
public edge TLS: rustls
application payload: HPKE or Noise
identity: ed25519-dalek
session: x25519 ephemeral
AEAD: chacha20poly1305 or aes-gcm
password/key wrapping: argon2
```

**KPI**:

- handshake latency
- message encrypt/decrypt throughput
- key rotation success
- nonce monotonicity validation
- fuzz/property test coverage
- dependency C/FFI footprint

**セキュリティルール**:

- nonce再利用禁止。
- associated dataを設計する。
- identity key / session key / storage keyを型で分ける。
- secretはDebug禁止。
- key materialはzeroize候補を検討。
- `snow` / `hpke`系はaudit statusを更新時に必ず確認。

### 7.5 CCTeam / Social Psychometrics CRM Playbook

**構成**:

```text
sqlx/Postgres: account, consent, auth, audit, billing
SurrealDB: agent, role, task, memory graph, decision state
Polars: feature engineering
Qdrant/LanceDB: embeddings and semantic retrieval
Tantivy: text search over transcripts/logs
DistX: explainable structured similarity R&D
rkyv: frozen rules/snapshots/context bundles
```

**KPI**:

- vector search latency
- full-text search latency
- graph query depth/cost
- batch feature time
- snapshot load time
- PII deletion completeness

**Big Five / Psychometrics注意**:

- 推定値は確率・仮説として扱う。
- 説明可能性と人間レビューを設ける。
- センシティブ属性推定や差別的意思決定を避ける。
- 同意、保存期間、削除要求、監査を明示する。

---

## 8. Update Governance

### 8.1 更新頻度

| 対象 | 頻度 | 実行内容 |
|---|---:|---|
| Security advisories | 毎週 / 緊急時即時 | `cargo audit`, RustSec, GitHub advisory, upstream security notes |
| Core crates | 月1 | docs.rs/crates.io/GitHub releases/MSRV/featuresを確認 |
| R&D crates | 月1〜隔週 | maturity, yanked, audit, issue, benchmark状況を確認 |
| WASM stack | 月1 | bundle size, Leptos/wasm-bindgen/web-sys互換性 |
| Crypto stack | 月1 + release時 | audit status, dependency tree, provider, CPU constraints |
| Perf-sensitive crates | update前後 | criterion/iai/pprof、RSS、p99比較 |

### 8.2 更新PRの必須チェックリスト

- [ ] `cargo update -p <crate>` のdiff確認
- [ ] `cargo tree -e features` の差分確認
- [ ] `cargo audit`
- [ ] `cargo deny check`
- [ ] `cargo outdated`
- [ ] `cargo semver-checks`、public APIを持つcrateの場合
- [ ] `cargo nextest run`
- [ ] `cargo clippy --all-targets --all-features`
- [ ] `cargo test --doc`
- [ ] `criterion` benchmark比較
- [ ] hot pathは `pprof` / allocation profile
- [ ] WASMは bundle size diff
- [ ] cryptoはtest vectors / Wycheproof等の検討
- [ ] MasterのCrate Registerを更新
- [ ] Sources indexへsource URL / changelog / release noteを追加

### 8.3 更新判定のルール

**即時更新**:

- critical/high advisory。
- remote code execution / memory unsafety / cryptographic vulnerability。
- 上流がyankした重大バグ。

**通常更新**:

- patch/minorでAPI互換。
- MSRV変更なし。
- benchmark退行なし。

**保留**:

- MSRV上昇。
- default feature変更。
- 新しいC/FFI依存。
- p99/RSS/wasm size退行。
- crypto audit/maturity不明。
- yanked/retracted/failed docs build。

**拒否**:

- security regression。
- license incompatibility。
- unmaintainedで重大issue未解決。
- 既存SLOを壊す。

---

## 9. AI Deep Research Update Protocol

> 後続の `update_prompt.md` はこの章から切り出す。

### 9.1 AIモデルに渡すべき入力

- このMaster全文。
- 現在の `Cargo.toml` / `Cargo.lock` / `cargo metadata`。
- `cargo tree -e features`。
- `cargo audit` / `cargo deny` / `cargo outdated` 結果。
- benchmark baseline。
- ユーザー/REV-Cのプロジェクト文脈。
- 変更したい対象crateと理由。

### 9.2 AI Deep Researchへの要求

- 日本語と英語の両方で調査する。
- 公式ドキュメント、docs.rs、crates.io、GitHub releases、RustSec、RFC/標準文書を優先する。
- 個人ブログやSNSは補助に留める。
- バージョン番号、release date、MSRV、feature変更、依存差分、yanked有無、security advisory、licenseを必ず確認する。
- pre/alpha/beta/rcは安定版として扱わない。
- R&D候補は成熟度・監査状況・fallback策を書く。
- 採用判断は `Adopt / Hold / Reject / R&D` の4値で返す。
- Masterの該当箇所を更新する差分案を出す。

### 9.3 AIが出力すべき更新レポート形式

```markdown
# RustSkills Update Report: <date>

## Executive Decision
- Target crates:
- Decision: Adopt / Hold / Reject / R&D
- Reason:

## Version Diff
| crate | current | latest stable | release date | source |

## Risk Diff
- MSRV:
- Feature changes:
- Dependency changes:
- C/FFI changes:
- Security advisories:
- License:

## Project Impact
- Crawler:
- Leptos/WASM:
- TUI/Audio:
- E2EE:
- Agent/Data:

## Required Tests
- Compile:
- Unit/integration:
- Benchmark:
- WASM size:
- Crypto/vector tests:

## Master Patch
<diff or section replacement>
```

---

## 10. Source Policy

> 後続の `sources.md` はこの章とCrate Registerから切り出す。

### 優先ソース

1. docs.rs latest crate page
2. crates.io crate page / versions
3. GitHub repository releases / changelog
4. Official project website
5. RustSec advisory DB
6. RFC / IETF / W3C / WHATWG / official standards
7. Upstream issue/PR for breaking changes

### ソース登録形式

```yaml
source_id: SRC-<crate>
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

### 注意すべきcrate

- `ringbuf`: docs.rs/latestとcrates.io latestに差異がある可能性。
- `distx` / `distx-core`: yanked情報・version整合性を都度確認。
- `graviola` / `rustls-graviola`: 新しいproject。CPU featuresとproduction readinessを確認。
- `hpke` / `hpke-rs` / `snow`: audit status確認必須。
- `tokio-uring` / `monoio`: Linux限定・成熟度・runtime interop確認必須。
- `talc`: WASM/no_std向け。Leptos実アプリでA/B benchmark必須。

---

## 11. Benchmark & SLO Master

### 高負荷送信

| Metric | Target | Notes |
|---|---:|---|
| queue growth | bounded | unbounded禁止 |
| p95 request latency | project-specific | host別に見る |
| p99 tail latency | project-specific | retry嵐検出 |
| timeout rate | low/stable | target別SLO |
| RSS | stable | jemalloc導入前後比較 |
| allocations/op | decreasing | `Bytes`, pre-encodeで削る |

### WASM

| Metric | Target | Notes |
|---|---:|---|
| wasm compressed size | small | route/component別に測定 |
| hydration time | low | island化 |
| JS/WASM calls | minimized | bulk transfer |
| route transition | responsive | parent resource reuse |

### Audio/TUI

| Metric | Target | Notes |
|---|---:|---|
| callback time | sub-frame | alloc/lock禁止 |
| ring buffer occupancy | stable | overflow/underflow監視 |
| first token latency | low | LLM/ASR/network分解 |
| render FPS | stable | tick間引き |

### E2EE

| Metric | Target | Notes |
|---|---:|---|
| handshake time | low | pattern別に測定 |
| encrypt/decrypt throughput | high | AEAD別比較 |
| nonce validation | zero violation | property test |
| dependency C/FFI footprint | explicit | binary別に監査 |

### AI/Data

| Metric | Target | Notes |
|---|---:|---|
| vector search p95 | low | Qdrant/LanceDB/DistX比較 |
| full-text search p95 | low | Tantivy index config |
| snapshot load | near O(1) | rkyv/mmap候補 |
| feature batch time | low | Polars lazy plan |

---

## 12. Skills化マップ

後続で作る `skills/` は次のようにMasterから分解する。

```text
skills/
  rustskills-async-io.md          # tokio, reqwest, tower, hyper, bytes, governor
  rustskills-crawler.md           # scraper, serde_urlencoded, rate limit, audit
  rustskills-extreme-io.md        # tokio-uring, monoio, simd-json, jemalloc
  rustskills-leptos-wasm.md       # leptos, wasm-bindgen, web-sys, talc
  rustskills-tui-audio-agent.md   # ratatui, crossterm, cpal, ringbuf, symphonia
  rustskills-e2ee-crypto.md       # rustls, graviola, x25519, ed25519, hpke, snow
  rustskills-ai-data.md           # surrealdb, sqlx, polars, qdrant, lancedb, tantivy, rkyv
  rustskills-observability.md     # tracing, tracing-subscriber, pprof, criterion
  rustskills-update-governance.md # cargo-audit, cargo-deny, cargo-outdated, update prompt
```

各Skillはこの形式にする。

```markdown
# Skill: <name>

## When to use
## Core principles
## Approved crates
## Forbidden patterns
## Canonical architecture
## Implementation recipes
## Benchmarks/SLOs
## Update checklist
## Sources
```

---

## 13. README抽出方針

後続の `README.md` はこのMasterから、次の内容だけを短く抽出する。

- RustSkillsとは何か。
- 対象プロジェクト。
- 5つのレーン。
- 最小推奨スタック。
- 更新体制。
- artifact構成。
- 安全・法令遵守の前提。

---

## 14. Immediate Adoption Priority

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

- `hyper` hot path
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

## 15. Master Maintenance Rules

1. Masterは常に最新の意思決定を持つ。
2. 後続ファイルはMasterから派生する。
3. crate追加時は必ずCrate Registerへ入れる。
4. R&DからAdoptへ昇格するには、benchmark、security、fallback、operational readinessが必要。
5. Crypto系はaudit statusと標準文書を必ず確認する。
6. High-load系は安全・同意・レート制限・監査を必ず設計に含める。
7. AI/Data系はPII、同意、削除要求、説明可能性を必ず含める。
8. すべての更新はsource URL、last checked、decision reasonを残す。

---

## 16. Open Questions

- `distx`を本番採用するか、Qdrant/LanceDB/Tantivyの補助R&Dに留めるか。
- `graviola`を秘匿バイナリの標準Providerに昇格するか。
- `tokio-uring` / `monoio` のどちらをextreme I/O laneの第一候補にするか。
- Leptos Web Builderで`talc`をglobal allocatorにするか、module限定にするか。
- TUI AI AgentでQUICを標準にするか、SSE/WebSocketを標準にしてQUICをR&Dにするか。
- SurrealDB v3系の運用実績をどこまで許容し、Postgres/sqlxとの境界をどう固定するか。

---

## 17. Current Decision Summary

RustSkillsの核は、**標準レーンを強くしつつ、ホットパスだけ別レーンで焼き切る**ことにある。`tokio / reqwest / tower / leptos / ratatui / cpal / rustls / sqlx / surrealdb / tracing` は土台として維持する。一方で、世界トップ1%の性能・保守性・秘匿性を狙うには、`bytes / hyper / governor / ringbuf / rkyv / simd-json / tikv-jemallocator / chacha20poly1305 / ed25519-dalek / qdrant-client / tantivy / lancedb` を段階導入し、`graviola / tokio-uring / monoio / distx / hpke-rs` はR&Dとして評価する。

このMasterを起点に、次は `skills/`、`update_prompt.md`、`sources.md`、`README.md` を生成する。
