#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'cd "$REPO_ROOT" >/dev/null 2>&1 || true; rm -rf "$TMP" >/dev/null 2>&1 || true' EXIT

mkdir -p "$TMP/scripts" "$TMP/.shared" "$TMP/.git/hooks" "$TMP/home"
cp "$REPO_ROOT/scripts/rev-harness-adopter-setup.sh" "$TMP/scripts/"
cp "$REPO_ROOT/scripts/_canonical-guard.sh" "$TMP/scripts/"
printf 'revharness-vendored-copy\n' > "$TMP/.shared/project_id"
chmod +x "$TMP/scripts/"*.sh

set +e
(
  cd "$TMP"
  export HOME="$TMP/home"
  export REVHARNESS_PARALLEL_QUIESCE=1
  export REV_HARNESS_VENDOR_CHECK=strict
  bash scripts/rev-harness-adopter-setup.sh setup >"$TMP/out" 2>"$TMP/err"
)
RC=$?
set -e

test "$RC" -eq 70
test ! -e "$TMP/.shared/rev-harness-adopter-setup.state.json"
grep -q 'strict: refusing to continue' "$TMP/err"
printf 'adopter_setup_vendored_copy_fail_closed: ok\n'
exit 0
