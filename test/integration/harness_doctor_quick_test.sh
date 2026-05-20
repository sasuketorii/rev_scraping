#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$PROJECT_ROOT/scripts/harness-doctor.sh"
TEST_BASH="${HARNESS_TEST_BASH:-/bin/bash}"

if [[ -x "$TEST_BASH" && "${BASH:-}" != "$TEST_BASH" && -z "${HARNESS_DOCTOR_QUICK_TEST_REEXECED:-}" ]]; then
  export HARNESS_DOCTOR_QUICK_TEST_REEXECED=1
  exec "$TEST_BASH" "$0" "$@"
fi

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

sha256_value() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    shasum -a 256 | awk '{print $1}'
  fi
}

file_hash_or_missing() {
  local path="$1"
  if [[ -e "$path" && ! -L "$path" && -f "$path" ]]; then
    if command -v sha256sum >/dev/null 2>&1; then
      sha256sum "$path" | awk '{print $1}'
    else
      shasum -a 256 "$path" | awk '{print $1}'
    fi
  elif [[ -L "$path" ]]; then
    printf 'symlink\n'
  else
    printf 'missing\n'
  fi
}

mtime_or_missing() {
  local path="$1"
  if [[ -e "$path" ]]; then
    stat -f '%m' "$path" 2>/dev/null || stat -c '%Y' "$path" 2>/dev/null || printf 'unknown\n'
  else
    printf 'missing\n'
  fi
}

run_json() {
  (cd "$PROJECT_ROOT" && "$TEST_BASH" "$DOCTOR" --quick --json)
}

assert_schema() {
  local json="$1"
  printf '%s\n' "$json" | jq -e '
    .schema_version == "harness-doctor/v1"
    and .mode == "quick"
    and .tier == "quick"
    and .advisory_only == true
    and .acceptance_authority == false
    and .network_allowed == false
    and .deep_scan == false
    and .artifact_body_scan == false
    and .mutated == false
    and .execution_failure == false
    and (.status | IN("OK", "WARN", "BLOCK", "UNKNOWN"))
    and (.advisory_status == .status)
    and (.elapsed_ms | type == "number")
    and (.elapsed_ms <= 3000)
    and (.steps | type == "array" and length >= 4)
    and all(.steps[]; (.name | type == "string") and (.status | type == "string") and (.elapsed_ms | type == "number"))
    and (.blocks | type == "array")
    and (.warnings | type == "array")
    and (.unknowns | type == "array")
    and (.summaries.git_status.dirty_count | type == "number")
    and (.summaries.release_gate | type == "object")
    and (.summaries.model_policy | type == "object")
  ' >/dev/null || fail "quick JSON schema sanity failed"
}

assert_step_timing_consistency() {
  local json="$1"
  printf '%s\n' "$json" | jq -e '
    ([.steps[].elapsed_ms] | max) <= (.elapsed_ms + 100)
    and (([.steps[].elapsed_ms] | add) <= (.elapsed_ms + 1200))
  ' >/dev/null || fail "step timing consistency failed"
}

snapshot_managed_state() {
  local root="$PROJECT_ROOT/.claude/tmp/harness-release-gate"
  local files=(
    "$root/latest.json"
    "$root/latest-success.json"
    "$root/latest-failure.json"
  )
  local file=""

  {
    printf 'tracked_diff_hash=%s\n' "$(git -C "$PROJECT_ROOT" diff --binary -- . ':(exclude).claude/tmp' | sha256_value)"
    printf 'cached_diff_hash=%s\n' "$(git -C "$PROJECT_ROOT" diff --cached --binary -- . ':(exclude).claude/tmp' | sha256_value)"
    printf 'untracked_hash=%s\n' "$(git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all | awk 'substr($0,1,2) == "??" {print substr($0,4)}' | LC_ALL=C sort | sha256_value)"
    printf 'untracked_content_hash=%s\n' "$(
	      git -C "$PROJECT_ROOT" status --porcelain=v1 --untracked-files=all \
	        | awk 'substr($0,1,2) == "??" {
	            path = substr($0,4)
	            if (path ~ /^(\.agent\/active\/|scripts\/|test\/integration\/|docs\/manual\/)/) {
	              print path
	            }
	          }' \
	        | LC_ALL=C sort \
	        | while IFS= read -r rel_path; do
	            [[ -f "$PROJECT_ROOT/$rel_path" && ! -L "$PROJECT_ROOT/$rel_path" ]] || continue
	            printf '%s  %s\n' "$(file_hash_or_missing "$PROJECT_ROOT/$rel_path")" "$rel_path"
	          done | sha256_value
    )"

    for file in "${files[@]}"; do
      printf 'file=%s hash=%s mtime=%s\n' "${file#"$PROJECT_ROOT"/}" "$(file_hash_or_missing "$file")" "$(mtime_or_missing "$file")"
    done

    if [[ -d "$root/runs" ]]; then
      printf 'run_dir_count=%s\n' "$(printf '%s\n' "$root"/runs/*/ | awk '$0 !~ /\*\/$/ {count++} END {print count + 0}')"
    else
      printf 'run_dir_count=missing\n'
    fi
  } | sha256_value
}

assert_no_mutation() {
  local before after
  before="$(snapshot_managed_state)"
  run_json >/dev/null
  after="$(snapshot_managed_state)"
  [[ "$before" == "$after" ]] || fail "quick doctor mutated tracked, cached, untracked, or managed pointer state"
}

assert_forbidden_calls_absent() {
  local body_file
  body_file="$(mktemp "${TMPDIR:-/tmp}/harness-doctor-body.XXXXXX")"
  sed -n '/^require_quick_dependencies()/,$p' "$DOCTOR" > "$body_file"

  ! grep -Eq '\b(curl|wget)\b' "$body_file" || fail "quick path must not call curl/wget"
  ! grep -Eq '\bgit[[:space:]]+(-C[[:space:]]+"?\$PROJECT_ROOT"?[[:space:]]+)?(fetch|pull|ls-remote|grep)\b' "$body_file" || fail "quick path must not call network git or git grep"
  ! grep -Eq '\b(npm|pnpm|yarn|pip|cargo)[[:space:]]+(install|update|fetch)\b' "$body_file" || fail "quick path must not call package fetch/install"
  ! grep -Eq '\bgrep[[:space:]]+-R\b' "$body_file" || fail "quick path must not call recursive grep"
  ! grep -Eq '\brg([[:space:]]|$)' "$body_file" || fail "quick path must not call rg"
  ! grep -Eq '\bfind[[:space:]]+\.' "$body_file" || fail "quick path must not call find ."
  ! grep -Eq 'harness-release-gate.*/\*\*|harness-release-gate.*find|harness-release-gate.*grep[[:space:]]+-R' "$body_file" \
    || fail "quick path must not recursively traverse release-gate artifacts"
  /bin/rm -f "$body_file"
}

write_stub() {
  local path="$1"
  local real_command="${2:-}"

  case "$(basename "$path")" in
    git)
      cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
subcmd="\${1:-}"
if [[ "\${subcmd}" == "-C" && "\$#" -ge 3 ]]; then
  subcmd="\${3}"
fi
case "\${subcmd}" in
  fetch|pull|ls-remote|grep)
    printf 'forbidden git %s\n' "\$*" >> "$FORBIDDEN_LOG"
    exit 97
    ;;
esac
exec "$real_command" "\$@"
EOF
      ;;
    grep)
      cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  case "\$arg" in
    -R|-r|--recursive)
      printf 'forbidden grep %s\n' "\$*" >> "$FORBIDDEN_LOG"
      exit 97
      ;;
  esac
done
exec "$real_command" "\$@"
EOF
      ;;
    find)
      cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
root="\${1:-}"
case "\$root" in
  .|./*|"$PROJECT_ROOT"|"$PROJECT_ROOT"/*|*.claude/tmp/harness-release-gate*)
    printf 'forbidden find %s\n' "\$*" >> "$FORBIDDEN_LOG"
    exit 97
    ;;
esac
exec "$real_command" "\$@"
EOF
      ;;
    *)
      cat > "$path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'forbidden $(basename "$path") %s\n' "\$*" >> "$FORBIDDEN_LOG"
exit 97
EOF
      ;;
  esac
  chmod +x "$path"
}

assert_path_stub_forbidden_shapes_absent() {
  local stub_dir
  local real_git real_grep real_find
  local cmd

  stub_dir="$(mktemp -d "${TMPDIR:-/tmp}/harness-doctor-path-stubs.XXXXXX")"
  FORBIDDEN_LOG="$stub_dir/forbidden.log"
  export FORBIDDEN_LOG
  : > "$FORBIDDEN_LOG"

  real_git="$(command -v git)"
  real_grep="$(command -v grep)"
  real_find="$(command -v find)"

  write_stub "$stub_dir/git" "$real_git"
  write_stub "$stub_dir/grep" "$real_grep"
  write_stub "$stub_dir/find" "$real_find"
  for cmd in curl wget npm pnpm yarn pip cargo rg; do
    write_stub "$stub_dir/$cmd"
  done

  PATH="$stub_dir:$PATH" run_json >/dev/null || {
    cat "$FORBIDDEN_LOG" >&2
    /bin/rm -rf "$stub_dir"
    fail "quick doctor failed under PATH forbidden-call stubs"
  }

  if [[ -s "$FORBIDDEN_LOG" ]]; then
    cat "$FORBIDDEN_LOG" >&2
    /bin/rm -rf "$stub_dir"
    fail "quick doctor invoked a forbidden network/deep-scan command shape"
  fi

  /bin/rm -rf "$stub_dir"
}

assert_external_timing_budget() {
  local elapsed
  elapsed="$(cd "$PROJECT_ROOT" && python3 - "$DOCTOR" "$TEST_BASH" <<'PY'
import subprocess
import sys
import time

started = time.monotonic_ns()
subprocess.run([sys.argv[2], sys.argv[1], "--quick", "--json"], check=True, stdout=subprocess.DEVNULL)
ended = time.monotonic_ns()
print((ended - started) // 1_000_000)
PY
)"
  [[ "$elapsed" =~ ^[0-9]+$ ]] || fail "external elapsed is not numeric: $elapsed"
  [[ "$elapsed" -le 3500 ]] || fail "external quick timing exceeded budget: ${elapsed}ms"
}

json="$(run_json)" || fail "quick doctor exited non-zero"
printf '%s\n' "$json" | jq empty >/dev/null || fail "quick doctor did not emit valid JSON"
assert_schema "$json"
assert_step_timing_consistency "$json"
assert_no_mutation
assert_forbidden_calls_absent
assert_path_stub_forbidden_shapes_absent
assert_external_timing_budget

(cd "$PROJECT_ROOT" && "$TEST_BASH" "$DOCTOR" --quick >/dev/null) || fail "human quick output exited non-zero"

printf 'PASS: harness_doctor_quick_test\n'
