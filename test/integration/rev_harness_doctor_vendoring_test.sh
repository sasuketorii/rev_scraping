#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DOCTOR="$PROJECT_ROOT/scripts/harness-doctor.sh"
CANONICAL_CLAUDE="$PROJECT_ROOT/scripts/claude-wrapper.sh"
CANONICAL_CODEX="$PROJECT_ROOT/scripts/codex-wrapper.sh"

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  printf 'PASS: %s\n' "$*"
  PASS_COUNT=$((PASS_COUNT + 1))
}

failure() {
  printf 'FAIL: %s\n' "$*" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

make_fixture() {
  local kind="$1"
  local fixture
  fixture="$(mktemp -d -t rev_harness_doctor_vendoring_test.XXXXXX)"
  case "$kind" in
    clean)
      mkdir -p "$fixture/src"
      printf 'echo hello\n' >"$fixture/src/app.sh"
      ;;
    vendor)
      mkdir -p "$fixture/tools/rev_harness/scripts"
      if [[ -f "$CANONICAL_CLAUDE" ]]; then
        cp "$CANONICAL_CLAUDE" "$fixture/tools/rev_harness/scripts/claude-wrapper.sh"
      fi
      if [[ -f "$CANONICAL_CODEX" ]]; then
        cp "$CANONICAL_CODEX" "$fixture/tools/rev_harness/scripts/codex-wrapper.sh"
      fi
      ;;
    mutated)
      mkdir -p "$fixture/tools/rev_harness/scripts"
      if [[ -f "$CANONICAL_CLAUDE" ]]; then
        cp "$CANONICAL_CLAUDE" "$fixture/tools/rev_harness/scripts/claude-wrapper.sh"
        printf '\n# local hack\n' >>"$fixture/tools/rev_harness/scripts/claude-wrapper.sh"
      fi
      ;;
  esac
  printf '%s\n' "$fixture"
}

cleanup_fixture() {
  local fixture="$1"
  [[ -n "$fixture" && -d "$fixture" ]] || return 0
  case "$fixture" in
    /tmp/*|/var/folders/*) rm -rf "$fixture" ;;
  esac
}

# Preflight: canonical wrappers must exist in this repo so cp can populate fixtures.
if [[ ! -f "$CANONICAL_CLAUDE" || ! -f "$CANONICAL_CODEX" ]]; then
  failure "preflight: canonical wrappers missing under $PROJECT_ROOT/scripts"
  printf 'RESULT: pass=%d fail=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
  exit 1
fi

# case1: clean fixture -> exit 0
FIX1="$(make_fixture clean)"
set +e
OUT1="$(bash "$DOCTOR" --check-vendoring --path "$FIX1" 2>&1)"
EC1=$?
set -e
if [[ "$EC1" -eq 0 ]] && printf '%s' "$OUT1" | grep -q 'no vendoring'; then
  pass "case1: clean fixture exits 0 with 'no vendoring'"
else
  failure "case1: expected exit 0 + 'no vendoring', got exit=$EC1 output=<<$OUT1>>"
fi
cleanup_fixture "$FIX1"

# case2: vendored fixture -> exit 70
FIX2="$(make_fixture vendor)"
set +e
OUT2="$(bash "$DOCTOR" --check-vendoring --path "$FIX2" 2>&1)"
EC2=$?
set -e
if [[ "$EC2" -eq 70 ]] && printf '%s' "$OUT2" | grep -q 'VENDORED COPY'; then
  pass "case2: vendored fixture exits 70 with 'VENDORED COPY'"
else
  failure "case2: expected exit 70 + 'VENDORED COPY', got exit=$EC2 output=<<$OUT2>>"
fi
cleanup_fixture "$FIX2"

# case3: mutated fixture -> exit 71
FIX3="$(make_fixture mutated)"
set +e
OUT3="$(bash "$DOCTOR" --check-vendoring --path "$FIX3" 2>&1)"
EC3=$?
set -e
if [[ "$EC3" -eq 71 ]] && printf '%s' "$OUT3" | grep -q 'MUTATED COPY'; then
  pass "case3: mutated fixture exits 71 with 'MUTATED COPY'"
else
  failure "case3: expected exit 71 + 'MUTATED COPY', got exit=$EC3 output=<<$OUT3>>"
fi
cleanup_fixture "$FIX3"

# case4: vendored fixture with --allow-vendored -> exit 0, warning visible
FIX4="$(make_fixture vendor)"
set +e
OUT4="$(bash "$DOCTOR" --check-vendoring --path "$FIX4" --allow-vendored 2>&1)"
EC4=$?
set -e
if [[ "$EC4" -eq 0 ]] && printf '%s' "$OUT4" | grep -q 'VENDORED COPY detected (allowed)'; then
  pass "case4: --allow-vendored suppresses vendored failure but warns"
else
  failure "case4: expected exit 0 + 'VENDORED COPY detected (allowed)' warning, got exit=$EC4 output=<<$OUT4>>"
fi
cleanup_fixture "$FIX4"

printf 'RESULT: pass=%d fail=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
