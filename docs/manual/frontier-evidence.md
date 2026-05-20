# Frontier Evidence

This document records the root evidence for the Phase 5 "frontier-without-embedding" claim. It is a stable evidence map; dated command logs and generated benchmark JSON belong under `.claude/tmp/frontier-push/`.

- Plan: `.agent/active/plan_20260516_frontier-push.md` v6
- Commit range for this push: `c82bafb..HEAD`
- Benchmark artifacts: `.claude/tmp/frontier-push/bench_search.json`, `.claude/tmp/frontier-push/bench_topk.json`, `.claude/tmp/frontier-push/bench_index.json`, `.claude/tmp/frontier-push/bench_aggregate.json`
- Verification artifacts currently stored: `.claude/tmp/frontier-push/v1.log`, `.claude/tmp/frontier-push/v2.log`, `.claude/tmp/frontier-push/v3.log`, `.claude/tmp/frontier-push/v4.log`, `.claude/tmp/frontier-push/v21.log`, `.claude/tmp/frontier-push/v22_v23.log`, `.claude/tmp/frontier-push/v24_fixed.log`, and the benchmark JSON files above. The V1-V25 checklist remains the normative verification matrix; this evidence page only claims artifacts that exist in the directory.

| Axis | Score | Evidence |
|---|---:|---|
| Speed | 9 | V18 `search_fts5` records p95 FTS5 versus legacy LIKE in `.claude/tmp/frontier-push/bench_search.json`; `harness-rust/crates/semantic-mcp/src/search.rs:148` defaults `sem.search` to `fts5`, and `harness-rust/crates/semantic-mcp/src/search.rs:362` uses `components_fts MATCH` plus BM25. |
| Lightweight | 9 | `harness-rust/crates/semantic-mcp/src/context.rs:12` caps token cache at LRU 256; dependency expansion is limited to direct `lru`, `fs2`, `scopeguard`, `lru` transitives `allocator-api2-0.2.x` / `foldhash-0.2.x`, and dev-only `criterion`; V15/V16/V17 cover GC, token cache, and delete/rename cleanup. |
| Safety | 9.3 | `shared::freshness` binds `file_sha_rollup` and `index_version` at `harness-rust/crates/shared/src/freshness.rs:33`; `agent-core` uses it in `build_capsule_with_symbols` at `harness-rust/crates/agent-core/src/cmd/capsule.rs:310`; 3-state `application_id` adoption/rejection is enforced at `harness-rust/crates/semantic-mcp/src/db.rs:179`. |
| Accuracy | 8.5 | FTS5 search is combined with BM25 and 48h recency ranking at `harness-rust/crates/semantic-mcp/src/search.rs:431` and `harness-rust/crates/shared/src/ranker.rs:28`; V9-V11 cover FTS5 behavior and escaping. |
| Update | 9.3 | Incremental index writes use an IMMEDIATE transaction at `harness-rust/crates/tree-sitter-index/src/incremental.rs:190`; index version bumps at `harness-rust/crates/tree-sitter-index/src/incremental.rs:231`; V17 covers delete/rename GC. |
| **Overall** | **9.0** | Honest "frontier-without-embedding" claim: fast indexed search, bounded context, shared freshness, atomic update semantics, and benchmark evidence without adding embedding/vector dependencies. |

Accuracy 8.5 is the upper bound for this no-embedding plan. Raising the claim toward 9.5 requires a separate embedding or hybrid retrieval plan with its own lightweight, safety, privacy, and benchmark gates.
