#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

JSON_OUTPUT=false
PRINT_CHECKLIST=true
SEMANTIC=false
APPLY=false
CONFIRM_UNINSTALL=false

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-uninstall.sh [--print-checklist] [--json]
  scripts/rev-harness-uninstall.sh --semantic            # dry-run preview only
  scripts/rev-harness-uninstall.sh --semantic --apply --confirm-uninstall

Default mode is checklist-only (advisory). The checklist never deletes anything.

--semantic (opt-in, I-11):
  Dispose-together for THIS project's semantic database (the externally placed
  per-project DB under the platform data dir). Resolves the current project_id
  and targets ONLY its v1/<project_id>/ directory (semantic.db + -wal + -shm +
  .migration.lock + advisory lock).

  Safety:
    - Default is DRY-RUN: --semantic alone lists what WOULD be removed and
      deletes nothing.
    - Deletion requires BOTH --apply AND --confirm-uninstall (I-11 double opt-in).
    - The target DB is RSEM-validated (application_id = 0x5253454D) before any
      removal. A non-RSEM (foreign) DB is never deleted.
    - An active server lock causes the DB to be skipped (never delete a live DB).
EOF
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

emit_json() {
  local backup_present=false
  [[ -e "$PROJECT_ROOT/.git/hooks/pre-commit.rev-harness.bak" ]] && backup_present=true
  cat <<EOF
[
  {"step":1,"title":"Remove canonical PATH export","command":"sed -i.bak '/rev_harness\\/scripts/d' \"\${HOME}/.zshrc\" # repeat for \"\${HOME}/.bashrc\" if used"},
  {"step":2,"title":"Delete adopter state","path":".agent/registry/rev_harness_adoption_state.json"},
  {"step":3,"title":"Review installed links and dirs","paths":[".claude/",".agent/active/"],"action":"remove only RevHarness-created symlinks or dirs after inspection"},
  {"step":4,"title":"Restore pre-commit hook","backup":".git/hooks/pre-commit.rev-harness.bak","backup_present":$backup_present},
  {"step":5,"title":"Decide project identity","path":".shared/project_id","note":"immutable identity; do not delete unless explicitly retiring the project"},
  {"step":6,"title":"Canonical cargo target","path":"\${HOME}/dev/rev_harness/harness-rust/target","note":"canonical-side cache, not adopter-side"},
  {"step":7,"title":"Semantic DB dispose-together (opt-in)","command":"scripts/rev-harness-uninstall.sh --semantic --apply --confirm-uninstall","note":"removes only this project's external semantic DB; RSEM-validated; dry-run without both flags"}
]
EOF
}

emit_human() {
  local backup_note="backup not detected"
  [[ -e "$PROJECT_ROOT/.git/hooks/pre-commit.rev-harness.bak" ]] && backup_note="backup exists at .git/hooks/pre-commit.rev-harness.bak"
  cat <<EOF
RevHarness uninstall checklist (advisory only)

1. Remove canonical PATH export line from shell rc files. Example:
   sed -i.bak '/rev_harness\\/scripts/d' "\${HOME}/.zshrc"
   sed -i.bak '/rev_harness\\/scripts/d' "\${HOME}/.bashrc"

2. Delete adopter state:
   rm -f .agent/registry/rev_harness_adoption_state.json

3. Inspect installed links or dirs before removal:
   .claude/
   .agent/active/
   Remove only symlinks or directories created by the RevHarness install.

4. Restore .git/hooks/pre-commit if needed.
   Expected backup: .git/hooks/pre-commit.rev-harness.bak ($backup_note)

5. Decide what to do with .shared/project_id.
   This is immutable project identity; do not delete unless explicitly retiring the project.

6. Cargo target cleanup is canonical-side only:
   \${HOME}/dev/rev_harness/harness-rust/target
   This is not adopter-side uninstall state.

7. Semantic database dispose-together (opt-in, destructive):
   scripts/rev-harness-uninstall.sh --semantic                       # preview only
   scripts/rev-harness-uninstall.sh --semantic --apply --confirm-uninstall
   Removes ONLY this project's external semantic DB dir. RSEM-validated and
   active-lock-skipped. Default (no --semantic) never touches the DB.
EOF
}

# ---------------------------------------------------------------------------
# Semantic DB dispose-together (opt-in)
# ---------------------------------------------------------------------------

semantic_die() { printf 'rev-harness-uninstall(--semantic): %s\n' "$*" >&2; exit 1; }

resolve_project_id() {
  local resolver="$SCRIPT_DIR/resolve-semantic-project-id.sh"
  [[ -x "$resolver" ]] || semantic_die "resolver not found or not executable: $resolver"
  local pid
  pid="$(bash "$resolver" --repo-root "$PROJECT_ROOT" --print 2>/dev/null || true)"
  pid="$(printf '%s' "$pid" | tr -d '[:space:]')"
  [[ -n "$pid" ]] || semantic_die "could not resolve project_id for $PROJECT_ROOT"
  # Defense-in-depth: project_id is used as a single path segment.
  case "$pid" in
    */*|*..*|"") semantic_die "refusing unsafe project_id segment: '$pid'" ;;
  esac
  printf '%s' "$pid"
}

semantic_data_dir_for_project() {
  local project_id="$1" data_home
  if [[ -n "${REV_HARNESS_RUST_DB_HOME:-}" ]]; then
    printf '%s/v1/%s' "$REV_HARNESS_RUST_DB_HOME" "$project_id"
    return 0
  fi
  case "$(uname -s)" in
    Darwin)
      printf '%s/Library/Application Support/Revharness/semantic-mcp/v1/%s' "$HOME" "$project_id"
      ;;
    *)
      data_home="${XDG_DATA_HOME:-$HOME/.local/share}"
      printf '%s/Revharness/semantic-mcp/v1/%s' "$data_home" "$project_id"
      ;;
  esac
}

# RSEM marker: SQLite application_id = 0x5253454D ("RSEM") = 1381188941 decimal.
readonly RSEM_APP_ID_DECIMAL=1381188941

# Validate the RSEM application_id of a SQLite DB.
# Returns 0 if RSEM-marked, 1 otherwise (foreign / unreadable / missing).
rsem_validate() {
  local db_path="$1"
  [[ -f "$db_path" ]] || return 1
  command -v sqlite3 >/dev/null 2>&1 || semantic_die "sqlite3 is required to RSEM-validate the DB"
  local app_id
  app_id="$(sqlite3 "file:$db_path?mode=ro" 'PRAGMA application_id;' 2>/dev/null || true)"
  [[ "$app_id" == "$RSEM_APP_ID_DECIMAL" ]]
}

# Liveness detection (FAIL-CLOSED).
#
# Returns 0 ("treat as active, REFUSE to delete") whenever we cannot positively
# prove that NO process is holding the DB. Returns 1 ("provably not in use, safe
# to delete") only when a reliable check ran and found no holder.
#
# Probe order:
#   1. lsof on the DB + -wal + -shm + advisory lock files (works on macOS, where
#      flock is absent by default). If lsof reports ANY process holding ANY of
#      those files → active. This is the same set of files SQLite + the Rust
#      advisory lock keep open while serving.
#   2. flock on the advisory lock file (Linux): if we cannot take an exclusive
#      lock, a server holds it → active.
#
# If NEITHER lsof NOR flock is available, we cannot prove the DB is idle, so we
# FAIL CLOSED (return 0) rather than risk deleting a live, server-held DB.
db_lock_active() {
  local db_path="$1"
  local lock_path="${db_path}.harness-lock"
  local probe_files=(
    "$db_path"
    "${db_path}-wal"
    "${db_path}-shm"
    "$lock_path"
  )

  local probed=false

  # Probe 1: lsof (portable, works on macOS).
  if command -v lsof >/dev/null 2>&1; then
    probed=true
    local f
    for f in "${probe_files[@]}"; do
      [[ -e "$f" ]] || continue
      # lsof exits 0 and prints a line when a process holds the file.
      if lsof -- "$f" >/dev/null 2>&1; then
        return 0  # active: a process holds this file → refuse to delete.
      fi
    done
  fi

  # Probe 2: flock (Linux). Only meaningful if the lock file exists.
  if command -v flock >/dev/null 2>&1; then
    probed=true
    if [[ -f "$lock_path" ]]; then
      if flock -n -x "$lock_path" true 2>/dev/null; then
        : # exclusive lock acquired → no holder via flock.
      else
        return 0  # cannot lock → a server holds it → refuse.
      fi
    fi
  fi

  if [[ "$probed" != true ]]; then
    # Neither lsof nor flock available: we cannot prove the DB is idle.
    # FAIL CLOSED — never delete a possibly-live DB.
    semantic_die "cannot verify DB liveness: neither lsof nor flock is available; refusing to delete $db_path (install lsof or flock, or stop the semantic server first)"
  fi

  # A probe ran and found no holder → provably not in use.
  return 1
}

run_semantic() {
  local project_id db_dir db_path
  project_id="$(resolve_project_id)"
  db_dir="$(semantic_data_dir_for_project "$project_id")"
  db_path="$db_dir/semantic.db"

  local files=(
    "$db_dir/semantic.db"
    "$db_dir/semantic.db-wal"
    "$db_dir/semantic.db-shm"
    "$db_dir/semantic.db.harness-lock"
    "$db_dir/.migration.lock"
  )

  printf 'RevHarness semantic dispose-together (project_id=%s)\n' "$project_id"
  printf 'Target dir: %s\n' "$db_dir"

  if [[ ! -d "$db_dir" ]]; then
    printf 'No semantic DB directory found. Nothing to remove.\n'
    return 0
  fi

  if [[ "$APPLY" != true || "$CONFIRM_UNINSTALL" != true ]]; then
    printf '\nDRY-RUN (no deletion). Would remove:\n'
    local f
    for f in "${files[@]}"; do
      [[ -e "$f" ]] && printf '  %s\n' "$f"
    done
    printf '  %s/   (directory, if empty after the above)\n' "$db_dir"
    printf '\nTo actually delete: --semantic --apply --confirm-uninstall (I-11 double opt-in).\n'
    return 0
  fi

  # APPLY path: RSEM-validate + active-lock-skip BEFORE any removal.
  if ! rsem_validate "$db_path"; then
    semantic_die "refusing to delete: $db_path is not an RSEM-marked managed DB (foreign or missing)"
  fi
  if db_lock_active "$db_path"; then
    semantic_die "refusing to delete: an active server lock is held on $db_path (live session)"
  fi

  local f removed=0
  for f in "${files[@]}"; do
    if [[ -e "$f" ]]; then
      rm -f "$f"
      printf 'removed: %s\n' "$f"
      removed=$((removed + 1))
    fi
  done
  # Remove the now-empty project dir (ignore if non-empty for safety).
  rmdir "$db_dir" 2>/dev/null && printf 'removed dir: %s\n' "$db_dir" || true
  printf 'semantic dispose-together complete (%d file(s) removed).\n' "$removed"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --print-checklist) PRINT_CHECKLIST=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --semantic) SEMANTIC=true; shift ;;
    --confirm-uninstall) CONFIRM_UNINSTALL=true; shift ;;
    --apply)
      APPLY=true
      shift
      ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'rev-harness-uninstall: unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

if [[ "$SEMANTIC" == true ]]; then
  run_semantic
  exit 0
fi

# Without --semantic, --apply remains deferred (legacy behavior preserved).
if [[ "$APPLY" == true ]]; then
  printf 'uninstall --apply: deferred to Phase G+1 (use --semantic --apply --confirm-uninstall for the semantic DB)\n' >&2
  exit 2
fi

if [[ "$PRINT_CHECKLIST" == true && "$JSON_OUTPUT" == true ]]; then
  emit_json
else
  emit_human
fi
