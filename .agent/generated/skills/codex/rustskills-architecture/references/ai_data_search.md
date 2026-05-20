## Skill: rustskills-ai-data-search

### When to use

CCTeam、自律型組織AI、Social Psychometrics CRM、Big Five / 行動経済学特徴量、ベクトル検索、全文検索、グラフ状態、SQL監査、ゼロコピーsnapshotを扱うときに使う。

### Core principles

- SQL、graph/document、vector、full-text、snapshotを一枚岩DBへ押し込まない。
- `sqlx/Postgres` はauth/consent/audit/billingなど強整合領域へ使う。
- `surrealdb` はagent/role/task/memory graph/decision stateへ使う。
- `qdrant-client` / `lancedb` はsemantic retrieval、`tantivy` は全文検索、`rkyv` は凍結snapshotへ使う。
- 心理推定は確率・仮説として扱い、人間レビュー、同意、削除要求、説明可能性を設計に含める。

### Approved crates

| ID | Crate / Tool | Version | Lane | Status | Primary Use | Source |
|---|---:|---:|---|---|---|---|
| A014 | polars | 0.53.0 | DataFrame | Core | 列指向バッチ分析 | https://docs.rs/crate/polars/latest |
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
| M002 | bumpalo | 3.20.2 | Arena | Adopt | 一括破棄arena | https://docs.rs/crate/bumpalo/latest |
| M003 | ahash | 0.8.12 | Hashing | Adopt | internal fast hash | https://docs.rs/crate/ahash/latest |
| M004 | dashmap | 6.1.0 | Concurrent Map | Adopt | sharded map | https://docs.rs/crate/dashmap/latest |
| M006 | arc-swap | 1.9.1 | Lock-free Config | Adopt | hot reload config | https://docs.rs/crate/arc-swap/latest |
| M007 | moka | 0.12.15 | Cache | Adopt | async cache | https://docs.rs/crate/moka/latest |
| E001 | tracing | 0.1.44 | Observability | Core | span/event | https://docs.rs/crate/tracing/latest |
| E002 | tracing-subscriber | 0.3.23 | Observability | Adopt | log/JSON/filter | https://docs.rs/crate/tracing-subscriber/latest |

### Forbidden patterns

- PIIをベクトルDB payloadへ無制限に入れる。
- 心理推定値を確定属性として扱う。
- 削除要求に対応できないID設計。
- 巨大状態を毎回JSONから再hydrateする。
- vector検索だけで監査検索を代替する。

### Canonical architecture

```text
sqlx/Postgres: account, consent, auth, audit, billing
SurrealDB: agent, role, task, memory graph, decision state
Polars: feature engineering
Qdrant/LanceDB: embeddings and semantic retrieval
Tantivy: transcript/log full-text search
DistX: explainable structured similarity R&D
rkyv: frozen rules/snapshots/context bundles
```

### Implementation recipes

1. event sourcing的に `DecisionEvent` / `ToolCallEvent` / `MemoryEvent` を型定義し、serde + tracing + DBへ共通利用する。
2. `Polars LazyFrame` は早期 `collect()` を避け、projection/predicate pushdownを効かせる。
3. `rkyv` snapshotはschema version付きDTOへ変換し、domain modelを直接archiveしない。
4. vector DB payloadにはPIIを最小化し、主キーでSQL/SurrealDB側へ戻る。
5. `Tantivy` は会話ログ・通話文字起こし・エージェント判断理由の検索に使う。

### Benchmarks / SLOs

- vector search p95。
- full-text search p95。
- graph query depth/cost。
- feature batch time。
- snapshot load time。
- PII deletion completeness。

### Update checklist

- SurrealDB/sqlxのquery behaviorとmigration影響を確認。
- Vector DBはindex format、payload schema、delete behaviorを確認。
- Polarsはlazy optimizer、Arrow互換、feature変更を確認。
- DistX系はyanked/version整合性を必ず確認。

### Sources

- `rustskills_sources.md` の `D006-D012`, `A014`, `D004`, `D010`。

---
