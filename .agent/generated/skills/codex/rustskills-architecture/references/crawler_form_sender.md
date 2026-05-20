## Skill: rustskills-crawler-form-sender

### When to use

許可済み対象のHTML取得、フォーム抽出、hidden token/CSRF token解析、URLエンコード済みPOST、監査ログ、再試行キューを作るときに使う。

### Core principles

- 送信先を壊さないことを最優先する。
- `scraper` でHTML構造を扱い、正規表現だけでフォーム解析しない。
- `serde_urlencoded` でform bodyを生成し、可能なら事前エンコードする。
- 入力リストはPolarsで前処理し、無効・重複・禁止対象を早期除外する。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A001 | tokio | 1.52.1 | Async I/O | Core | 非同期ランタイム | https://docs.rs/crate/tokio/latest |
| A002 | reqwest | 0.13.3 | Async HTTP | Core | 高レベルHTTPクライアント | https://docs.rs/crate/reqwest/latest |
| A003 | tower | 0.5.3 | Middleware | Core | Service/Layer制御面 | https://docs.rs/crate/tower/latest |
| A006 | governor | 0.10.4 | Rate Limit | Adopt | レート制御 | https://docs.rs/crate/governor/latest |
| A007 | bytes | 1.11.1 | Zero-copy Buffer | Adopt | I/O共通バッファ | https://docs.rs/crate/bytes/latest |
| A012 | scraper | 0.26.0 | HTML Parse | Core | フォーム/HTML抽出 | https://docs.rs/crate/scraper/latest |
| A013 | serde_urlencoded | 0.7.1 | Encoding | Adopt | form body生成 | https://docs.rs/crate/serde_urlencoded/latest |
| A014 | polars | 0.53.0 | DataFrame | Core | 列指向バッチ分析 | https://docs.rs/crate/polars/latest |
| M004 | dashmap | 6.1.0 | Concurrent Map | Adopt | sharded map | https://docs.rs/crate/dashmap/latest |
| M006 | arc-swap | 1.9.1 | Lock-free Config | Adopt | hot reload config | https://docs.rs/crate/arc-swap/latest |
| M007 | moka | 0.12.15 | Cache | Adopt | async cache | https://docs.rs/crate/moka/latest |
| E001 | tracing | 0.1.44 | Observability | Core | span/event | https://docs.rs/crate/tracing/latest |
| E005 | clap | 4.6.1 | CLI | Core | CLI parser | https://docs.rs/crate/clap/latest |
| E006 | indicatif | 0.18.4 | CLI | Core | progress UI | https://docs.rs/crate/indicatif/latest |

### Forbidden patterns

- 許可・同意・契約のない対象への大量送信。
- robots、利用規約、相手先負荷、停止要求を無視する設計。
- CSRFや認証を回避する目的の処理。
- 成功/失敗/停止理由を監査できない処理。

### Canonical architecture

```text
CSV / Parquet / DB input
  -> Polars lazy cleaning
  -> allowlist / denylist / dedupe
  -> bounded async queue
  -> host/account/campaign/global limiter
  -> form discovery and validation
  -> encoded POST
  -> response classification
  -> audit log + retry/dead-letter
```

### Implementation recipes

1. `Selector` はループ内で作らず `once_cell` / `LazyLock` で静的化する。
2. HTML全文を長期保持せず、必要フィールドだけ短命DTOへ落とす。
3. host別limiterは `DashMap<Host, Arc<Limiter>>` で管理し、TTLで掃除する。
4. payload templateを `BytesMut` で組み、差分だけ差し替えて `freeze()` する。
5. 監査ログにはPII/secretを出さず、hash化ID、policy decision、latency、status、retry reasonを残す。

### Benchmarks / SLOs

- target count / processed / success / failure / skipped / retryを分離。
- per-host concurrency、limiter wait time、queue depthを計測。
- parse time、request time、DB write timeを別spanで測る。

### Update checklist

- `scraper` / `html5ever` 系依存更新のparse挙動差分を確認。
- `serde_urlencoded` のencoding互換性を確認。
- `reqwest` / `rustls` / proxy featureの差分を確認。

### Sources

- `rustskills_sources.md` の `A012-A014`, `A001-A007`, `M004`, `M006-M007`。

---
