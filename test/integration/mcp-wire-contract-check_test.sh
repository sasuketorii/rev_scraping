#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
HARNESS_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd -P)"
CHECKER="$HARNESS_ROOT/scripts/ci/mcp-wire-contract-check.sh"

make_harness() {
  local root="$1"
  root="$(cd "$root" && pwd -P)"
  mkdir -p "$root/scripts/ci" "$root/scripts" "$root/.claude" "$root/.codex"
  cp "$CHECKER" "$root/scripts/ci/mcp-wire-contract-check.sh"
  chmod 755 "$root/scripts/ci/mcp-wire-contract-check.sh"
  cp "$HARNESS_ROOT/.mcp.json.template" "$root/.mcp.json.template"
  cat > "$root/scripts/launch-semantic-mcp.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod 755 "$root/scripts/launch-semantic-mcp.sh"
  cat > "$root/.claude/settings.json" <<JSON
{"mcpServers":{"semantic-mcp":{"command":"$root/scripts/launch-semantic-mcp.sh","args":[]}}}
JSON
  cat > "$root/.codex/config.toml" <<TOML
[mcp_servers.semantic-mcp]
command = "$root/scripts/launch-semantic-mcp.sh"
args = []
TOML
  cat > "$root/scripts/init-project.sh" <<'SH'
#!/usr/bin/env bash
target=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --target) target="$2"; shift 2 ;;
    --self-test) shift ;;
    *) shift ;;
  esac
done
[ -n "$target" ] || exit 0
mkdir -p "$target/.claude"
printf '{}\n' > "$target/.claude/settings.json"
SH
  chmod 755 "$root/scripts/init-project.sh"
  cat > "$root/scripts/install-rev-harness-mcp.sh" <<'SH'
#!/usr/bin/env bash
out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-fixture) out="$2"; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$out" ] || exit 2
jq -n --arg cmd "$(cd "$(dirname "$0")/.." && pwd -P)/scripts/launch-semantic-mcp.sh" '{"mcpServers":{"semantic-mcp":{"command":$cmd,"args":[]}}}' > "$out"
SH
  chmod 755 "$root/scripts/install-rev-harness-mcp.sh"
  cp "$root/scripts/install-rev-harness-mcp.sh" "$root/scripts/rev-harness-mcp-wire.sh"
  chmod 755 "$root/scripts/rev-harness-mcp-wire.sh"
}

run_case() {
  local case_id="$1" input="$2" expected="$3" mode_root test_file warn_out strict_out
  mode_root="$(mktemp -d "${TMPDIR:-/tmp}/mcp-wire-case.XXXXXX")"
  mode_root="$(cd "$mode_root" && pwd -P)"
  output_root="$(mktemp -d "${TMPDIR:-/tmp}/mcp-wire-output.XXXXXX")"
  make_harness "$mode_root"
  mkdir -p "$mode_root/cases"
  test_file="$mode_root/cases/case.txt"
  printf '%s\n' "$input" > "$test_file"

  set +e
  bash "$mode_root/scripts/ci/mcp-wire-contract-check.sh" >"$output_root/warn.stdout" 2>"$output_root/warn.stderr"
  warn_status=$?
  bash "$mode_root/scripts/ci/mcp-wire-contract-check.sh" --strict >"$output_root/strict.stdout" 2>"$output_root/strict.stderr"
  strict_status=$?
  set -e

  [[ "$warn_status" -eq 0 ]] || fail "case $case_id failed: warn-only exited $warn_status"
  warn_out="$(cat "$output_root/warn.stdout")"
  strict_out="$(cat "$output_root/strict.stdout")"
  if [[ "$expected" == "FLAGGED" ]]; then
    printf '%s\n' "$warn_out" | jq -e 'length > 0' >/dev/null || fail "case $case_id failed: warn-only did not report finding"
    grep -q '^WARN:' "$output_root/warn.stderr" || fail "case $case_id failed: warn-only did not print WARN"
    [[ "$strict_status" -eq 1 ]] || fail "case $case_id failed: strict exited $strict_status"
    printf '%s\n' "$strict_out" | jq -e 'length > 0' >/dev/null || fail "case $case_id failed: strict did not report finding"
    grep -q '^ERROR:' "$output_root/strict.stderr" || fail "case $case_id failed: strict did not print ERROR"
  else
    printf '%s\n' "$warn_out" | jq -e 'length == 0' >/dev/null || fail "case $case_id failed: warn-only reported unexpected finding"
    [[ ! -s "$output_root/warn.stderr" ]] || fail "case $case_id failed: warn-only printed stderr"
    [[ "$strict_status" -eq 0 ]] || fail "case $case_id failed: strict exited $strict_status"
    printf '%s\n' "$strict_out" | jq -e 'length == 0' >/dev/null || fail "case $case_id failed: strict reported unexpected finding"
    [[ ! -s "$output_root/strict.stderr" ]] || fail "case $case_id failed: strict printed stderr"
  fi
  rm -rf "$mode_root" >/dev/null 2>&1 || true
  rm -rf "$output_root" >/dev/null 2>&1 || true
  printf 'PASS: case %s\n' "$case_id"
}

run_case 1 '"semantic": {' FLAGGED
run_case 2 '"semantic-mcp": {' OK
run_case 3 '"./scripts/launch-semantic-mcp.sh"' FLAGGED
run_case 4 '"scripts/launch-semantic-mcp.sh"' FLAGGED
run_case 5 './scripts/launch-semantic-mcp.sh' FLAGGED
run_case 6 '/Users/x/dev/r/scripts/launch-semantic-mcp.sh' OK # rev-harness-path-leak-guard: allow
run_case 7 '"/Users/x/dev/r/scripts/launch-semantic-mcp.sh"' OK # rev-harness-path-leak-guard: allow
run_case 8 '$HARNESS_ROOT/scripts/launch-semantic-mcp.sh' FLAGGED
run_case 9 '../foo/scripts/launch-semantic-mcp.sh' FLAGGED
run_case 10 'cp /abs/scripts/launch-semantic-mcp.sh ./scripts/launch-semantic-mcp.sh' FLAGGED
run_case 11 'process.env.SEMANTIC_MCP_PROJECT_ID' FLAGGED
run_case 12 '"semantic": { # rev-harness-i13: allow' OK

root="$(mktemp -d "${TMPDIR:-/tmp}/mcp-wire-case.XXXXXX")"
root="$(cd "$root" && pwd -P)"
output_root="$(mktemp -d "${TMPDIR:-/tmp}/mcp-wire-output.XXXXXX")"
make_harness "$root"
mkdir -p "$root/test/fixtures"
printf '%s\n' '"semantic": {' > "$root/test/fixtures/case.txt"
set +e
bash "$root/scripts/ci/mcp-wire-contract-check.sh" >"$output_root/warn.stdout" 2>"$output_root/warn.stderr"
warn_status=$?
bash "$root/scripts/ci/mcp-wire-contract-check.sh" --strict >"$output_root/strict.stdout" 2>"$output_root/strict.stderr"
strict_status=$?
set -e
[[ "$warn_status" -eq 0 ]] || fail "case 13 failed: warn-only exited $warn_status"
jq -e 'length == 0' "$output_root/warn.stdout" >/dev/null || fail "case 13 failed: warn-only reported unexpected finding"
[[ ! -s "$output_root/warn.stderr" ]] || fail "case 13 failed: warn-only printed stderr"
[[ "$strict_status" -eq 0 ]] || fail "case 13 failed: strict exited $strict_status"
jq -e 'length == 0' "$output_root/strict.stdout" >/dev/null || fail "case 13 failed: strict reported unexpected finding"
[[ ! -s "$output_root/strict.stderr" ]] || fail "case 13 failed: strict printed stderr"
rm -rf "$root" >/dev/null 2>&1 || true
rm -rf "$output_root" >/dev/null 2>&1 || true
printf 'PASS: case 13\n'
