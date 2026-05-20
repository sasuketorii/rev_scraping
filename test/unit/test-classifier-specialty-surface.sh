#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CLI="$REPO_ROOT/scripts/rev-harness-task-classifier.sh"
PASS=0
FAIL=0

assert_class() {
  local name="$1"; shift
  local expected="$1"; shift
  local result
  result=$("$@" 2>&1 | jq -r .task_class 2>/dev/null)
  if [ "$result" = "$expected" ]; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (got=$result expected=$expected)"; FAIL=$((FAIL+1))
  fi
}

# 1. coder specialty path classifies heavy.
assert_class "coder/specialties is heavy" heavy \
  "$CLI" classify --intent implementation --files docs/roles/coder/specialties/refactor-safety-analyst.md --json

# 2. reviewer specialty path classifies heavy.
assert_class "reviewer/specialties is heavy" heavy \
  "$CLI" classify --intent implementation --files docs/roles/reviewer/specialties/staff-code-reviewer.md --json

# 3. orchestrator specialty path classifies heavy.
assert_class "orchestrator/specialties is heavy" heavy \
  "$CLI" classify --intent implementation --files docs/roles/orchestrator/specialties/scope-guard.md --json

# 4. canonical role docs still heavy (regression).
assert_class "docs/roles/coder.md is heavy" heavy \
  "$CLI" classify --intent implementation --files docs/roles/coder.md --json

# 5. matrix file still heavy (regression).
assert_class "matrix is heavy" heavy \
  "$CLI" classify --intent implementation --files docs/manual/verification-truth-matrix.md --json

# 6. Unrelated docs path stays at intent class (regression).
assert_class "unrelated docs intent-only is standard" standard \
  "$CLI" classify --intent docs --files README.md --json

# 7. Non-canonical docs/roles/specialties path must not match role docs or specialty glob.
assert_class "non-canonical roles specialties path is not heavy" standard \
  "$CLI" classify --intent implementation --files docs/roles/specialties/foo.md --json

echo "---"
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
