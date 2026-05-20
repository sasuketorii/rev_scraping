# Data / State / Search Reference

## Core stack

- SQL: Drizzle or Kysely.
- ORM-heavy projects: Prisma as Adopt.
- Database: Postgres.
- Cache/job queue: Redis + BullMQ.
- Vector search: Qdrant / LanceDB / Pinecone according to deployment model.

## CRM / psychometrics rules

- Separate PII from embeddings and psychometric payloads.
- Keep consent, deletion, audit, and retention as first-class tables.
- Do not put raw phone/audio/PII directly into vector payload unless legally and operationally justified.
- For Social Psychometrics CRM, store explanation fields so similarity decisions are inspectable.

## Agent memory

- Short-term state: app memory/cache.
- Operational state: Postgres/SurrealDB/RDB or graph store.
- Semantic retrieval: vector DB.
- Audit: append-only log/events.
