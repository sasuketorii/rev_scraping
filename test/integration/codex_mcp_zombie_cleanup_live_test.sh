#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEANUP_SCRIPT="$ROOT_DIR/scripts/cleanup-codex-mcp-zombies.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-mcp-zombie-live.XXXXXX")"
PID1=""
PID2=""

cleanup() {
  if [[ -n "$PID1" ]]; then
    kill "$PID1" >/dev/null 2>&1 || true
  fi
  if [[ -n "$PID2" ]]; then
    kill "$PID2" >/dev/null 2>&1 || true
  fi
  /bin/rm -rf "$TMP_DIR"
}
trap cleanup EXIT

bash -c 'exec -a "npm exec @playwright/mcp@latest" sleep 30' &
PID1=$!
bash -c 'exec -a "node /home/example/.npm/_npx/abcd/node_modules/.bin/playwright-mcp" sleep 30' &
PID2=$!

sleep 1

KILL_JSON="$TMP_DIR/kill.json"
bash "$CLEANUP_SCRIPT" kill --min-age-seconds 0 --pids "$PID1,$PID2" > "$KILL_JSON"

jq -e '.phase == "kill"' "$KILL_JSON" >/dev/null
jq -e '.kill_threshold_seconds == 0' "$KILL_JSON" >/dev/null
jq -e --argjson pid1 "$PID1" --argjson pid2 "$PID2" '(.requested_kill_pids | sort) == ([$pid1, $pid2] | sort)' "$KILL_JSON" >/dev/null
jq -e --argjson pid1 "$PID1" --argjson pid2 "$PID2" '(.terminated_pids | sort) == ([$pid1, $pid2] | sort)' "$KILL_JSON" >/dev/null
jq -e '.failed_signal_pids | length == 0' "$KILL_JSON" >/dev/null
jq -e '.survivor_pids | length == 0' "$KILL_JSON" >/dev/null
jq -e --argjson pid1 "$PID1" --argjson pid2 "$PID2" '.total_matches >= 2 and (.matches | any(.pid == $pid1)) and (.matches | any(.pid == $pid2))' "$KILL_JSON" >/dev/null
jq -e --argjson pid1 "$PID1" --argjson pid2 "$PID2" '.before.total_matches >= 2 and (.before.matches | any(.pid == $pid1)) and (.before.matches | any(.pid == $pid2))' "$KILL_JSON" >/dev/null
jq -e --argjson pid1 "$PID1" --argjson pid2 "$PID2" '((.after.matches | any(.pid == $pid1)) | not) and ((.after.matches | any(.pid == $pid2)) | not)' "$KILL_JSON" >/dev/null

if kill -0 "$PID1" 2>/dev/null; then
  printf 'FAIL: PID1 still alive after cleanup\n' >&2
  exit 1
fi
if kill -0 "$PID2" 2>/dev/null; then
  printf 'FAIL: PID2 still alive after cleanup\n' >&2
  exit 1
fi

printf 'PASS: codex_mcp_zombie_cleanup_live\n'
