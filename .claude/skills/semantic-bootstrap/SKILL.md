---
name: semantic-bootstrap
description: Opt-in bootstrap guidance for the RevHarness semantic-mcp layer in a new or freshly synced project. Use when an adopter installs RevHarness, sync-bumps to a new harness version, or encounters semantic table/freshness errors. Run scripts/semantic-bootstrap.sh; raw-read while semantic state is absent or STALE.
---

# Semantic Bootstrap

## Why this exists

RevHarness has a single canonical **Rust** semantic-mcp backend. It is an
opt-in acceleration surface, not required context for session start:

- **Rust** at `harness-rust/crates/semantic-mcp/` — provides the search,
  capsule, index, registry, queue, and review surfaces from one backend.
  Writes to
  `~/Library/Application Support/Revharness/semantic-mcp/v1/<project_id>/`
  (macOS) or `~/.local/share/Revharness/semantic-mcp/v1/<project_id>/`
  (Linux).

The layer auto-migrates its schema **on first use** (first request after
`cargo run`). For adopters this means there is a window where the db file
exists but the schema is incomplete from an older harness version. sem.* tools
then fail with "table ... missing" or silently return zero results.

`scripts/semantic-bootstrap.sh` confirms the Rust backend builds
(`cargo check -p semantic-mcp`) and triggers the Rust migration explicitly by
running one read-only `queue export-json` through
`scripts/semantic-review-queue.sh`.

## When to use this skill

Trigger this skill when any of the following is true:

- Adopting RevHarness into a new project (immediately after
  `scripts/init-project.sh`).
- Syncing to a new RevHarness version that touches the Rust semantic-mcp
  schema/migrations under `harness-rust/crates/semantic-mcp/`.
- A `sem.*` MCP call or `bash scripts/semantic-review-queue.sh ...`
  returns "no such table" / "table ... missing".
- `bash scripts/harness-doctor.sh --quick` reports semantic-mcp db
  health as UNKNOWN or WARN with a tables-missing note.
- The operator asks "did the semantic db get built", "is the queue
  table set up", "how do I run reindex".
- A semantic capsule/context request reports STALE, cache miss, or token
  freshness failure. In that case, raw-read the affected files first;
  bootstrap/reindex only restores optional semantic acceleration.

Do **not** invoke this skill for:

- Rebuilding the Rust-side capsule/index db (that requires
  `cargo build -p semantic-mcp` and is out of scope).
- Refreshing search FTS index (the Rust layer rebuilds FTS on demand
  when `sem.search` is called against changed files).
- Importing existing data — bootstrap is schema-only.

## Canonical workflow

```bash
# In the project root (rev_harness or a managed-adopter checkout):
bash scripts/semantic-bootstrap.sh           # human-readable
bash scripts/semantic-bootstrap.sh --json    # machine-readable
bash scripts/semantic-bootstrap.sh --skip-build  # skip the cargo check
```

The script:

1. Sources `scripts/_canonical-guard.sh` (0.0.12 identity-check,
   advisory by default).
2. Reads `.shared/project_id` (fails closed if absent / malformed).
3. Resolves the Rust workspace (`harness-rust/`) and confirms the Rust
   semantic-mcp crate builds (`cargo check -p semantic-mcp`).
4. Runs one read-only `queue export-json` through
   `scripts/semantic-review-queue.sh`, which drives the Rust backend and
   triggers its schema migration against the project db.
5. Confirms the export snapshot was produced; exits non-zero if not.

Exit codes:

- `0` — bootstrap succeeded, Rust migration triggered cleanly
- `2` — prerequisite missing (no `.shared/project_id`)
- `3` — build failure (Rust workspace absent or `cargo check` failed)
- `4` — schema verification failed (migration ran but export did not succeed)

## Verifying it worked

```bash
# Trigger/verify the Rust migration and inspect the export snapshot:
PID="$(cat .shared/project_id)"
bash scripts/semantic-review-queue.sh export-json \
  --project-id "$PID" --output /tmp/q.json
cat /tmp/q.json   # should show pending_count / leased_count fields
```

## Relationship to other skills

- **revharness-semantic-mcp-usage**: documents optional use of
  sem.context.top_k / sem.capsule once the db is bootstrapped and FRESH.
  On STALE / absent semantic state, raw-read instead.
- **orchestrator-bootstrap**: covers higher-level harness adoption
  (project_id artifact, registry files, role docs). Run
  `init-project.sh` first, then `semantic-bootstrap.sh`.
- **harness-official-docs-update**: when docs reference semantic-mcp
  build steps, point them at `scripts/semantic-bootstrap.sh` rather
  than describing the cargo/sqlite incantation inline.

## Known limitations (gap surface)

The semantic backend is the single canonical Rust backend. If an adopter
reports Rust-side "no such table" errors, the remediation is:

```bash
( cd harness-rust && cargo build -p semantic-mcp )
bash scripts/semantic-bootstrap.sh   # fires the Rust migration
```
Related: `rev-harness-lifecycle` for full adopter setup (includes semantic-bootstrap as one of 5 phases).
