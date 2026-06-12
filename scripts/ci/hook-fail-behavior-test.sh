#!/usr/bin/env bash
set -euo pipefail

# Exit codes:
# 0 pass, 1 assertion failure, 2 usage error, 3 environment failure.

usage() {
  printf '%s\n' \
    'Usage:' \
    '  hook-fail-behavior-test.sh --post-tool-use --no-semantic'
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

usage_error() {
  usage >&2
  exit 2
}

env_fail() {
  printf 'ENV: %s\n' "$*" >&2
  exit 3
}

count_lines() {
  local file_path="$1"
  if [[ ! -f "$file_path" ]]; then
    printf '0\n'
    return 0
  fi
  wc -l < "$file_path" | tr -d '[:space:]'
}

now_ms() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

write_hostile_binary() {
  local bin_dir="$1"
  local binary_name="$2"
  local marker_path="${bin_dir}/${binary_name}.marker"

  mkdir -p "$bin_dir"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'echo %q >&2\n' "hostile ${binary_name} executed"
    printf ': > %q\n' "$marker_path"
    printf '%s\n' 'exit 99'
  } > "$bin_dir/$binary_name"
  chmod +x "$bin_dir/$binary_name"
}

assert_hostile_not_executed() {
  local bin_dir="$1"
  local binary_name="$2"
  [[ ! -e "$bin_dir/${binary_name}.marker" ]] \
    || fail "hostile ${binary_name} binary executed unexpectedly"
}

assert_jsonl_selects() {
  local filter="$1"
  local file_path="$2"
  jq -e "$filter" "$file_path" >/dev/null || fail "jq filter did not match $file_path: $filter"
}

POST_TOOL_USE=0
NO_SEMANTIC=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --post-tool-use)
      POST_TOOL_USE=1
      shift
      ;;
    --no-semantic)
      NO_SEMANTIC=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage_error
      ;;
  esac
done

[[ "$POST_TOOL_USE" -eq 1 && "$NO_SEMANTIC" -eq 1 ]] || usage_error

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
[[ -x "$REPO_ROOT/.claude/hooks/codex-review-hook.sh" ]] \
  || env_fail "hook entrypoint is missing or not executable"
[[ -x "$REPO_ROOT/scripts/semantic-review-queue.sh" ]] \
  || env_fail "queue helper is missing or not executable"
command -v jq >/dev/null 2>&1 || env_fail "jq is required"
[[ -x /usr/bin/perl ]] || env_fail "/usr/bin/perl is required for timing"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/hook_fail_behavior.XXXXXX")"
trap '/bin/rm -rf "$tmpdir"' EXIT

hook_repo="$tmpdir/hook_repo"
hostile_dir="$tmpdir/hostile-bin"
docs_stdout="$tmpdir/docs.stdout"
docs_stderr="$tmpdir/docs.stderr"
docs_warm_stdout="$tmpdir/docs-warm.stdout"
docs_warm_stderr="$tmpdir/docs-warm.stderr"
code_stdout="$tmpdir/code.stdout"
code_stderr="$tmpdir/code.stderr"
semantic_stdout="$tmpdir/inherited-semantic.stdout"
semantic_stderr="$tmpdir/inherited-semantic.stderr"
outside_stdout="$tmpdir/outside.stdout"
outside_stderr="$tmpdir/outside.stderr"
bad_pid_stdout="$tmpdir/bad-project-id.stdout"
bad_pid_stderr="$tmpdir/bad-project-id.stderr"
missing_stdout="$tmpdir/missing-helper.stdout"
missing_stderr="$tmpdir/missing-helper.stderr"
noexec_stdout="$tmpdir/noexec-helper.stdout"
noexec_stderr="$tmpdir/noexec-helper.stderr"
docs_start=""
docs_end=""
docs_elapsed_ms=""

mkdir -p \
  "$hook_repo/.claude/hooks" \
  "$hook_repo/.claude/tmp" \
  "$hook_repo/.shared" \
  "$hook_repo/scripts" \
  "$hook_repo/docs" \
  "$hook_repo/src"

/bin/cp -p "$REPO_ROOT/.claude/hooks/codex-review-hook.sh" "$hook_repo/.claude/hooks/codex-review-hook.sh"
/bin/cp -p "$REPO_ROOT/scripts/semantic-review-queue.sh" "$hook_repo/scripts/semantic-review-queue.sh"
/bin/cp -p "$REPO_ROOT/scripts/resolve-semantic-project-id.sh" "$hook_repo/scripts/resolve-semantic-project-id.sh"
/bin/cp -p "$REPO_ROOT/scripts/project-id.sh" "$hook_repo/scripts/project-id.sh"
/bin/cp -p "$REPO_ROOT/.shared/project_id" "$hook_repo/.shared/project_id"
: > "$hook_repo/docs/readme.md"
: > "$hook_repo/src/main.rs"
: > "$hook_repo/src/lib.rs"
: > "$hook_repo/src/other.rs"

write_hostile_binary "$hostile_dir" cargo
write_hostile_binary "$hostile_dir" semantic-mcp
write_hostile_binary "$hostile_dir" tree-sitter-index

state_jsonl="$hook_repo/.agent/state/review_queue/events.jsonl"
metrics_jsonl="$hook_repo/.agent/metrics/review_queue_events.jsonl"
export_json="$hook_repo/.claude/tmp/review_queue.json"

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/docs/readme.md" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$docs_warm_stdout" 2>"$docs_warm_stderr" \
  || fail "docs file hook run should skip cleanly"
[[ ! -s "$docs_warm_stdout" ]] || fail "docs warm hook run should stay silent on stdout"
[[ ! -f "$state_jsonl" ]] || fail "docs warm hook run should not enqueue"

docs_start="$(now_ms)"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/docs/readme.md" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    REVHARNESS_REVIEW_QUEUE_BACKEND=core \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$docs_stdout" 2>"$docs_stderr" \
  || fail "docs file timed hook run should skip cleanly"
docs_end="$(now_ms)"
docs_elapsed_ms="$(( docs_end - docs_start ))"

[[ ! -s "$docs_stdout" ]] || fail "docs timed hook run should stay silent on stdout"
[[ ! -f "$state_jsonl" ]] || fail "docs timed hook run should not enqueue"
assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/main.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
    unset REVHARNESS_REVIEW_QUEUE_BACKEND
    ./.claude/hooks/codex-review-hook.sh
  ) >"$code_stdout" 2>"$code_stderr" \
  || fail "code file hook run should enqueue through the core backend"

[[ ! -s "$code_stdout" ]] || fail "code hook run should stay silent on stdout"
[[ -f "$state_jsonl" ]] || fail "code hook run did not create core JSONL state"
assert_jsonl_selects 'select(.op == "enqueue" and .file_path == "src/main.rs" and .source == "hook")' "$state_jsonl"
[[ -f "$export_json" ]] || fail "code hook run did not create compatibility export"
jq -e '.pending_review == true and (.changed_files | index("src/main.rs")) != null' "$export_json" >/dev/null \
  || fail "compatibility export does not include src/main.rs"
[[ -f "$metrics_jsonl" ]] || fail "code hook run did not create metrics"
assert_jsonl_selects 'select(.event == "enqueue-ok" and .backend == "core" and .file_path == "src/main.rs")' "$metrics_jsonl"
assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/other.rs" \
  | (
    cd "$hook_repo"
    export REVHARNESS_REVIEW_QUEUE_BACKEND=semantic
    PATH="$hostile_dir:$PATH" \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$semantic_stdout" 2>"$semantic_stderr" \
  || fail "inherited semantic backend hook run should enqueue through the pinned core backend"

[[ ! -s "$semantic_stdout" ]] || fail "inherited semantic hook run should stay silent on stdout"
assert_jsonl_selects 'select(.op == "enqueue" and .file_path == "src/other.rs" and .source == "hook")' "$state_jsonl"
assert_jsonl_selects 'select(.event == "enqueue-ok" and .backend == "core" and .file_path == "src/other.rs")' "$metrics_jsonl"
assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

outside_file="$tmpdir/outside.rs"
: > "$outside_file"
events_before="$(count_lines "$state_jsonl")"
printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$outside_file" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$outside_stdout" 2>"$outside_stderr" \
  || fail "repo-outside hook run should skip cleanly"
events_after="$(count_lines "$state_jsonl")"
[[ "$events_after" == "$events_before" ]] || fail "repo-outside file should not enqueue"
grep -Fq -- "Skipping file outside repo: $outside_file" "$outside_stderr" \
  || fail "repo-outside skip should be logged"

printf 'bad\nid\n' > "$hook_repo/.shared/project_id"
if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/lib.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$bad_pid_stdout" 2>"$bad_pid_stderr"; then
  fail "malformed project_id should fail closed for enqueue-eligible files"
fi
grep -Eq 'project_id|Failed to enqueue DB review queue item' "$bad_pid_stderr" \
  || fail "malformed project_id failure should be observable on stderr"
/bin/cp -p "$REPO_ROOT/.shared/project_id" "$hook_repo/.shared/project_id"

/bin/mv "$hook_repo/scripts/semantic-review-queue.sh" "$hook_repo/scripts/semantic-review-queue.sh.missing"
if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/lib.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$missing_stdout" 2>"$missing_stderr"; then
  fail "missing queue helper should fail closed for enqueue-eligible files"
fi
grep -Fq -- "queue helper not found or not executable" "$missing_stderr" \
  || fail "missing queue helper failure should include hook stderr"
/bin/mv "$hook_repo/scripts/semantic-review-queue.sh.missing" "$hook_repo/scripts/semantic-review-queue.sh"

chmod -x "$hook_repo/scripts/semantic-review-queue.sh"
if printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$hook_repo/src/lib.rs" \
  | (
    cd "$hook_repo"
    PATH="$hostile_dir:$PATH" \
      ./.claude/hooks/codex-review-hook.sh
  ) >"$noexec_stdout" 2>"$noexec_stderr"; then
  fail "non-executable queue helper should fail closed for enqueue-eligible files"
fi
grep -Fq -- "queue helper not found or not executable" "$noexec_stderr" \
  || fail "non-executable queue helper failure should include hook stderr"
chmod +x "$hook_repo/scripts/semantic-review-queue.sh"

assert_hostile_not_executed "$hostile_dir" cargo
assert_hostile_not_executed "$hostile_dir" semantic-mcp
assert_hostile_not_executed "$hostile_dir" tree-sitter-index

printf 'PASS: hook-fail-behavior-test docs_elapsed_ms=%s\n' "$docs_elapsed_ms"
