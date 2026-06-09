#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P 2>/dev/null || pwd -P)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P 2>/dev/null || pwd -P)"
# shellcheck disable=SC1090
source "${REPO_ROOT}/scripts/snapshot-dispatch.sh" 2>/dev/null || exit 0

payload="$(cat 2>/dev/null || true)"
parsed="$(
  printf '%s' "$payload" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    data = {}
tool = data.get("tool_name") or data.get("tool") or ""
tool_input = data.get("tool_input") if isinstance(data.get("tool_input"), dict) else {}
path = tool_input.get("file_path") or data.get("file_path") or tool_input.get("path") or ""
print(tool)
print(path)
' 2>/dev/null || true
)"
tool="$(printf '%s\n' "$parsed" | sed -n '1p')"
file_path="$(printf '%s\n' "$parsed" | sed -n '2p')"

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit) ;;
  *) exit 0 ;;
esac
[ -n "$file_path" ] || exit 0

repo_rel="$(_snapshot_repo_rel "$file_path" 2>/dev/null || true)"
[ -n "$repo_rel" ] || exit 0
_snapshot_is_denied "$repo_rel" && exit 0

snapshot_path=""
sha256=""
file_abs="$(_snapshot_file_abs "$file_path" 2>/dev/null || true)"
if [ -n "$file_abs" ] && [ -f "$file_abs" ]; then
  snapshot_file pre "$file_path"
  snapshot_path="${HARNESS_SNAPSHOT_LAST_PATH:-}"
  sha256="$(_snapshot_sha256 "$file_abs" 2>/dev/null || true)"
fi

details="$(
  TOOL="$tool" FILE_PATH="$repo_rel" TASK_ID="${HARNESS_TASK_ID:-unknown}" \
  SNAPSHOT_PATH="$snapshot_path" SHA256="$sha256" python3 -c '
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
snapshot_index_append pre "$details"
exit 0
