#!/usr/bin/env bash
[ -n "${_SNAPSHOT_DISPATCH_LOADED:-}" ] && return 0; _SNAPSHOT_DISPATCH_LOADED=1

set -uo pipefail

_snapshot_repo_root() {
  if [ -n "${HARNESS_REPO_ROOT:-}" ]; then
    printf '%s\n' "$HARNESS_REPO_ROOT"
    return 0
  fi

  local root=""
  if command -v git >/dev/null 2>&1; then
    root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  fi
  if [ -z "$root" ]; then
    root="$(pwd -P 2>/dev/null || printf '.')"
  fi
  HARNESS_REPO_ROOT="$root"
  export HARNESS_REPO_ROOT
  printf '%s\n' "$HARNESS_REPO_ROOT"
  return 0
}

_snapshot_timestamp() {
  if [ -z "${HARNESS_SNAPSHOT_TS:-}" ]; then
    HARNESS_SNAPSHOT_TS="$(date -u +"%Y%m%d-%H%M%S" 2>/dev/null || printf 'unknown-ts')"
    export HARNESS_SNAPSHOT_TS
  fi
  printf '%s\n' "$HARNESS_SNAPSHOT_TS"
  return 0
}

_snapshot_dir_abs() {
  local root snapshot_dir
  root="$(_snapshot_repo_root)"
  snapshot_dir="${HARNESS_SNAPSHOT_DIR:-.agent/snapshots}"
  case "$snapshot_dir" in
    /*) printf '%s\n' "$snapshot_dir" ;;
    *) printf '%s/%s\n' "$root" "$snapshot_dir" ;;
  esac
  return 0
}

_snapshot_task_id() {
  local task_id="${HARNESS_TASK_ID:-unknown}"
  if [ -z "$task_id" ]; then
    task_id="unknown"
  fi
  case "$task_id" in
    */*|*..*) task_id="unknown" ;;
  esac
  printf '%s\n' "$task_id"
  return 0
}

_snapshot_repo_rel() {
  local input="${1:-}" root rel
  [ -n "$input" ] || return 1
  root="$(_snapshot_repo_root)"
  case "$input" in
    "$root") rel="" ;;
    "$root"/*) rel="${input#"$root"/}" ;;
    /*) return 1 ;;
    *) rel="$input" ;;
  esac
  rel="${rel#./}"
  case "$rel" in
    ""|../*|*/../*|*/..|..) return 1 ;;
  esac
  printf '%s\n' "$rel"
  return 0
}

_snapshot_file_abs() {
  local path="${1:-}" root
  [ -n "$path" ] || return 1
  root="$(_snapshot_repo_root)"
  case "$path" in
    "$root"/*) printf '%s\n' "$path" ;;
    /*) return 1 ;;
    *) printf '%s/%s\n' "$root" "${path#./}" ;;
  esac
  return 0
}

_snapshot_is_denied() {
  local repo_rel_path="${1:-}" denylist pattern old_ifs
  [ -n "$repo_rel_path" ] || return 1
  denylist="${HARNESS_SNAPSHOT_DENYLIST:-*.env:*credential*:secrets/*:*.key:*.pem}"
  old_ifs=$IFS
  IFS=:
  for pattern in $denylist; do
    IFS=$old_ifs
    [ -n "$pattern" ] || { IFS=:; continue; }
    case "$repo_rel_path" in
      $pattern) IFS=$old_ifs; return 0 ;;
    esac
    IFS=:
  done
  IFS=$old_ifs
  return 1
}

_snapshot_sha256() {
  local path="${1:-}"
  [ -f "$path" ] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$path" 2>/dev/null | awk '{print $1}'
    return 0
  fi
  return 1
}

snapshot_file() {
  local event_kind="${1:-}" file_path="${2:-}" repo_rel="" file_abs=""
  local snapshot_root ts task_id dest_dir dest_path
  HARNESS_SNAPSHOT_LAST_REPO_REL=""
  HARNESS_SNAPSHOT_LAST_PATH=""

  case "$event_kind" in
    pre|post|stop) ;;
    *) return 0 ;;
  esac

  repo_rel="$(_snapshot_repo_rel "$file_path" 2>/dev/null || true)"
  [ -n "$repo_rel" ] || return 0
  HARNESS_SNAPSHOT_LAST_REPO_REL="$repo_rel"
  _snapshot_is_denied "$repo_rel" && return 0

  file_abs="$(_snapshot_file_abs "$file_path" 2>/dev/null || true)"
  [ -n "$file_abs" ] || return 0
  [ -f "$file_abs" ] || return 0

  snapshot_root="$(_snapshot_dir_abs)"
  ts="$(_snapshot_timestamp)"
  task_id="$(_snapshot_task_id)"
  dest_path="${snapshot_root}/${ts}/${task_id}/${event_kind}/${repo_rel}"
  dest_dir="${dest_path%/*}"

  mkdir -p "$dest_dir" 2>/dev/null || return 0
  cp -p "$file_abs" "$dest_path" 2>/dev/null || return 0
  HARNESS_SNAPSHOT_LAST_PATH="$dest_path"
  return 0
}

snapshot_index_append() {
  local event="${1:-}" details_json="${2:-}" index_dir index_file ts
  if [ -z "$details_json" ]; then
    details_json="{}"
  fi
  case "$event" in
    pre|post|stop) ;;
    *) return 0 ;;
  esac

  index_dir="$(_snapshot_dir_abs)"
  mkdir -p "$index_dir" 2>/dev/null || return 0
  index_file="${index_dir}/index.jsonl"
  ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null || printf '1970-01-01T00:00:00Z')"
  command -v python3 >/dev/null 2>&1 || return 0

  SNAPSHOT_EVENT="$event" \
  SNAPSHOT_DETAILS_JSON="$details_json" \
  SNAPSHOT_TS="$ts" \
  SNAPSHOT_TASK_ID="${HARNESS_TASK_ID:-unknown}" \
  python3 -c '
import json, os, re, sys
index_path = sys.argv[1]
event = os.environ.get("SNAPSHOT_EVENT") or "unknown"
task_id = os.environ.get("SNAPSHOT_TASK_ID") or "unknown"
try:
    details = json.loads(os.environ.get("SNAPSHOT_DETAILS_JSON") or "{}")
    if not isinstance(details, dict):
        details = {}
except Exception:
    details = {}
sha = details.get("sha256")
if isinstance(sha, str) and not re.fullmatch(r"[0-9a-fA-F]{64}", sha):
    sha = None
elif isinstance(sha, str):
    sha = sha.lower()
else:
    sha = None
row = {"ts": os.environ.get("SNAPSHOT_TS") or "1970-01-01T00:00:00Z", "event": event, "tool": details.get("tool"), "file_path": details.get("file_path"), "task_id": details.get("task_id") or task_id, "snapshot_path": details.get("snapshot_path"), "sha256": sha}
with open(index_path, "a", encoding="utf-8") as fh:
    fh.write(json.dumps(row, separators=(",", ":"), ensure_ascii=True) + "\n")
' "$index_file" 2>/dev/null || return 0
  return 0
}
