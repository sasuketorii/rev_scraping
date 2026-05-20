# AI / Data / Search Reference

- **Version**: v0.1.2
- **Generated from**: `../rust-skills-master.md`
- **Role**: Lane detail extract. The master remains the single source of truth.
- **Primary crates**: `serde`, `serde_json`, `simd-json`, `rkyv`, `surrealdb`, `sqlx`, `polars`, `qdrant-client`, `lancedb`, `tantivy`, `distx`, `distx-similarity`, `moka`, `arc-swap`, `dashmap`

## Use Cases

- Agent state management and workflow memory.
- CRM analytics, Big Five / behavioral features, and batch feature engineering.
- RAG, vector search, full-text search, and explainable structured similarity R&D.
- Frozen snapshots and static context bundles.

## Responsibility Split

```text
Postgres/sqlx       -> hard state, auth, billing, consent, audit
SurrealDB           -> dynamic graph/document state
Qdrant/LanceDB      -> embedding/vector retrieval
Tantivy             -> full-text and audit search
DistX               -> explainable structured similarity, R&D
Polars              -> batch feature engineering
rkyv                -> frozen snapshots / static rule sets
```

## Engineering Rules

- Keep auth, billing, consent, permissions, and audit in Postgres/SQLx.
- Keep dynamic organization, agent, relationship, task, and conversation state in SurrealDB when document-graph shape is required.
- Use Qdrant as the first production vector-search candidate; treat LanceDB as local/serverless/R&D where appropriate.
- Use Tantivy for full-text search over transcripts, logs, and knowledge.
- Use Polars lazy plans for batch feature work.
- Use `rkyv` for immutable snapshots with schema version and validation.
- Keep PII deletion, consent boundaries, and explainability explicit.

## Forbidden Patterns

- Treating any one database as the universal store.
- Storing raw PII in vector payloads.
- Using psychometric scores as deterministic facts or discriminatory decision inputs.
- Archiving mutable domain models directly without versioned snapshot types.
- Holding concurrent map guards across `.await`.

## SLO / Review Metrics

- vector search p95 latency.
- full-text search p95 latency.
- graph query depth and cost.
- batch feature runtime.
- snapshot load time.
- PII deletion completeness.

## Update Checks

- Verify version, yanked status, advisory status, feature/default-feature diff, MSRV, license, benchmark impact, and project impact.
- Treat `distx` and `distx-core` as R&D until yanked/version history and production readiness are clear.
