#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLEANUP_SCRIPT="$ROOT_DIR/scripts/cleanup-codex-mcp-zombies.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-mcp-zombie-contract.XXXXXX")"
WATCHDOG_PID=""
TEST_PID="$$"

cleanup() {
  if [[ -n "$WATCHDOG_PID" ]]; then
    kill "$WATCHDOG_PID" 2>/dev/null || true
  fi
  /bin/rm -rf "$TMP_DIR"
}

timeout_diagnostics() {
  local ps_snapshot="$TMP_DIR/timeout-ps.txt"
  printf 'FAIL: codex_mcp_zombie_cleanup_contract timed out after %s seconds\n' "${CODEX_MCP_ZOMBIE_CONTRACT_TIMEOUT_SECONDS:-30}" >&2
  ps -Ao pid=,ppid=,stat=,etime=,command= > "$ps_snapshot" 2>/dev/null || true
  if [[ -s "$ps_snapshot" ]]; then
    printf 'diagnostic: matching process snapshot follows\n' >&2
    awk '/codex_mcp_zombie_cleanup_contract_test|cleanup-codex-mcp-zombies|jq/ { print }' "$ps_snapshot" >&2 || true
  fi
  exit 124
}

trap cleanup EXIT
trap timeout_diagnostics ALRM

(
  sleep "${CODEX_MCP_ZOMBIE_CONTRACT_TIMEOUT_SECONDS:-30}"
  kill -ALRM "$TEST_PID" 2>/dev/null || true
) &
WATCHDOG_PID="$!"

FIXTURE="$TMP_DIR/ps_fixture.txt"

printf '%s\n' \
  '100 1 82000 01:20:00 npm exec @playwright/mcp@latest' \
  '101 100 91000 01:20:00 node /home/example/.npm/_npx/abcd/node_modules/.bin/playwright-mcp' \
  '102 1 19000 01:20:00 ./Codex Computer Use.app/Contents/MacOS/SkyComputerUseClient mcp' \
  '103 1 9000 01:20:00 ~/dev/agent_base/harness-rust/target/debug/semantic-mcp --project-id agent_base-e911f375a31a' \
  '104 1 6000 00:01:00 /Applications/Codex.app/Contents/MacOS/Codex' \
  '105 1 21000 00:01:00 node /home/example/.npm/_npx/recent/node_modules/.bin/playwright-mcp' \
  '106 1 31000 01:20:00 npm exec @chrome-devtools/mcp@latest' \
  > "$FIXTURE"

REPORT_JSON="$TMP_DIR/report.json"
REPORT_WITH_SEMANTIC_JSON="$TMP_DIR/report_with_semantic.json"
DRY_RUN_JSON="$TMP_DIR/kill_dry_run.json"

bash "$CLEANUP_SCRIPT" report --ps-file "$FIXTURE" > "$REPORT_JSON"
jq -e '.counts.playwright_mcp_node == 2' "$REPORT_JSON" >/dev/null
jq -e '.counts.npm_exec_playwright_mcp == 1' "$REPORT_JSON" >/dev/null
jq -e '.counts.skycomputeruse_mcp == 1' "$REPORT_JSON" >/dev/null
jq -e '.counts.chrome_devtools_mcp == 1' "$REPORT_JSON" >/dev/null
jq -e '.counts.semantic_mcp == 0' "$REPORT_JSON" >/dev/null
jq -e '.total_matches == 5' "$REPORT_JSON" >/dev/null

bash "$CLEANUP_SCRIPT" report --ps-file "$FIXTURE" --include-semantic > "$REPORT_WITH_SEMANTIC_JSON"
jq -e '.counts.semantic_mcp == 1' "$REPORT_WITH_SEMANTIC_JSON" >/dev/null
jq -e '.total_matches == 6' "$REPORT_WITH_SEMANTIC_JSON" >/dev/null

bash "$CLEANUP_SCRIPT" kill --dry-run --ps-file "$FIXTURE" > "$DRY_RUN_JSON"
jq -e '.phase == "kill-dry-run"' "$DRY_RUN_JSON" >/dev/null
jq -e '.kill_threshold_seconds == 600' "$DRY_RUN_JSON" >/dev/null
jq -e '.would_kill_pids | length == 4' "$DRY_RUN_JSON" >/dev/null
jq -e '.would_kill_pids | join(",") == "100,101,102,106"' "$DRY_RUN_JSON" >/dev/null
jq -e '.terminated_pids | length == 0' "$DRY_RUN_JSON" >/dev/null

if bash "$CLEANUP_SCRIPT" kill --ps-file "$FIXTURE" --pids 100 >/dev/null 2>&1; then
  printf 'FAIL: live kill unexpectedly accepted --ps-file\n' >&2
  exit 1
fi

printf 'PASS: codex_mcp_zombie_cleanup_contract\n'
