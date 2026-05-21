#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GUARD="${REPO_ROOT}/scripts/_canonical-guard.sh"
PASS=0
FAIL=0

# Default-warn semantic (0.0.12):
#   - canonical-dev / managed-adopter: silent pass
#   - ambiguous-copy: default WARN (advisory, exit 0), strict mode -> exit 70
#   - invalid (missing/malformed project_id): default STRICT (exit 70), warn mode -> advisory exit 0

make_temp_repo() {
  local dir
  dir="$(mktemp -d)"
  mkdir -p "$dir/scripts" "$dir/.shared"
  cp "${GUARD}" "$dir/scripts/_canonical-guard.sh"
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

# 1. canonical-dev (REV_HARNESS_CANONICAL_ROOT == repo_root) — silent pass
T1=$(make_temp_repo)
echo "revharness-canonical-test" >"$T1/.shared/project_id"
assert_outcome "canonical path match passes silent" "PASS" "" \
  env REV_HARNESS_CANONICAL_ROOT="$T1" "$T1/scripts/test-wrapper.sh"
cleanup_temp_repo "$T1"

# 2. managed-adopter — silent pass, no advisory
T2=$(make_temp_repo)
echo "rev_scraping-09399a56d97f" >"$T2/.shared/project_id"
assert_outcome "managed-adopter passes silently" "PASS" "" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T2/scripts/test-wrapper.sh"
# Also: no identity-check wording leaks on managed-adopter
out=$(env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T2/scripts/test-wrapper.sh" 2>&1)
if echo "$out" | grep -q "identity-check"; then
  echo "FAIL: managed-adopter should not emit identity-check wording"; FAIL=$((FAIL+1))
else
  echo "PASS: managed-adopter silent (no identity-check wording)"; PASS=$((PASS+1))
fi
cleanup_temp_repo "$T2"

# 3. ambiguous-copy default WARN (0.0.12 change) — exit 0 with advisory wording
T3=$(make_temp_repo)
echo "revharness-deadbeef" >"$T3/.shared/project_id"
assert_outcome "ambiguous-copy default warn (exit 0, advisory wording)" "PASS" "identity-check (advisory)" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T3/scripts/test-wrapper.sh"
cleanup_temp_repo "$T3"

# 4. ambiguous-copy with REV_HARNESS_VENDOR_CHECK=strict — fail-close
T4=$(make_temp_repo)
echo "revharness-deadbeef" >"$T4/.shared/project_id"
assert_outcome "ambiguous-copy strict fail-closes" "FAIL" "identity-check (strict)" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=strict \
  HOME="/nonexistent-test-home-canonical-guard" "$T4/scripts/test-wrapper.sh"
cleanup_temp_repo "$T4"

# 5. invalid (missing project_id) — default STRICT fail-close (kept from 0.0.11)
T5=$(make_temp_repo)
rm -f "$T5/.shared/project_id"
assert_outcome "missing project_id default strict fail-closes" "FAIL" "identity-check (strict)" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T5/scripts/test-wrapper.sh"
cleanup_temp_repo "$T5"

# 6. invalid with REV_HARNESS_VENDOR_CHECK=warn — advisory exit 0
T6=$(make_temp_repo)
rm -f "$T6/.shared/project_id"
assert_outcome "invalid + warn mode downgrades to advisory" "PASS" "identity-check (advisory)" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=warn \
  HOME="/nonexistent-test-home-canonical-guard" "$T6/scripts/test-wrapper.sh"
cleanup_temp_repo "$T6"

# 7. control-char in project_id — invalid, default strict
T7=$(make_temp_repo)
printf 'rev_scraping\x01bad' >"$T7/.shared/project_id"
assert_outcome "control-char in project_id default strict fail-closes" "FAIL" "identity-check (strict)" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T7/scripts/test-wrapper.sh"
cleanup_temp_repo "$T7"

# 8. leading-blank multiline project_id — invalid, default strict
T8=$(make_temp_repo)
printf '\nrev_scraping-second-line' >"$T8/.shared/project_id"
assert_outcome "leading-blank multiline project_id default strict fail-closes" "FAIL" "identity-check (strict)" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T8/scripts/test-wrapper.sh"
cleanup_temp_repo "$T8"

# 9. unknown REV_HARNESS_VENDOR_CHECK value — falls back to warn with advisory
T9=$(make_temp_repo)
echo "revharness-deadbeef" >"$T9/.shared/project_id"
assert_outcome "unknown VENDOR_CHECK value falls back to warn" "PASS" "unknown REV_HARNESS_VENDOR_CHECK" \
  env -u REV_HARNESS_CANONICAL_ROOT REV_HARNESS_VENDOR_CHECK=bogus \
  HOME="/nonexistent-test-home-canonical-guard" "$T9/scripts/test-wrapper.sh"
cleanup_temp_repo "$T9"

# 10. managed-adopter with mixed chars (._-)
T10=$(make_temp_repo)
echo "my_project.local-name_v2-abcd1234" >"$T10/.shared/project_id"
assert_outcome "managed-adopter mixed-char id passes" "PASS" "" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T10/scripts/test-wrapper.sh"
cleanup_temp_repo "$T10"

# 11. revharness-* WITH matching official git remote (canonical-dev via remote)
T11=$(make_temp_repo)
echo "revharness-deadbeef" >"$T11/.shared/project_id"
(cd "$T11" && git init -q 2>/dev/null && git remote add origin "https://github.com/sasuketorii/rev_harness.git" 2>/dev/null)
assert_outcome "revharness-* + official remote passes silent (canonical-dev via remote)" "PASS" "" \
  env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T11/scripts/test-wrapper.sh"
# Also: no identity-check wording leaks on canonical-dev via remote
out=$(env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T11/scripts/test-wrapper.sh" 2>&1)
if echo "$out" | grep -q "identity-check"; then
  echo "FAIL: canonical-dev via remote should not emit identity-check wording"; FAIL=$((FAIL+1))
else
  echo "PASS: canonical-dev via remote silent (no identity-check wording)"; PASS=$((PASS+1))
fi
cleanup_temp_repo "$T11"

# 12. neutral wording — no "VENDOR GUARD" left in any path (legacy term removed)
T12=$(make_temp_repo)
echo "revharness-deadbeef" >"$T12/.shared/project_id"
out=$(env -u REV_HARNESS_CANONICAL_ROOT -u REV_HARNESS_VENDOR_CHECK \
  HOME="/nonexistent-test-home-canonical-guard" "$T12/scripts/test-wrapper.sh" 2>&1)
if echo "$out" | grep -q "VENDOR GUARD"; then
  echo "FAIL: legacy 'VENDOR GUARD' wording must be removed (found in ambiguous-copy advisory)"; FAIL=$((FAIL+1))
else
  echo "PASS: legacy 'VENDOR GUARD' wording is gone"; PASS=$((PASS+1))
fi
cleanup_temp_repo "$T12"

echo "---"
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "${FAIL}"
