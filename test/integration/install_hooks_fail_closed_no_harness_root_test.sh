#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TMP_DIR="$(mktemp -d)"

cleanup() {
  /bin/rm -rf "$TMP_DIR"
}
trap cleanup EXIT

git -C "$TMP_DIR" init -q

set +e
(
  cd "$TMP_DIR"
  PROJECT_ROOT="$TMP_DIR" bash "$REPO_ROOT/scripts/install-rev-harness-hooks.sh"
) >"$TMP_DIR/out.txt" 2>"$TMP_DIR/err.txt"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  printf 'FAIL: installer succeeded without --harness-root\n' >&2
  exit 1
fi

if ! grep -Fq 'harness-root required' "$TMP_DIR/err.txt"; then
  printf 'FAIL: stderr did not mention harness-root required\n' >&2
  cat "$TMP_DIR/err.txt" >&2
  exit 1
fi

printf 'PASS: install hooks fails closed without --harness-root\n'
