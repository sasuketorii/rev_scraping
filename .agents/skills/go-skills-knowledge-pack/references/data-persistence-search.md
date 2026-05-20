# Data / Persistence / Search

## PostgreSQL lane

- `github.com/jackc/pgx/v5` is default PostgreSQL driver/toolkit.
- `github.com/sqlc-dev/sqlc` generates type-safe Go from SQL.
- Use `database/sql` only when portability matters more than pgx features.

## sqlc rules

- SQL files are the contract.
- Avoid `SELECT *`.
- Keep queries named and reviewed.
- Use migrations separately from generated queries.
- Run generation in CI and fail on drift.

## ent lane

Use `entgo.io/ent` when schema graph/codegen improves productivity. It is v0.x, so keep Watch status.

Good for:

- complex domain models,
- graph-like entity traversal,
- admin APIs,
- migration generation.

Avoid for:

- SQL hot path where handcrafted SQL is clearer,
- massive streaming scans,
- latency-critical batch ingestion.

## Vector lane

- Qdrant Go client for dedicated vector search.
- pgvector-go/pgvector for PostgreSQL-native retrieval where operational simplicity wins.

Design rule:

```text
PostgreSQL = source of truth / auth / audit / state
Vector store = semantic retrieval / similarity search
```

Never store raw PII in vector payload unless deletion, access control, and audit are solved.

## Cache lane

- Ristretto v2 for high-throughput memory cache.
- fastcache for GC-light large-entry cache.
- hashicorp/golang-lru for simple fixed-size LRU.

Always define:

- key normalization,
- max cost/size,
- TTL,
- eviction policy,
- negative cache behavior.
