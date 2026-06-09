#!/usr/bin/env bash
# lint-cross-harness-skill-ownership.sh
# Task: skill-audit/phase12 S-2. Validates cross_harness_skill_ownership.json:
#   - every duplicated skill has exactly one canonical_base in {3 harnesses}
#   - x-kobun canonical_base == rev_textsocialharness
# exit 0 if valid, nonzero otherwise.
set -euo pipefail
# Resolve rev_harness root from this script's location (no home-dir absolute
# paths baked in; keeps the path-leak guard happy and the script portable).
REV_HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
MAP="${REV_HARNESS_ROOT}/.agent/registry/cross_harness_skill_ownership.json"
command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required" >&2; exit 2; }
test -f "$MAP" || { echo "FAIL: ownership map missing: $MAP" >&2; exit 1; }

VALID='["rev_harness","rev_marketing_harness","rev_textsocialharness"]'
bad=$(jq -r --argjson v "$VALID" '
  to_entries
  | map(select((.value | type) == "object"))
  | map(select((.value.canonical_base // "") as $b | ($v | index($b)) == null))
  | .[].key' "$MAP")
if [ -n "$bad" ]; then
  echo "FAIL: skills with missing/invalid canonical_base:" >&2
  echo "$bad" >&2
  exit 1
fi

xk=$(jq -r '.["x-kobun"].canonical_base // "MISSING"' "$MAP")
if [ "$xk" != "rev_textsocialharness" ]; then
  echo "FAIL: x-kobun canonical_base=$xk (expected rev_textsocialharness)" >&2
  exit 1
fi

count=$(jq -r 'to_entries | map(select((.value | type) == "object")) | length' "$MAP")
echo "OK: $count duplicate skills each have exactly one valid canonical_base; x-kobun=rev_textsocialharness"
exit 0
