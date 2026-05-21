#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/_canonical-guard.sh"
PASS=0
FAIL=0

make_temp_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/scripts" "$dir/.shared"
  # Symlink the real guard so identity-class logic is exercised
  cp "${GUARD}" "$dir/scripts/_canonical-guard.sh"
  # Synthetic wrapper script that sources the guard and prints "OK"
  cat >"$dir/scripts/test-wrapper.sh" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/_canonical-guard.sh
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root test-wrapper
echo "OK"
WRAPPER
  chmod +x "$dir/scripts/test-wrapper.sh"
  echo "$dir"
}

cleanup_temp_repo() { rm -rf "$1"; }

assert_outcome() {
  local name="$1"; shift
  local expect="$1"; shift   # "PASS" or "FAIL"
  local expect_grep="${1:-}"; shift || true
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  local got
  if [[ $rc -eq 0 ]] && echo "$out" | grep -q "^OK$"; then
    got="PASS"
  else
    got="FAIL"
  fi
  if [[ "$got" == "$expect" ]]; then
    if [[ -n "$expect_grep" ]] && ! echo "$out" | grep -q -- "$expect_grep"; then
      echo "FAIL: ${name} (outcome matched ${expect} but expected substring missing: ${expect_grep})"
      FAIL=$((FAIL+1))
    else
      echo "PASS: ${name}"
      PASS=$((PASS+1))
    fi
  else
    echo "FAIL: ${name} (expected ${expect} got ${got}, rc=${rc})"
    echo "      output: $(echo "$out" | head -3 | tr '\n' '|')"
    FAIL=$((FAIL+1))
  fi
}

# 1. canonical-dev (via REV_HARNESS_CANONICAL_ROOT == repo_root)
T1=$(make_temp_repo)
echo "fake-revharness-id" >"$T1/.shared/project_id"
assert_outcome "canonical path match passes" "PASS" "" \
  env REV_HARNESS_CANONICAL_ROOT="$T1" "$T1/scripts/test-wrapper.sh"
cleanup_temp_repo "$T1"

# 2. managed-adopter (non-revharness project_id)
T2=$(make_temp_repo)
echo "rev_scraping-09399a56d97f" >"$T2/.shared/project_id"
assert_outcome "managed-adopter (non-revharness id) passes without env" "PASS" "" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T2/scripts/test-wrapper.sh"
cleanup_temp_repo "$T2"

# 3. ambiguous-copy (revharness-* but no canonical path AND no official remote)
T3=$(make_temp_repo)
echo "revharness-deadbeef" >"$T3/.shared/project_id"
assert_outcome "ambiguous-copy (revharness id outside canonical) fail-closes" "FAIL" "ambiguous RevHarness identity" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T3/scripts/test-wrapper.sh"
cleanup_temp_repo "$T3"

# 4. invalid (project_id missing)
T4=$(make_temp_repo)
rm -f "$T4/.shared/project_id"
assert_outcome "missing project_id fail-closes invalid" "FAIL" "missing or invalid repo identity" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T4/scripts/test-wrapper.sh"
cleanup_temp_repo "$T4"

# 5. invalid (control characters in project_id)
T5=$(make_temp_repo)
printf 'rev_scraping\x01bad' >"$T5/.shared/project_id"
assert_outcome "control-char in project_id fail-closes" "FAIL" "missing or invalid repo identity" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T5/scripts/test-wrapper.sh"
cleanup_temp_repo "$T5"

# 6. invalid (multiline project_id collapses to first line; first line empty -> invalid)
T6=$(make_temp_repo)
printf '\nrev_scraping-second-line' >"$T6/.shared/project_id"
assert_outcome "leading-blank multiline project_id fail-closes" "FAIL" "missing or invalid repo identity" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T6/scripts/test-wrapper.sh"
cleanup_temp_repo "$T6"

# 7. warn mode bypasses fail-close for ambiguous-copy
T7=$(make_temp_repo)
echo "revharness-deadbeef" >"$T7/.shared/project_id"
assert_outcome "VENDOR_CHECK=warn allows ambiguous-copy through" "PASS" "ambiguous RevHarness identity" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=warn \
  HOME="/nonexistent-test-home-canonical-guard" "$T7/scripts/test-wrapper.sh"
cleanup_temp_repo "$T7"

# 8. managed-adopter with id containing dots / underscores / hyphens
T8=$(make_temp_repo)
echo "my_project.local-name_v2-abcd1234" >"$T8/.shared/project_id"
assert_outcome "managed-adopter with mixed chars (._-) passes" "PASS" "" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T8/scripts/test-wrapper.sh"
cleanup_temp_repo "$T8"

# 9. revharness-* WITH matching git remote (official source checkout via remote URL)
T9=$(make_temp_repo)
echo "revharness-deadbeef" >"$T9/.shared/project_id"
(cd "$T9" && git init -q 2>/dev/null && git remote add origin "https://github.com/sasuketorii/rev_harness.git" 2>/dev/null)
assert_outcome "revharness-* with official git remote passes (canonical-dev via remote)" "PASS" "" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T9/scripts/test-wrapper.sh"
cleanup_temp_repo "$T9"

echo "---"
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
