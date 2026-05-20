#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

output="$("$REPO_ROOT/scripts/rev-harness-dual-native-check.sh")"
case "$output" in
  *'"status":"ok"'*'"dual-native-orchestration"'*) ;;
  *)
    printf 'unexpected dual-native check output: %s\n' "$output" >&2
    exit 1
    ;;
esac

printf 'PASS: rev_harness_dual_native_check_test\n'
