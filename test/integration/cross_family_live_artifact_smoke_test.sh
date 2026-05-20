#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SMOKE="$PROJECT_ROOT/scripts/cross-family-live-artifact-smoke.sh"

TMP_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}" 2>/dev/null || true
  cleanup_project_artifacts
}

cleanup_project_artifacts() {
  /bin/rm -rf \
    "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke" \
    "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-missing" \
    "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-invalid" \
    "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-failure" \
    "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-residual" \
    "$PROJECT_ROOT/workspace/live-artifact-smoke" \
    "$PROJECT_ROOT/workspace/live-artifact-smoke-missing" \
    "$PROJECT_ROOT/workspace/live-artifact-smoke-failure" \
    "$PROJECT_ROOT/workspace/live-artifact-smoke-residual" \
    2>/dev/null || true
}
trap cleanup EXIT

write_executable() {
  local path="$1"
  shift
  printf '%s\n' "$@" > "$path"
  chmod +x "$path"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/cross-family-live-artifact-smoke.XXXXXX")"
cleanup_project_artifacts
stub_root="$TMP_ROOT/stubs"
mkdir -p "$stub_root" "$TMP_ROOT/repo/.claude/tmp/live-artifact-smoke" "$TMP_ROOT/repo/workspace/live-artifact-smoke"
empty_process_snapshot="$TMP_ROOT/empty-process-snapshot.txt"
: > "$empty_process_snapshot"

stub_codex_cli="$stub_root/codex-cli"
stub_claude_cli="$stub_root/claude-cli"
write_executable "$stub_codex_cli" \
  '#!/usr/bin/env bash' \
  'printf "stub codex cli\n"'
write_executable "$stub_claude_cli" \
  '#!/usr/bin/env bash' \
  'printf "stub claude cli\n"'

stub_codex_wrapper="$stub_root/codex-wrapper"
write_executable "$stub_codex_wrapper" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'artifact="$(awk '"'"'match($0, /\.claude\/tmp\/[^` ]+\/codex-worker-artifact\.md/) { print substr($0, RSTART, RLENGTH); exit }'"'"')"' \
  '[[ -n "$artifact" ]] || exit 10' \
  'mkdir -p "$(dirname "$artifact")"' \
  'printf "%s\n" \' \
  '  "provider: codex" \' \
  '  "model_family: gpt" \' \
  '  "role: coder" \' \
  '  "status: completed" \' \
  '  "task: tiny deterministic shell bug proposal" \' \
  '  "proposed_fix: replace a fragile shell command with a checked command" \' \
  '  "checks:" \' \
  '  "- bash -n path/to/script.sh" \' \
  '  "- git diff --check -- path/to/script.sh" \' \
  '  "handoff_to: opus-reviewer" > "$artifact"' \
  'printf "stub codex wrapper completed\n"'

stub_codex_wrapper_fail="$stub_root/codex-wrapper-fail"
write_executable "$stub_codex_wrapper_fail" \
  '#!/usr/bin/env bash' \
  'cat >/dev/null' \
  'exit 42'

stub_claude_wrapper="$stub_root/claude-wrapper"
write_executable "$stub_claude_wrapper" \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'input=""' \
  'output=""' \
  'while [[ $# -gt 0 ]]; do' \
  '  case "$1" in' \
  '    --input)' \
  '      input="$2"' \
  '      shift 2' \
  '      ;;' \
  '    --output)' \
  '      output="$2"' \
  '      shift 2' \
  '      ;;' \
  '    *)' \
  '      shift' \
  '      ;;' \
  '  esac' \
  'done' \
  '[[ -n "$input" && -n "$output" ]] || exit 11' \
  'artifact="$(awk '"'"'match($0, /\.claude\/tmp\/[^` ]+\/opus-reviewer-artifact\.md/) { print substr($0, RSTART, RLENGTH); exit }'"'"' "$input")"' \
  'reviewed="$(awk '"'"'match($0, /\.claude\/tmp\/[^` ]+\/codex-worker-artifact\.md/) { print substr($0, RSTART, RLENGTH); exit }'"'"' "$input")"' \
  '[[ -n "$artifact" && -n "$reviewed" ]] || exit 12' \
  'mkdir -p "$(dirname "$artifact")"' \
  'printf "%s\n" \' \
  '  "provider: claude" \' \
  '  "model_family: opus" \' \
  '  "role: reviewer" \' \
  '  "reviewed_artifact: $reviewed" \' \
  '  "verdict: LGTM" \' \
  '  "findings: none" \' \
  '  "live_smoke_result: codex_artifact_received" \' \
  '  "handoff_to: orchestrator" > "$artifact"' \
  'printf "stub opus wrapper completed\n" > "$output"'

pushd "$PROJECT_ROOT" >/dev/null
out="$TMP_ROOT/report.json"
REV_HARNESS_CODEX_WRAPPER="$stub_codex_wrapper" \
REV_HARNESS_CLAUDE_WRAPPER="$stub_claude_wrapper" \
REV_HARNESS_PROCESS_SNAPSHOT_FILE="$empty_process_snapshot" \
  bash "$SMOKE" \
    --json \
    --artifact-root .claude/tmp/live-artifact-smoke \
    --workspace workspace/live-artifact-smoke \
    --codex-cli "$stub_codex_cli" \
    --claude-cli "$stub_claude_cli" > "$out"
popd >/dev/null

jq -e '
  .schema_version == "rev-harness-cross-family-live-artifact-smoke/v1"
  and .status == "PASS"
  and (.violations | length) == 0
' "$out" >/dev/null || { cat "$out" >&2; fail "live artifact smoke report did not pass"; }

artifact_root="$(jq -r '.artifact_root' "$out")"
[[ "$artifact_root" == ".claude/tmp/live-artifact-smoke" ]] || fail "unexpected artifact root"

jq -e '
  .status == "PASS"
  and .codex_cli.available == true
  and .claude_cli.available == true
  and .completion_claim_allowed == false
  and .live_execution_enabled == false
' "$PROJECT_ROOT/$artifact_root/preflight.json" >/dev/null || fail "preflight invariant failed"

jq -e '
  .workers[0].status == "completed"
  and .workers[1].verdict == "LGTM"
  and .direct_long_lived_chat == false
  and .orchestrator.acceptance == "PASS"
' "$PROJECT_ROOT/$artifact_root/packet.json" >/dev/null || fail "packet invariant failed"

jq -e '
  .status == "PASS"
  and .completion_allowed == true
  and (.violations | length) == 0
' "$PROJECT_ROOT/$artifact_root/lease-guard.json" >/dev/null || fail "lease guard invariant failed"

[[ ! -s "$PROJECT_ROOT/$artifact_root/residual-processes.txt" ]] \
  || fail "residual process report should be empty"

missing_out="$TMP_ROOT/missing-report.json"
if REV_HARNESS_CODEX_WRAPPER="$stub_codex_wrapper" \
  REV_HARNESS_CLAUDE_WRAPPER="$stub_claude_wrapper" \
  REV_HARNESS_PROCESS_SNAPSHOT_FILE="$empty_process_snapshot" \
    bash "$SMOKE" \
      --json \
      --artifact-root .claude/tmp/live-artifact-smoke-missing \
      --workspace workspace/live-artifact-smoke-missing \
      --codex-cli "$stub_codex_cli" \
      --claude-cli "$TMP_ROOT/missing-claude" > "$missing_out"; then
  fail "missing Claude CLI should block"
fi
jq -e '
  .status == "BLOCK"
  and (.violations | map(select(contains("Claude CLI"))) | length) > 0
' "$missing_out" >/dev/null || { cat "$missing_out" >&2; fail "missing CLI block report did not match"; }

invalid_out="$TMP_ROOT/invalid-path-report.json"
if REV_HARNESS_CODEX_WRAPPER="$stub_codex_wrapper" \
  REV_HARNESS_CLAUDE_WRAPPER="$stub_claude_wrapper" \
  REV_HARNESS_PROCESS_SNAPSHOT_FILE="$empty_process_snapshot" \
    bash "$SMOKE" \
      --json \
      --artifact-root .claude/tmp/live-artifact-smoke-invalid \
      --workspace ../workspace-escape \
      --codex-cli "$stub_codex_cli" \
      --claude-cli "$stub_claude_cli" > "$invalid_out"; then
  fail "invalid workspace path should block"
fi
jq -e '
  .status == "BLOCK"
  and (.violations | map(select(contains("workspace must stay under workspace"))) | length) > 0
' "$invalid_out" >/dev/null || { cat "$invalid_out" >&2; fail "invalid path block report did not match"; }
[[ ! -e "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-invalid" ]] \
  || fail "invalid path should not create artifact root before validation"

failure_out="$TMP_ROOT/failure-report.json"
if REV_HARNESS_CODEX_WRAPPER="$stub_codex_wrapper_fail" \
  REV_HARNESS_CLAUDE_WRAPPER="$stub_claude_wrapper" \
  REV_HARNESS_PROCESS_SNAPSHOT_FILE="$empty_process_snapshot" \
    bash "$SMOKE" \
      --json \
      --artifact-root .claude/tmp/live-artifact-smoke-failure \
      --workspace workspace/live-artifact-smoke-failure \
      --codex-cli "$stub_codex_cli" \
      --claude-cli "$stub_claude_cli" > "$failure_out"; then
  fail "failed Codex wrapper should block"
fi
jq -e '
  .status == "BLOCK"
  and (.violations | map(select(contains("Codex worker failed or timed out"))) | length) > 0
' "$failure_out" >/dev/null || { cat "$failure_out" >&2; fail "failure block report did not match"; }
[[ -f "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-failure/residual-processes.txt" ]] \
  || fail "failure path should still run residual scan"

residual_snapshot="$TMP_ROOT/residual-process-snapshot.txt"
printf '%s\n' '123 1 123 S 00:01 claude --print --model opus --session-id residual-smoke' > "$residual_snapshot"
residual_out="$TMP_ROOT/residual-report.json"
if REV_HARNESS_CODEX_WRAPPER="$stub_codex_wrapper" \
  REV_HARNESS_CLAUDE_WRAPPER="$stub_claude_wrapper" \
  REV_HARNESS_PROCESS_SNAPSHOT_FILE="$residual_snapshot" \
    bash "$SMOKE" \
      --json \
      --artifact-root .claude/tmp/live-artifact-smoke-residual \
      --workspace workspace/live-artifact-smoke-residual \
      --codex-cli "$stub_codex_cli" \
      --claude-cli "$stub_claude_cli" > "$residual_out"; then
  fail "residual Claude process should block"
fi
jq -e '
  .status == "BLOCK"
  and (.violations | map(select(contains("residual Codex/Opus"))) | length) > 0
' "$residual_out" >/dev/null || { cat "$residual_out" >&2; fail "residual block report did not match"; }
grep -q 'claude --print --model opus' "$PROJECT_ROOT/.claude/tmp/live-artifact-smoke-residual/residual-processes.txt" \
  || fail "residual report should include claude --print process"

printf 'PASS: cross_family_live_artifact_smoke_test\n'
