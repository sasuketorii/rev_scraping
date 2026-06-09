---
name: revharness-semantic-mcp-usage
description: Opt-in RevHarness semantic-mcp (Rust) reference. Covers sem.context.top_k -> sem.capsule, context_token, freshness hashes, FTS5 BM25 search, sem.admin.gc, placement v2, RSEM marker, and test isolation. Use raw-read when semantic state is absent or STALE.
---

# RevHarness Semantic MCP Usage

## Overview

semantic-mcp は opt-in の補助 surface である。必須 context は raw-read を優先し、FRESH な index / context_token がある場合だけ Rust semantic-mcp の `sem.context.top_k` -> `sem.capsule` 2-step flow を使ってよい。caller が `top_k_symbols` を直接送る旧 flow は fail-closed で拒否され、freshness は `INDEX_VERSION` / `FILE_SHA_ROLLUP` / `CAPSULE_SHA256` と shared Rust code によって bind される。STALE / absent / cache miss / token expiry の場合は raw-read に戻り、STALE capsule body を根拠にしない。

## When to use

Use this skill when a task touches or asks about any of these semantic-mcp surfaces:

- `semantic-mcp` Rust operation, usage, routing, docs, or review.
- `sem.context.top_k` request shape, result handling, or `context_token` lifetime.
- `sem.capsule` request shape, capsule hash behavior, or fail-closed errors.
- `top_k_symbols` migration from caller-provided input to server-issued context.
- `INDEX_VERSION`, `FILE_SHA_ROLLUP`, `TOPK_SHA256`, or `CAPSULE_SHA256`.
- FTS5 BM25 search, `sem.search`, `fts5_escape()`, or `kind="legacy-like"`.
- `sem.admin.gc`, orphan DB cleanup, dry-run behavior, or forced deletion.
- DB placement v2 under `Revharness/semantic-mcp/v1/{project_id}`.
- `application_id` marker `0x5253454D` / `RSEM` adoption or rejection.
- `REVHARNESS_TEST_HARNESS` and `SEMANTIC_MCP_HOME` test isolation.
- `agent-core/cmd/capsule.rs` freshness parity with semantic-mcp.
- Reviewer questions about semantic capsule evidence, fail-closed routing, or stale docs.

Do not use this skill as a reason to call MCP by itself. This is a reference skill; the routing registry keeps `mcp_servers: []` because agents read the contract here and then use the appropriate runtime surface separately.

## Optional workflow

When semantic output is useful and the index is FRESH, generate a capsule through `sem.context.top_k` followed by `sem.capsule`. This workflow is not a session-start prerequisite.

1. Call `sem.context.top_k`.

   Required params:

   - `project_id`: RevHarness project id; must match the server context.
   - `task_id`: task lineage or current work id.
   - `phase`: current phase label, for example `coding`, `review`, or `handoff`.
   - `changed_files`: repo-relative files affected by the task.

   Required bounds:

   - `changed_files` length must be `1..=512`.
   - Each changed file must be a repo-relative string.
   - Empty strings, absolute paths, or parent traversal are invalid.

   Optional bounded params:

   - `k`: default `8`, valid range `1..=32`.
   - `max_depth`: default `3`, valid range `1..=5`.
   - `max_nodes`: default `256`, valid range `1..=1024`.

   These optional params are bounded, not clamped. Range violations must fail closed with a JSON-RPC error. Do not describe out-of-range behavior as automatic clamping.

2. Use the `sem.context.top_k` response.

   Expected response fields include:

   - `context_token`: opaque server-issued token.
   - `top_k_symbols`: server-selected Top-K symbols for observability only.
   - `index_version`: tree-sitter index version at token issue time.
   - `file_sha_rollup`: changed-file freshness rollup at token issue time.
   - `issued_at_unix_ms`: token issue timestamp.
   - `ttl_secs`: token TTL, currently 30 minutes.

   Treat `context_token` as the only reusable Top-K handle. Do not persist or replay `top_k_symbols` as an input.

3. Within 30 minutes, call `sem.capsule`.

   Required params:

   - `project_id`
   - `task_id`
   - `phase`
   - `context_token`

   Optional params:

   - `budget`: total capsule token budget, capped by semantic-mcp.
   - `context`: small metadata object for signals such as `preflight_verdict`, `target_lock`, `ambiguity`, `duplicate_risk`, and `changed_symbols`.

4. Never send caller-provided Top-K.

   Forbidden fields:

   - Top-level `top_k_symbols`.
   - `context.top_k_symbols`.

   `sem.capsule` must reject either form with a fail-closed error similar to:

   ```text
   sem.capsule failed: top_k_symbols is server-issued; provide context_token instead (see sem.context.top_k) (fail-closed)
   ```

5. Handle common `sem.capsule` failures by reissuing `sem.context.top_k`.

   Reissue when:

   - `context_token` is missing.
   - `context_token` is unknown.
   - `context_token` is expired.
   - `file_parse_cache changed since context_token was issued`.
   - `cache freshness violation` appears in the error.

   Do not bypass these failures by reconstructing Top-K in the caller. A stale token means no capsule body is valid; raw-read the affected files, then optionally reissue `sem.context.top_k` after freshness is restored.

6. Keep the capsule bounded.

   The canonical semantic capsule budget is 220 tokens total: 200 body tokens plus 20 metadata/framing tokens. If the response exceeds the bounded budget, semantic-mcp must fail closed instead of emitting an oversized capsule.

## Index coverage (source-first bootstrap)

Indexing is **edit-driven**: only files touched by the Edit/Write hook are indexed. Stable, unedited source — usually the very code you want semantic to find — is therefore **not covered** until something touches it. Symptoms: `sem.context.top_k` returns a `file_parse_cache miss` for a changed file you have not edited, and `sem.symbols.search` returns 0 rows for a symbol that demonstrably exists.

When `sem.context.top_k` returns:

```
sem.context.top_k failed: file_parse_cache miss for <path>. This file is not yet indexed ... Run the source-first full reindex once: `agent-core context index-all --apply` ...
```

run the **source-first full index** once from the repo root:

```
agent-core context index-all --apply
# or, during adopter setup / sync:
scripts/semantic-bootstrap.sh --index-all
```

`context index-all` indexes the WHOLE repo's source now (`changed_only=false`, `gc_orphans=true`, idempotent by `file_hash + grammar_version`). It excludes top-level harness paths (`.agent/`, `.claude/`, `docs/`, top-level `scripts/`, …) but **includes nested product paths** such as `contact_sender_v2/.../scripts/sender-opt`. `gc_orphans=true` purges stale legacy rows. Dry-run is the default (`agent-core context index-all` with no `--apply` reports candidate counts without writing).

This is **not** lazy in-request indexing: the MCP read-server never indexes on a `top_k` call (avoids write-contention / latency / freshness races). The miss error is actionable — run `index-all`, then retry; newly edited files are still picked up automatically on the next iteration.

## Capsule body anatomy

The capsule body includes freshness and integrity lines with distinct hash semantics.

- `TOPK_SHA256=<sha256>` records the digest of the server-issued Top-K content.
- `INDEX_VERSION=<u64>` is informational and excluded from the `CAPSULE_SHA256` hash input by fixed slot index.
- `FILE_SHA_ROLLUP=<sha256>` is part of the capsule body and is included in the `CAPSULE_SHA256` hash input.
- `CAPSULE_SHA256=<sha256>` is the final digest over the capsule hash input after the fixed `INDEX_VERSION` slot is excluded.

Operational consequences:

- `INDEX_VERSION` can change without asserting byte-identical capsule hash parity across all producers.
- `FILE_SHA_ROLLUP` must bind the capsule to the changed-file cache state.
- A `FILE_SHA_ROLLUP` mismatch between token issue and capsule build is a freshness violation.
- External references should preserve `CAPSULE_SHA256` and the same hash-inclusion rules.
- Do not claim `agent-core` and `semantic-mcp` produce byte-identical `CAPSULE_SHA256` formats; the shared requirement is the freshness invariant.

## sem.search usage

`sem.search` is an advisory search helper. New callers should use the default FTS5 mode unless they have a specific compatibility reason.

- Default search mode is `kind="fts5"`.
- FTS5 mode uses BM25 rank from `bm25(components_fts)`.
- Ranking also includes recent-update signal, with the current implementation favoring roughly 48h recency.
- Results are bounded by `limit`, with server-side maximums.
- `kind="legacy-like"` is opt-in only for backward compatibility.

`fts5_escape()` behavior:

- The entire user query is wrapped as an FTS5 phrase.
- Embedded `"` characters are escaped by doubling quotes.
- Operator-like text is treated as literal query text.
- `*`, `NEAR`, `OR`, `AND`, `-`, and `name:` prefixes are literals in this release.

Prefix wildcard is not provided in this release.

- Sending `freshness*` searches for the literal text `freshness*`; it does not become a prefix query.
- Sending raw FTS5 syntax through `query` is not a supported escape hatch.
- If raw FTS5 prefix query mode is needed, add it in a separate plan with a separate contract.
- FTS5 syntax errors and SQLite errors must fail closed through `rusqlite::Error`; callers must not silently fall back to a broader unbounded search.

### Search idiom & expectations

各ツールの探索範囲は固定されており、混同すると 0 件で迷子になる。意図を取り違えないこと。

- `sem.search` = **symbol-NAME lookup** over the ~129-row manually-curated `components` registry (plus a filesystem file-scan). FTS5 index covers only `name` / `semantic_id` / `module` / `kind` / `file_path` — **no description/docstring**. つまり自然言語クエリ（"the thing that validates tokens" のような文）は **0 hits** になる。クエリにはシンボル名トークン（識別子・モジュール名・パス断片）を渡すこと。`sem.search` は 31,514-row の tree-sitter `symbols` テーブルは一切引かない。
- `sem.context.top_k` = **impact discovery** over the 31,514 tree-sitter symbols。`changed_files` 入力を要求する fan-in / impact ランキングであって、free-form な検索インターフェースではない。「変更ファイルから影響範囲を出す」用途専用。
- `sem.registry.query` = filter the same ~129-row registry（`name_partial` / `kind` などで絞り込む）。これも自然言語検索ではない。
- **Free-form / natural-language discovery（"X に関係するシンボルを探したい"）には現状 semantic path が無い。** sanctioned fallback は `rg` / `grep`。フルの 31k symbol index を引く専用ツール `sem.symbols.search` は **planned**（別スライスで追跡）であり、まだ存在しないものとして扱うこと。利用可能であるかのように案内しない。

## sem.admin.gc usage

`sem.admin.gc` cleans up managed semantic-mcp DBs under placement v2. It is deliberately safe by default.

Arguments:

- `older_than_days`: default `30`; must be `>= 1`.
- `dry_run`: default `true`.
- `force`: default `false`.

Default behavior:

- `dry_run=true && force=false` lists candidates only.
- No DB files are deleted by default.
- Candidate size includes managed suffixes such as `semantic.db`, `semantic.db-wal`, `semantic.db-shm`, and `.migration.lock`.

Deletion behavior:

- Real deletion requires both `dry_run=false` and `force=true`.
- Do not tell operators that `force=true` alone deletes files.
- Do not tell operators that `dry_run=false` alone deletes files.
- Use both explicit flags in destructive examples.

CLI examples:

```bash
semantic-mcp gc --older-than 30d --dry-run
```

```bash
semantic-mcp gc --older-than 30d --dry-run=false --force
```

## DB placement (3 OS)

DB placement v2 stores Rust semantic-mcp data under a platform data directory plus `Revharness/semantic-mcp/v1/{project_id}/semantic.db`.

Linux:

```text
${XDG_DATA_HOME:-~/.local/share}/Revharness/semantic-mcp/v1/{project_id}/semantic.db
```

macOS:

```text
~/Library/Application Support/Revharness/semantic-mcp/v1/{project_id}/semantic.db
```

Windows:

```text
%LOCALAPPDATA%\Revharness\semantic-mcp\v1\{project_id}\semantic.db
```

Operational notes:

- The old `~/.semantic-mcp/{project_id}/semantic.db` path is legacy, not canonical.
- Agents must not create ad hoc DB paths in repo-local temp directories during normal runtime.
- `SEMANTIC_MCP_HOME` is reserved for explicit test harness mode.

## Test isolation

Tests that override semantic-mcp storage must opt in with both environment variables:

- `REVHARNESS_TEST_HARNESS=1`
- `SEMANTIC_MCP_HOME=$TMPDIR/...`

Rules:

- Set both variables together.
- If only `SEMANTIC_MCP_HOME` is set, normal builds should ignore it.
- If only `REVHARNESS_TEST_HARNESS=1` is set, there is no valid override path.
- Release builds may accept the override only when the explicit test harness pair is present.
- Integration tests should prefer the repository helper pattern equivalent to `tests/common/mod.rs::enable_test_harness()`.
- Do not reuse a shared developer data directory for tests.
- Do not point tests at production or user-level semantic DBs.

## application_id marker (0x5253454D = "RSEM")

Rust semantic-mcp uses SQLite `PRAGMA application_id` as a DB ownership marker.

Marker:

- Hex: `0x5253454D`
- ASCII: `RSEM`
- Purpose: distinguish RevHarness semantic DBs from foreign SQLite files.

Three-state adoption:

- Fresh or unstamped DB with `application_id = 0`: validate schema, stamp `RSEM`, then continue.
- Existing DB already stamped with `RSEM`: continue.
- DB stamped with any other marker: fail closed and refuse the foreign DB.

Safety notes:

- Adoption is not blind stamping.
- `validate_revharness_schema()` must pass before stamping an unstamped DB.
- Foreign DB rejection protects against path mistakes and accidental deletion or mutation of unrelated SQLite files.

## agent-core/cmd/capsule.rs も同 contract

`agent-core/cmd/capsule.rs::build_capsule_with_symbols` participates in the same freshness contract.

Shared expectations:

- It binds `file_sha_rollup` through `shared::freshness`.
- It binds `index_version` through `shared::freshness`.
- `Capsule` carries both fields with serde defaults for compatibility.
- `harness-cache::CachedCapsule` cache keys include freshness input.
- The no-symbols fallback path remains a separate freshness-free path and should not be treated as the canonical semantic-mcp 2-step capsule flow.

## References

- `CLAUDE.md`: MCP Semantic Server settings and capsule generation rules.
- `.agent_rules/RULES.md`: universal capsule discipline and deterministic evidence rules.
- `docs/manual/frontier-evidence.md`: frontier-push evidence and score records.
- `docs/manual/verification-truth-matrix.md`: deterministic checks, including V1-V25 semantic-mcp coverage.
- `harness-rust/crates/semantic-mcp/src/capsule.rs`: `sem.capsule` input validation, token use, and capsule hash construction.
- `harness-rust/crates/semantic-mcp/src/context_top_k.rs`: `sem.context.top_k` token issue and resolution.
- `harness-rust/crates/semantic-mcp/src/search.rs`: `sem.search`, FTS5 BM25 behavior, and `fts5_escape()`.
- `harness-rust/crates/semantic-mcp/src/admin_gc.rs`: `sem.admin.gc` dry-run and forced deletion behavior.
- `harness-rust/crates/semantic-mcp/src/db.rs`: `application_id` adoption and foreign DB rejection.
- `harness-rust/crates/shared/src/freshness.rs`: `FILE_SHA_ROLLUP` and `INDEX_VERSION` shared freshness snapshot.
- `harness-rust/crates/shared/src/paths.rs`: placement v2 and test harness override rules.
- `harness-rust/crates/shared/src/ranker.rs`: Top-K and search ranking support.
- `harness-rust/crates/agent-core/src/cmd/capsule.rs`: agent-core capsule builder freshness fields.
