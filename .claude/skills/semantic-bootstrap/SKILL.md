---
name: semantic-bootstrap
description: How and when to bootstrap the RevHarness semantic-mcp layer in a new or freshly synced project. Use this skill whenever an adopter first installs RevHarness, sync-bumps to a new harness version, or encounters "table missing" / "stale schema" errors from sem.* tools or the queue/review surfaces. Run scripts/semantic-bootstrap.sh — do not try to hand-craft the migration SQL.
---

# Semantic Bootstrap

## Why this exists

RevHarness ships **two** independent semantic-mcp implementations:

1. **Node** at `scripts/semantic-mcp-server/` — registry / queue / review
   surfaces. Writes to `~/.semantic-mcp/<project_id>/semantic.db`.
2. **Rust** at `harness-rust/crates/semantic-mcp/` — search / capsule /
   index surfaces. Writes to
   `~/Library/Application Support/Revharness/semantic-mcp/v1/<project_id>/`
   (macOS) or `~/.local/share/Revharness/semantic-mcp/v1/<project_id>/`
   (Linux).

Both layers auto-migrate their schema **on first use** (Node: first CLI
invocation that opens the db; Rust: first request after `cargo run`).
For adopters this means there is a window where the db file exists but
the schema is incomplete — typically only `symbols` / `file_parse_cache`
/ `symbol_dependencies` / `_ts_meta` from an older harness version.
sem.* tools then fail with "table ... missing" or silently return zero
results.

`scripts/semantic-bootstrap.sh` triggers the Node-side migration
explicitly and verifies the resulting 7-table registry layout
(`capsules`, `components`, `outbox_queue`, `projects`, `registry_deltas`,
`review_queue_items`, `review_runs`).

## When to use this skill

Trigger this skill when any of the following is true:

- Adopting RevHarness into a new project (immediately after
  `scripts/init-project.sh`).
- Syncing to a new RevHarness version that touches
  `scripts/semantic-mcp-server/src/db/migrations.ts`.
- A `sem.*` MCP call or `bash scripts/semantic-review-queue.sh ...`
  returns "no such table" / "table ... missing".
- `bash scripts/harness-doctor.sh --quick` reports semantic-mcp db
  health as UNKNOWN or WARN with a tables-missing note.
- The operator asks "did the semantic db get built", "is the queue
  table set up", "how do I run reindex".

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
bash scripts/semantic-bootstrap.sh --skip-build  # if dist/ already built
```

The script:

1. Sources `scripts/_canonical-guard.sh` (0.0.12 identity-check,
   advisory by default).
2. Reads `.shared/project_id` (fails closed if absent / malformed).
3. Builds `scripts/semantic-mcp-server/dist/` if missing
   (`npm install` + `npm run build`).
4. Invokes `node dist/cli.js queue export-json --project-id <pid>
   --output /tmp/semantic-bootstrap-<pid>.json` — read-only call that
   triggers `runMigrations()` against the project db.
5. Verifies the 7 expected registry tables exist; exits non-zero if
   any are missing.

Exit codes:

- `0` — bootstrap succeeded, schema verified
- `2` — prerequisite missing (no `.shared/project_id`)
- `3` — build failure (`npm install` or `tsc`)
- `4` — schema verification failed (migration ran but expected tables
  not present — likely indicates an upstream `migrations.ts` regression
  worth flagging in rev_harness)

## Verifying it worked

```bash
# Schema check (should output 7 tables):
PID="$(cat .shared/project_id)"
sqlite3 ~/.semantic-mcp/$PID/semantic.db ".tables"

# Queue export sanity:
node scripts/semantic-mcp-server/dist/cli.js queue export-json \
  --project-id "$PID" --output /tmp/q.json
cat /tmp/q.json   # should show pending_count / leased_count fields
```

## Relationship to other skills

- **revharness-semantic-mcp-usage**: documents how to **use**
  sem.context.top_k / sem.capsule once the db is bootstrapped. Always
  pair these two when onboarding a new adopter.
- **orchestrator-bootstrap**: covers higher-level harness adoption
  (project_id artifact, registry files, role docs). Run
  `init-project.sh` first, then `semantic-bootstrap.sh`.
- **harness-official-docs-update**: when docs reference semantic-mcp
  build steps, point them at `scripts/semantic-bootstrap.sh` rather
  than describing the npm/tsc/sqlite incantation inline.

## Known limitations (gap surface)

This skill closes the Node-side gap. The Rust-side first-run UX is
still implicit (it migrates on first MCP request and there is no
`harness-rust/bootstrap.sh` analog). If an adopter reports Rust-side
"no such table" errors, the current remediation is:

```bash
( cd harness-rust && cargo build -p semantic-mcp )
# then invoke any sem.* MCP call to fire the Rust migration
```

A future round should consolidate both into a single
`scripts/semantic-bootstrap.sh --include-rust` or expand the Rust
layer's own bootstrap. Track this when next touching
`harness-rust/crates/semantic-mcp/`.
