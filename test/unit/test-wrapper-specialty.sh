#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/codex-wrapper.sh"
PASS=0
FAIL=0

run() {
  local name="$1"; shift
  local expect_exit="$1"; shift
  local expect_grep="$1"; shift
  local out
  out=$("$@" 2>&1)
  local rc=$?
  if [ "$rc" = "$expect_exit" ] && echo "$out" | grep -q -- "$expect_grep"; then
    echo "PASS: $name"; PASS=$((PASS+1))
  else
    echo "FAIL: $name (exit=$rc, expected=$expect_exit; output substring missing: $expect_grep)"; FAIL=$((FAIL+1))
  fi
}

# 1. Positive: coder + valid coder specialty.
run "coder + refactor-safety-analyst dry-run validates" 0 "Status: validated" \
  "$WRAPPER" --role coder --specialty refactor-safety-analyst --dry-run

# 2. Positive: high-coder + valid coder specialty (runtime mapping).
run "high-coder + refactor-safety-analyst dry-run validates with canonical coder" 0 "Canonical: coder" \
  "$WRAPPER" --role high-coder --specialty refactor-safety-analyst --dry-run

# 3. Positive: reviewer + valid reviewer specialty.
run "reviewer + staff-code-reviewer dry-run validates" 0 "Status: validated" \
  "$WRAPPER" --role reviewer --specialty staff-code-reviewer --dry-run

# 4. Negative: standard runtime + specialty.
run "standard runtime rejects --specialty" 1 "standard/research runtime cannot use --specialty" \
  "$WRAPPER" --role standard --specialty refactor-safety-analyst --dry-run

# 5. Negative: research runtime + specialty.
run "research runtime rejects --specialty" 1 "standard/research runtime cannot use --specialty" \
  "$WRAPPER" --role research --specialty refactor-safety-analyst --dry-run

# 6. Negative: orchestrator specialty under coder profile.
run "coder + scope-guard rejected as orchestrator-only specialty" 1 "orchestrator specialty must be invoked by orchestrator" \
  "$WRAPPER" --role coder --specialty scope-guard --dry-run

# 7. Negative: --specialty without --role.
run "bare --specialty rejected" 1 "--specialty requires --role" \
  "$WRAPPER" --specialty refactor-safety-analyst --dry-run

# 8. Negative: invalid slug pattern.
run "invalid slug pattern rejected" 1 "slug pattern" \
  "$WRAPPER" --role coder --specialty FOO_BAR --dry-run

# 9. Negative: missing specialty file.
run "missing specialty file rejected" 1 "specialty file not found" \
  "$WRAPPER" --role coder --specialty nonexistent-slug --dry-run

# 10. Negative: coder runtime + reviewer specialty (canonical_role mismatch).
run "coder + staff-code-reviewer canonical mismatch" 1 "canonical_role mismatch" \
  "$WRAPPER" --role coder --specialty staff-code-reviewer --dry-run

# 11. Negative: specialty cannot be projected into resume continuation.
run "specialty + resume rejected" 1 "cannot be combined" \
  "$WRAPPER" --role coder --specialty refactor-safety-analyst --resume fake-session-id --dry-run

# 12. Negative: specialty cannot be combined with manual-session mode.
run "specialty + manual-session rejected" 1 "cannot be combined" \
  "$WRAPPER" --role coder --specialty refactor-safety-analyst --manual-session --dry-run

# 13. Positive: --specialty omitted logs Specialty: none.
run "omitted --specialty logs none" 0 "Specialty: none" \
  "$WRAPPER" --role coder --dry-run

# 14. Positive: --dry-run exits 0 on success.
"$WRAPPER" --role coder --specialty refactor-safety-analyst --dry-run >/dev/null 2>&1
if [ "$?" = "0" ]; then echo "PASS: dry-run exit 0 on success"; PASS=$((PASS+1)); else echo "FAIL: dry-run did not exit 0"; FAIL=$((FAIL+1)); fi

# 15. Negative: --dry-run exits non-zero on fail-closed.
"$WRAPPER" --role standard --specialty refactor-safety-analyst --dry-run >/dev/null 2>&1
if [ "$?" != "0" ]; then echo "PASS: dry-run exit non-zero on fail-closed"; PASS=$((PASS+1)); else echo "FAIL: dry-run did not exit non-zero"; FAIL=$((FAIL+1)); fi

echo "---"
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
