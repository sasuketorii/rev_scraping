#!/usr/bin/env bash
set -euo pipefail
unset REVHARNESS_PARALLEL_QUIESCE

# T-G-3 rev-harness CLI integration smoke.
# Scenarios: help, --help, no args, status --json, install --dry-run --json,
# clean --dry-run, uninstall checklist, uninstall --apply deferred,
# upgrade apply deferred, backward syntax compatibility, unknown sub-command.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$SCRIPT_DIR/scripts/rev-harness"
FAILS=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR" || true' EXIT

run_case() {
  local name="$1"; shift
  set +e
  "$@" >"$TMP_DIR/$name.out" 2>"$TMP_DIR/$name.err"
  local rc=$?
  cat "$TMP_DIR/$name.out" "$TMP_DIR/$name.err" >"$TMP_DIR/$name.all"
  return "$rc"
}

pass() { printf 'PASS %s\n' "$1"; }
fail() {
  printf 'FAIL %s\n' "$1"
  FAILS=$((FAILS + 1))
}

contains() {
  local file="$1" pattern="$2"
  grep -Fq "$pattern" "$file"
}

valid_json() {
  local file="$1"
  if command -v jq >/dev/null 2>&1; then
    jq -e . "$file" >/dev/null 2>&1
  else
    grep -q '^{.*}$' "$file"
  fi
}

cd "$SCRIPT_DIR"

if run_case help "$CLI" help && \
  contains "$TMP_DIR/help.out" install && contains "$TMP_DIR/help.out" clean && \
  contains "$TMP_DIR/help.out" repair && contains "$TMP_DIR/help.out" status && \
  contains "$TMP_DIR/help.out" upgrade && contains "$TMP_DIR/help.out" uninstall; then
  pass "help lists medium verbs"
else
  fail "help lists medium verbs"
fi

if run_case help_flag "$CLI" --help && \
  contains "$TMP_DIR/help_flag.out" install && contains "$TMP_DIR/help_flag.out" uninstall; then
  pass "--help lists medium verbs"
else
  fail "--help lists medium verbs"
fi

if run_case no_args "$CLI" && contains "$TMP_DIR/no_args.out" Usage:; then
  pass "no args shows usage"
else
  fail "no args shows usage"
fi

if run_case status_json "$CLI" status --json; then
  if valid_json "$TMP_DIR/status_json.out" && contains "$TMP_DIR/status_json.out" '"phase":"uninstalled"'; then
    pass "status --json reports uninstalled without state"
  else
    fail "status --json reports uninstalled without state"
  fi
else
  fail "status --json exits 0"
fi

set +e
mkdir -p "$TMP_DIR/install-target"
run_case install_dry_json "$CLI" install --target "$TMP_DIR/install-target" --dry-run --json
install_rc=$?
set -e
if [[ "$install_rc" -eq 0 || "$install_rc" -eq 2 || "$install_rc" -ge 10 ]] && \
  contains "$TMP_DIR/install_dry_json.all" '"command":"install"'; then
  pass "install --dry-run --json invokes composer"
else
  fail "install --dry-run --json invokes composer"
fi

set +e
mkdir -p "$TMP_DIR/clean-target"
run_case clean_dry "$CLI" clean --target "$TMP_DIR/clean-target" --dry-run
clean_rc=$?
set -e
if [[ "$clean_rc" -eq 0 || "$clean_rc" -eq 2 ]] && \
  ! contains "$TMP_DIR/clean_dry.all" "unknown sub-command" && \
  ! contains "$TMP_DIR/clean_dry.all" "PARALLEL_QUIESCE active" && \
  contains "$TMP_DIR/clean_dry.all" "janitor_command: build-cleanup"; then
  pass "clean --dry-run dispatches janitor or fallback"
else
  fail "clean --dry-run dispatches janitor or fallback"
fi

set +e
mkdir -p "$TMP_DIR/clean-quiesce-target"
run_case clean_quiesce_skips env REVHARNESS_PARALLEL_QUIESCE=1 "$CLI" clean --target "$TMP_DIR/clean-quiesce-target" --dry-run
clean_quiesce_rc=$?
set -e
if [[ "$clean_quiesce_rc" -eq 0 ]] && \
  contains "$TMP_DIR/clean_quiesce_skips.all" "PARALLEL_QUIESCE active"; then
  pass "clean --dry-run skips under PARALLEL_QUIESCE"
else
  fail "clean --dry-run skips under PARALLEL_QUIESCE"
fi

if run_case uninstall "$CLI" uninstall && \
  { contains "$TMP_DIR/uninstall.out" "Remove canonical PATH export" || \
    contains "$TMP_DIR/uninstall.out" "checklist" || \
    contains "$TMP_DIR/uninstall.out" "pre-commit"; }; then
  pass "uninstall prints checklist"
else
  fail "uninstall prints checklist"
fi

set +e
run_case uninstall_apply "$CLI" uninstall --apply
uninstall_apply_rc=$?
set -e
if [[ "$uninstall_apply_rc" -eq 2 ]] && contains "$TMP_DIR/uninstall_apply.all" "deferred to Phase G+1"; then
  pass "uninstall --apply deferred"
else
  fail "uninstall --apply deferred"
fi

set +e
run_case upgrade_apply "$CLI" upgrade apply
upgrade_apply_rc=$?
set -e
if [[ "$upgrade_apply_rc" -eq 2 ]] && contains "$TMP_DIR/upgrade_apply.all" "deferred to Phase G+1"; then
  pass "upgrade apply deferred"
else
  fail "upgrade apply deferred"
fi

if bash -n "$SCRIPT_DIR/scripts/rev-harness-adopter-setup.sh" && \
  bash -n "$SCRIPT_DIR/scripts/rev-harness-janitor.sh" && \
  bash -n "$SCRIPT_DIR/scripts/harness-doctor.sh"; then
  pass "backward compatible scripts parse"
else
  fail "backward compatible scripts parse"
fi

set +e
run_case unknown "$CLI" frobnicate
unknown_rc=$?
set -e
if [[ "$unknown_rc" -eq 2 ]] && contains "$TMP_DIR/unknown.all" "unknown sub-command"; then
  pass "unknown sub-command exits 2"
else
  fail "unknown sub-command exits 2"
fi

printf 'FAILURES %s\n' "$FAILS"
[[ "$FAILS" -eq 0 ]]
