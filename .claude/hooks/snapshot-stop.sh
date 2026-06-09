#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P 2>/dev/null || pwd -P)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/scripts/snapshot-dispatch.sh" 2>/dev/null || exit 0

cat >/dev/null 2>/dev/null || true

task_id="${HARNESS_TASK_ID:-unknown}"
[ -n "$task_id" ] || task_id="unknown"
repo_root="$(_snapshot_repo_root)"
lock_file="${repo_root}/.agent/state/locks/${task_id}.after.sha256"

append_stop_row() {
  local rel_path="${1:-}" sha="${2:-}" snap_path="${3:-}"
  local details
  details="$(
    TOOL="Stop" FILE_PATH="$rel_path" TASK_ID="$task_id" SNAPSHOT_PATH="$snap_path" SHA256="$sha" python3 -c '
import json, os
print(json.dumps({
    "tool": os.environ.get("TOOL") or None,
    "file_path": os.environ.get("FILE_PATH") or None,
    "task_id": os.environ.get("TASK_ID") or "unknown",
    "snapshot_path": os.environ.get("SNAPSHOT_PATH") or None,
    "sha256": os.environ.get("SHA256") or None,
}, separators=(",", ":")))
' 2>/dev/null || printf '{}'
  )"
  snapshot_index_append stop "$details"
  return 0
}

if [ ! -r "$lock_file" ]; then
  append_stop_row "" ""
  exit 0
fi

while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    *"  "*) ;;
    *) continue ;;
  esac
  sha="${line%%  *}"
  path="${line#*  }"
  [ -n "$path" ] || continue
  repo_rel="$(_snapshot_repo_rel "$path" 2>/dev/null || true)"
  [ -n "$repo_rel" ] || continue
  _snapshot_is_denied "$repo_rel" && continue
  snapshot_file stop "$path"
  append_stop_row "$repo_rel" "$sha" "${HARNESS_SNAPSHOT_LAST_PATH:-}"
done < "$lock_file"

exit 0
