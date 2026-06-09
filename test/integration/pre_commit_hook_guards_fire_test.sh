#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ADOPTER="$(mktemp -d)"

cleanup() {
  /bin/rm -rf "$ADOPTER"
}
trap cleanup EXIT

git -C "$ADOPTER" init -q
git -C "$ADOPTER" config user.email "rev-harness-test@example.invalid"
git -C "$ADOPTER" config user.name "RevHarness Test"

(
  cd "$ADOPTER"
  PROJECT_ROOT="$ADOPTER" bash "$REPO_ROOT/scripts/install-rev-harness-hooks.sh" install \
    --adopter-root "$ADOPTER" \
    --harness-root "$REPO_ROOT" \
    --without-hsdi-hooks
) >/dev/null

printf '%s\n' '/Users/foo/dev/bar' > "$ADOPTER/leak.txt" # rev-harness-path-leak-guard: allow
git -C "$ADOPTER" add leak.txt

set +e
git -C "$ADOPTER" commit -m "test path leak guard" >"$ADOPTER/commit.out" 2>"$ADOPTER/commit.err"
rc=$?
set -e

if [[ "$rc" -eq 0 ]]; then
  printf 'FAIL: commit succeeded; expected pre-commit guard block\n' >&2
  cat "$ADOPTER/commit.out" >&2
  cat "$ADOPTER/commit.err" >&2
  exit 1
fi

if ! grep -Fq 'rev-harness-path-leak-guard' "$ADOPTER/commit.err"; then
  printf 'FAIL: commit stderr did not mention rev-harness-path-leak-guard\n' >&2
  cat "$ADOPTER/commit.err" >&2
  exit 1
fi

printf 'PASS: pre-commit path-leak guard blocks staged absolute home path\n'
