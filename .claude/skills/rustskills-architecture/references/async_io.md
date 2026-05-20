## Skill: rustskills-async-io

### When to use

高負荷HTTP、LLM API、DBアクセス、API Gateway、ストリーミング、ジョブワーカー、TUIイベント処理など、RustSkillsの非同期I/O全般で使う。

### Core principles

- `tokio` を標準ランタイムにする。
- `reqwest` は業務HTTP、`hyper + bytes` はhot path専用とする。
- `tower` / `tower-http` でtimeout、retry、rate limit、trace、body limit、request idをレイヤ化する。
- concurrency controlは `Semaphore` / bounded queue / `governor` を使い、処理能力以上のリクエストを受けない。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A001 | tokio | 1.52.1 | Async I/O | Core | 非同期ランタイム | https://docs.rs/crate/tokio/latest |
| A002 | reqwest | 0.13.3 | Async HTTP | Core | 高レベルHTTPクライアント | https://docs.rs/crate/reqwest/latest |
| A003 | tower | 0.5.3 | Middleware | Core | Service/Layer制御面 | https://docs.rs/crate/tower/latest |
| A004 | tower-http | 0.6.8 | Middleware | Adopt | HTTP middleware | https://docs.rs/crate/tower-http/latest |
| A005 | axum | 0.8.9 | API Server | Adopt | API/SSR gateway | https://docs.rs/crate/axum/latest |
| A006 | governor | 0.10.4 | Rate Limit | Adopt | レート制御 | https://docs.rs/crate/governor/latest |
| A007 | bytes | 1.11.1 | Zero-copy Buffer | Adopt | I/O共通バッファ | https://docs.rs/crate/bytes/latest |
| A008 | hyper | 1.9.0 | Low-level HTTP | Adopt | 高性能HTTP hot path | https://docs.rs/crate/hyper/latest |
| A011 | rayon | 1.12.0 | CPU Parallel | Core | CPU並列処理 | https://docs.rs/crate/rayon/latest |
| T007 | tokio-util | 0.7.18 | Async Utility | Core | cancellation/codec | https://docs.rs/crate/tokio-util/latest |
| E001 | tracing | 0.1.44 | Observability | Core | span/event | https://docs.rs/crate/tracing/latest |
| E002 | tracing-subscriber | 0.3.23 | Observability | Adopt | log/JSON/filter | https://docs.rs/crate/tracing-subscriber/latest |

### Forbidden patterns

- `for item in items { tokio::spawn(...) }` の無制限spawn。
- requestごとの `reqwest::Client::new()`。
- unbounded queueによるメモリ爆発。
- retryとtimeoutを分類せず全部再試行する設計。
- bodyを無制限にcollectする実装。

### Canonical architecture

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

### Implementation recipes

1. `Client` は出口ポリシーごとに長寿命で共有する。
2. `tower::ServiceBuilder` のレイヤ順序は `trace -> request_id -> body_limit -> timeout -> concurrency -> rate_limit -> retry` のように明示的に固定する。
3. `Bytes` / `BytesMut` をI/O境界の標準バッファにし、`String` 化はUI・ログ直前まで遅延する。
4. 失敗は `timeout / DNS / TLS / 4xx / 5xx / rate limited / policy blocked / parse error` へ分類する。
5. CPU-heavy処理は `rayon`、`spawn_blocking`、専用workerへ逃がす。

### Benchmarks / SLOs

- queue depthがboundedで安定している。
- per-host p95/p99 latencyが測れている。
- timeout/retry rateがhost/account/campaign別に見える。
- RSSとallocations/opがリリースごとに比較可能。

### Update checklist

- `tokio`, `reqwest`, `hyper`, `tower` のMSRVとfeature変更を確認。
- TLS provider、HTTP/2、proxy、cookie、compression featureの差分を見る。
- `cargo tree -e features` で不要featureが増えていないか確認。
- hot pathはcriterion/pprofで旧版比較する。

### Sources

- `rustskills_sources.md` の `A001-A008`, `A011`, `T007`, `E001-E002`。

---
