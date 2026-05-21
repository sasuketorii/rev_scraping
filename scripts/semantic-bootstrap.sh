#!/usr/bin/env bash
# semantic-bootstrap.sh
#
# RevHarness adopter / first-run bootstrap for the semantic-mcp layer.
#
# Problem this solves
# -------------------
# Semantic-mcp (Node, scripts/semantic-mcp-server/) auto-migrates its
# SQLite schema on first CLI invocation that opens the db. Adopters who
# never explicitly invoke the CLI end up with either:
#   - no db at all (first sem.* call fails)
#   - a stale 4-table symbol-only db left over from earlier harness
#     versions (registry / queue / review tables missing)
#
# The Rust semantic-mcp under harness-rust/crates/semantic-mcp/ writes
# to a different on-disk location (Library/Application Support on macOS,
# .local/share on Linux). That layer is independent of the Node layer
# and is built by `cargo build` in harness-rust/.
#
# What this script does (idempotent)
# ----------------------------------
# 1. Ensures scripts/semantic-mcp-server/ is built (`npm install` +
#    `npm run build` if dist/ is missing).
# 2. Reads .shared/project_id (managed-adopter identity).
# 3. Invokes one read-only CLI command (queue export-json) that triggers
#    runMigrations() against ~/.semantic-mcp/<project_id>/semantic.db,
#    bringing the schema to the current 7-table registry layout.
# 4. Reports the resulting table set so the operator can sanity-check.
#
# This script does NOT:
#   - touch the Rust semantic-mcp db under Library/Application Support
#     (use `cargo build -p semantic-mcp` for that)
#   - run sem.context.top_k or sem.capsule (those need a real task)
#   - rebuild the search index (the index is rebuilt on demand by the
#     Rust layer when sem.search is called against changed files)
#
# Usage
# -----
#   bash scripts/semantic-bootstrap.sh
#   bash scripts/semantic-bootstrap.sh --skip-build   # if dist/ already present
#   bash scripts/semantic-bootstrap.sh --json         # machine-readable report
#
# Exit codes
# ----------
#   0  bootstrap completed (schema verified)
#   1  generic failure
#   2  prerequisite missing (project_id absent or malformed)
#   3  build failure
#   4  schema verification failed (migration ran but tables not as expected)
#
# Identity-check
# --------------
# This script sources scripts/_canonical-guard.sh so it respects the
# 0.0.12 default-warn identity classification. In an ambiguous-copy
# context it emits an advisory but continues (REV_HARNESS_VENDOR_CHECK
# =strict makes it fail-close like wrappers do).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
JSON_OUTPUT="false"
SKIP_BUILD="false"

die() { printf 'semantic-bootstrap: %s\n' "$*" >&2; exit "${2:-1}"; }
log() { [[ "$JSON_OUTPUT" == "true" ]] || printf '[semantic-bootstrap] %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT="true"; shift ;;
    --skip-build) SKIP_BUILD="true"; shift ;;
    -h|--help)
      sed -n '1,60p' "$0"
      exit 0
      ;;
    *) die "unknown arg: $1" ;;
  esac
done

# 0.0.12 identity-check (advisory by default; strict via env)
# shellcheck source=scripts/_canonical-guard.sh
source "$SCRIPT_DIR/_canonical-guard.sh"
rev_harness_assert_canonical_root semantic-bootstrap

PID_FILE="$REPO_ROOT/.shared/project_id"
[[ -f "$PID_FILE" ]] || die ".shared/project_id missing — run scripts/init-project.sh first" 2
PROJECT_ID="$(head -1 "$PID_FILE" | tr -d '\r' | sed 's/[[:space:]]*$//')"
[[ "$PROJECT_ID" =~ ^[A-Za-z0-9_.-]+$ ]] || die "project_id malformed: $PROJECT_ID" 2

MCP_DIR="$REPO_ROOT/scripts/semantic-mcp-server"
[[ -d "$MCP_DIR" ]] || die "scripts/semantic-mcp-server/ missing — harness installation incomplete"
DIST="$MCP_DIR/dist/cli.js"

if [[ "$SKIP_BUILD" == "false" && ! -f "$DIST" ]]; then
  log "building semantic-mcp-server (npm install + tsc)"
  ( cd "$MCP_DIR" && npm install --no-fund --no-audit >/dev/null 2>&1 ) || die "npm install failed" 3
  ( cd "$MCP_DIR" && npm run build >/dev/null 2>&1 ) || die "tsc build failed" 3
fi
[[ -f "$DIST" ]] || die "dist/cli.js missing after build attempt" 3

log "triggering migration for project_id=$PROJECT_ID"
SNAPSHOT="${TMPDIR:-/tmp}/semantic-bootstrap-${PROJECT_ID}.json"
( cd "$REPO_ROOT" && node "$DIST" queue export-json --project-id "$PROJECT_ID" --output "$SNAPSHOT" >/dev/null 2>&1 ) || die "queue export-json failed (migration did not run cleanly)" 1

DB="$HOME/.semantic-mcp/$PROJECT_ID/semantic.db"
[[ -f "$DB" ]] || die "expected db not at $DB after migration" 4

EXPECTED_TABLES="capsules components outbox_queue projects registry_deltas review_queue_items review_runs"
ACTUAL_TABLES="$(sqlite3 "$DB" "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('capsules','components','outbox_queue','projects','registry_deltas','review_queue_items','review_runs') ORDER BY name" | tr '\n' ' ' | sed 's/[[:space:]]*$//')"

if [[ "$ACTUAL_TABLES" != "$EXPECTED_TABLES" ]]; then
  die "schema verification FAILED: expected [$EXPECTED_TABLES] got [$ACTUAL_TABLES]" 4
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  printf '{"status":"ok","project_id":"%s","db_path":"%s","registry_tables":7,"snapshot":"%s"}\n' \
    "$PROJECT_ID" "$DB" "$SNAPSHOT"
else
  log "OK: project_id=$PROJECT_ID schema=7-table-registry db=$DB"
  log "snapshot written to $SNAPSHOT"
fi
exit 0
