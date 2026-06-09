#!/usr/bin/env bash
# semantic-bootstrap.sh
#
# RevHarness adopter / first-run bootstrap for the semantic-mcp layer.
#
# Problem this solves
# -------------------
# The Rust semantic-mcp (harness-rust/crates/semantic-mcp/) auto-migrates its
# SQLite schema on first CLI invocation that opens the db. Adopters who never
# explicitly invoke the CLI end up with either:
#   - no db at all (first sem.* call fails)
#   - a stale schema left over from earlier harness versions
#
# The Rust semantic-mcp writes to a platform-specific on-disk location
# (Library/Application Support on macOS, .local/share on Linux) and is built by
# `cargo build` in harness-rust/. It is the ONLY supported semantic backend;
# the legacy Node tree (scripts/semantic-mcp-server/) was retired in
# de-overkill S3-B3.
#
# What this script does (idempotent)
# ----------------------------------
# 1. Resolves the Rust workspace (harness-rust/) and confirms the Rust
#    semantic-mcp crate builds (`cargo check -p semantic-mcp`).
# 2. Reads .shared/project_id (managed-adopter identity).
# 3. Invokes one read-only CLI command (queue export-json) via
#    semantic-review-queue.sh, which drives the Rust backend and triggers its
#    schema migration against the platform Rust semantic db.
# 4. Confirms the migration ran cleanly (the export succeeded).
#
# This script does NOT (by default):
#   - run sem.context.top_k or sem.capsule (those need a real task)
#
# Source-first index coverage (--index-all, root-cause 2.1)
# ---------------------------------------------------------
# Indexing is otherwise edit-driven: only files touched by the Edit/Write
# hook get indexed, so stable unedited source (the usual semantic search
# target) is never covered. Passing `--index-all` runs the agent-core
# `context index-all --apply` bootstrap, which indexes the WHOLE repo's
# source now (changed_only=false, gc_orphans=true) into the Rust
# semantic-mcp db. It is idempotent (file_hash + grammar_version). If
# index-all is unavailable or fails, treat semantic output as absent/STALE:
# raw-read the affected files and do not rely on a stale capsule body.
#
# Incremental post-commit index (index-commit + opt-in hook)
# ----------------------------------------------------------
# `index-all` is a whole-repo walk (minutes) — too heavy to run on every
# commit. For keeping the index fresh as you commit, agent-core also offers
# `context index-commit --head <commit> --base <parent> --apply`, which upserts
# ONLY the source-filtered files changed by that immutable commit range
# (gc_orphans=false: other files' symbols are left intact). To run it
# automatically after each commit, install the opt-in post-commit hook
# (default OFF):
#
#   bash scripts/install-rev-harness-hooks.sh \
#     --harness-root <harness> --with-index-hook
#   # prerequisite: cargo build --release -p agent-core
#
# The hook captures POST_HEAD and POST_BASE before detaching so later commits
# cannot change the indexed range. Root commits omit --base. The hook is
# fail-open (never blocks a commit) and detached (commit latency stays ~zero).
# A missing agent-core binary is logged to the bounded redacted hook log and
# skipped.
#
# Operational note: index-commit does NOT reap symbols for deleted/renamed
# files (gc_orphans=false). Run `agent-core context index-all` periodically
# (or `semantic-bootstrap.sh --index-all`) to sweep those orphans.
#
# Usage
# -----
#   bash scripts/semantic-bootstrap.sh
#   bash scripts/semantic-bootstrap.sh --skip-build   # skip cargo check
#   bash scripts/semantic-bootstrap.sh --json         # machine-readable report
#   bash scripts/semantic-bootstrap.sh --index-all    # also full-index source (2.1)
#
# Exit codes
# ----------
#   0  bootstrap completed (Rust migration triggered cleanly)
#   1  generic failure
#   2  prerequisite missing (project_id absent or malformed)
#   3  build failure (Rust workspace absent or cargo check failed)
#   4  schema verification failed (migration ran but export did not succeed)
#
# Identity-check
# --------------
# This script sources scripts/_canonical-guard.sh so it respects the
# 0.0.12 default-warn identity classification. In an ambiguous-copy
# context it emits an advisory but continues (REV_HARNESS_VENDOR_CHECK
# =strict makes it fail-close like wrappers do).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"
REPO_ROOT="$PROJECT_ROOT"
HARNESS_ROOT="${HARNESS_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd -P)}"
JSON_OUTPUT="false"
SKIP_BUILD="false"
INDEX_ALL="false"

die() { printf 'semantic-bootstrap: %s\n' "$*" >&2; exit "${2:-1}"; }
log() { [[ "$JSON_OUTPUT" == "true" ]] || printf '[semantic-bootstrap] %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --json) JSON_OUTPUT="true"; shift ;;
    --skip-build) SKIP_BUILD="true"; shift ;;
    --index-all) INDEX_ALL="true"; shift ;;
    -h|--help)
      sed -n '1,86p' "$0"
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

QUEUE_CLI="$HARNESS_ROOT/scripts/semantic-review-queue.sh"
[[ -f "$QUEUE_CLI" ]] || die "scripts/semantic-review-queue.sh missing — harness installation incomplete" 3

# Resolve the Rust workspace. Absent (status 3) means the harness Rust tree is
# not present; the semantic backend cannot run. Fail with exit 3 (build/prereq).
WORKSPACE_ROOT=""
RWS_STATUS=0
WORKSPACE_ROOT="$(bash "$QUEUE_CLI" __internal-rust-workspace-root --repo-root "$REPO_ROOT" --allow-absent)" || RWS_STATUS=$?
if [[ "$RWS_STATUS" -eq 3 || -z "$WORKSPACE_ROOT" ]]; then
  die "Rust workspace (harness-rust/) not found — the Rust semantic backend is required (the Node backend was removed in S3). Run 'cargo build -p semantic-mcp' inside harness-rust/ after syncing the harness." 3
elif [[ "$RWS_STATUS" -ne 0 ]]; then
  die "Rust workspace resolution failed (status $RWS_STATUS)" 3
fi

# Confirm the Rust semantic-mcp crate builds. This replaces the old Node
# npm/tsc build step. --skip-build skips the (slower) cargo check.
if [[ "$SKIP_BUILD" == "false" ]]; then
  log "verifying Rust semantic backend builds (cargo check -p semantic-mcp)"
  ( cd "$WORKSPACE_ROOT" && cargo check -p semantic-mcp >/dev/null 2>&1 ) \
    || die "cargo check -p semantic-mcp failed — build the Rust backend with 'cargo build -p semantic-mcp'" 3
fi

# Trigger the Rust backend's schema migration by invoking one read-only verb
# (queue export-json) through the queue CLI, which drives the Rust semantic-mcp.
# The Rust backend auto-migrates its platform-specific db on first open.
log "triggering Rust semantic migration for project_id=$PROJECT_ID"
SNAPSHOT="${TMPDIR:-/tmp}/semantic-bootstrap-${PROJECT_ID}.json"
( cd "$REPO_ROOT" && bash "$QUEUE_CLI" export-json --project-id "$PROJECT_ID" --output "$SNAPSHOT" --repo-root "$REPO_ROOT" >/dev/null 2>&1 ) \
  || die "queue export-json failed (Rust migration did not run cleanly)" 1

# Schema contract: a clean export-json proves the Rust backend opened and
# migrated the db to the current registry layout. The exported snapshot must
# exist and be valid JSON.
[[ -f "$SNAPSHOT" ]] || die "expected snapshot not at $SNAPSHOT after migration" 4
if command -v jq >/dev/null 2>&1; then
  jq -e . "$SNAPSHOT" >/dev/null 2>&1 || die "schema verification FAILED: snapshot is not valid JSON" 4
fi

# Optional source-first full index (root-cause 2.1). Runs the agent-core
# `context index-all --apply` bootstrap so stable, unedited source is covered
# (not just edit-touched files). Advisory-only: a missing binary skips the step
# without failing the Node-layer bootstrap above.
INDEX_ALL_STATUS="skipped"
if [[ "$INDEX_ALL" == "true" ]]; then
  AGENT_CORE_BIN=""
  for cand in \
    "${REV_HARNESS_AGENT_CORE_BIN:-}" \
    "$HARNESS_ROOT/harness-rust/target/release/agent-core" \
    "$HARNESS_ROOT/harness-rust/target/debug/agent-core"; do
    if [[ -n "$cand" && -x "$cand" ]]; then AGENT_CORE_BIN="$cand"; break; fi
  done
  if [[ -z "$AGENT_CORE_BIN" ]]; then
    log "ADVISORY: --index-all requested but no agent-core binary found; \
semantic capsule/index output is unavailable. Raw-read affected files now; \
build it with 'cargo build --release -p agent-core' then re-run, or invoke \
'agent-core context index-all --apply' directly when optional semantic \
acceleration is needed. Skipping (Rust semantic bootstrap OK)."
    INDEX_ALL_STATUS="binary-missing"
  else
    log "source-first full index via $AGENT_CORE_BIN (context index-all --apply)"
    if ( cd "$REPO_ROOT" && "$AGENT_CORE_BIN" context index-all --apply >/dev/null 2>&1 ); then
      INDEX_ALL_STATUS="applied"
      log "index-all OK (whole-repo source indexed)"
    else
      INDEX_ALL_STATUS="failed"
      log "ADVISORY: index-all failed; semantic capsule/index output may be STALE. Raw-read affected files now; Rust semantic bootstrap still succeeded."
    fi
  fi
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  printf '{"status":"ok","backend":"rust","project_id":"%s","workspace_root":"%s","snapshot":"%s","index_all":"%s"}\n' \
    "$PROJECT_ID" "$WORKSPACE_ROOT" "$SNAPSHOT" "$INDEX_ALL_STATUS"
else
  log "OK: project_id=$PROJECT_ID backend=rust workspace=$WORKSPACE_ROOT"
  log "snapshot written to $SNAPSHOT"
  [[ "$INDEX_ALL" == "true" ]] && log "index-all: $INDEX_ALL_STATUS"
fi
exit 0
