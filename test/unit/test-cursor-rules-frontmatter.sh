#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RULE="${REPO_ROOT}/.cursor/rules/revharness-critical.mdc"
DETAIL_RULE="${REPO_ROOT}/.cursor/rules/revharness-detailed.mdc"
PASS=0
FAIL=0

pass() {
  echo "PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL=$((FAIL + 1))
}

assert_cmd() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_head_contains() {
  local name="$1"
  local pattern="$2"
  if head -10 "$RULE" | grep -q -- "$pattern"; then
    pass "$name"
  else
    fail "$name"
  fi
}

assert_head_not_contains() {
  local name="$1"
  local pattern="$2"
  if head -10 "$RULE" | grep -q -- "$pattern"; then
    fail "$name"
  else
    pass "$name"
  fi
}

assert_rule_contains_any() {
  local name="$1"
  shift
  local pattern
  for pattern in "$@"; do
    if grep -qi -- "$pattern" "$RULE"; then
      pass "$name"
      return
    fi
  done
  fail "$name"
}

assert_cmd "critical rule exists" test -s "$RULE"

assert_head_contains "alwaysApply true in first 10 lines" "alwaysApply: true"
assert_head_not_contains "no globs in first 10 lines" "globs:"
assert_head_not_contains "no description in first 10 lines" "description:"

line_count="$(wc -l <"$RULE" | tr -d '[:space:]')"
if [[ "$line_count" =~ ^[0-9]+$ ]] && ((line_count <= 80)); then
  pass "critical rule line count <= 80"
else
  fail "critical rule line count <= 80 (got ${line_count})"
fi

assert_rule_contains_any "mentions secret invariant" "secret" "redacted"
assert_rule_contains_any "mentions outbound wrapper invariant" "outbound" "wrapper"
assert_rule_contains_any "mentions ask read-only invariant" "read-only" "ask"
assert_rule_contains_any "mentions truth matrix invariant" "truth-matrix" "verification-truth-matrix"
assert_rule_contains_any "mentions project_id invariant" "project_id"

first_line="$(sed -n '1p' "$RULE")"
third_line="$(sed -n '3p' "$RULE")"
if [[ "$first_line" == "---" && "$third_line" == "---" ]]; then
  pass "frontmatter is wrapped by --- on lines 1 and 3"
else
  fail "frontmatter is wrapped by --- on lines 1 and 3"
fi

last_byte="$(tail -c 1 "$RULE" 2>/dev/null | od -An -t x1 | tr -d '[:space:]')"
if [[ -s "$RULE" ]] && [[ "$last_byte" == "0a" ]]; then
  pass "critical rule has trailing newline"
else
  fail "critical rule has trailing newline"
fi

assert_cmd "detailed rule exists" test -s "$DETAIL_RULE"

if head -10 "$DETAIL_RULE" | grep -q -- "description:"; then
  pass "detailed rule has description frontmatter"
else
  fail "detailed rule has description frontmatter"
fi

if head -10 "$DETAIL_RULE" | grep -q -- "alwaysApply:"; then
  fail "detailed rule has no alwaysApply frontmatter"
else
  pass "detailed rule has no alwaysApply frontmatter"
fi

detailed_line_count="$(wc -l <"$DETAIL_RULE" | tr -d '[:space:]')"
if [[ "$detailed_line_count" =~ ^[0-9]+$ ]] && ((detailed_line_count <= 400)); then
  pass "detailed rule line count <= 400"
else
  fail "detailed rule line count <= 400 (got ${detailed_line_count})"
fi

if grep -Eq 'AKIA[0-9A-Z]{16}' "$DETAIL_RULE"; then
  fail "detailed rule does not duplicate raw access-key regex"
else
  pass "detailed rule does not duplicate raw access-key regex"
fi

if grep -Eqi 'must not call.*wrapper|must not invoke.*wrapper' "$DETAIL_RULE"; then
  fail "detailed rule does not duplicate strict wrapper prohibition"
else
  pass "detailed rule does not duplicate strict wrapper prohibition"
fi

echo "---"
echo "Result: ${PASS} passed, ${FAIL} failed"
exit "$FAIL"
