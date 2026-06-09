#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
ADOPTER="$(mktemp -d)"
FAKE_BIN_DIR="$(mktemp -d)"
ARG_LOG="$ADOPTER/agent-core-args.nul"

cleanup() {
  /bin/rm -rf "$ADOPTER" "$FAKE_BIN_DIR"
}
trap cleanup EXIT

cat >"$FAKE_BIN_DIR/agent-core" <<'FAKE'
#!/usr/bin/env bash
printf '%s\0' "$@" > "${ARG_LOG:?}"
printf 'fake-output %s/private\n' "${HOME:?}"
exit 0
FAKE
chmod +x "$FAKE_BIN_DIR/agent-core"

git -C "$ADOPTER" init -q
git -C "$ADOPTER" config user.email "rev-harness-test@example.invalid"
git -C "$ADOPTER" config user.name "RevHarness Test"
git -C "$ADOPTER" config commit.gpgsign false

mkdir -p "$ADOPTER/src"
printf 'pub fn first() {}\n' >"$ADOPTER/src/lib.rs"
git -C "$ADOPTER" add -A
git -C "$ADOPTER" commit -q -m "initial"

PROJECT_ROOT="$ADOPTER" bash "$REPO_ROOT/scripts/install-rev-harness-hooks.sh" install \
  --adopter-root "$ADOPTER" \
  --harness-root "$REPO_ROOT" \
  --without-hsdi-hooks \
  --with-index-hook >/dev/null

printf 'pub fn first() {}\npub fn second() {}\n' >"$ADOPTER/src/lib.rs"
git -C "$ADOPTER" add -A
REV_HARNESS_AGENT_CORE_BIN="$FAKE_BIN_DIR/agent-core" ARG_LOG="$ARG_LOG" \
  git -C "$ADOPTER" commit -q -m "second"

for _ in $(seq 1 50); do
  [[ -s "$ARG_LOG" ]] && break
  sleep 0.1
done

if [[ ! -s "$ARG_LOG" ]]; then
  printf 'FAIL: post-commit hook did not invoke fake agent-core\n' >&2
  exit 1
fi

args_text="$(tr '\0' ' ' <"$ARG_LOG")"
head_sha="$(git -C "$ADOPTER" rev-parse HEAD)"
base_sha="$(git -C "$ADOPTER" rev-parse HEAD^1)"

case "$args_text" in
  *"context index-commit"* ) ;;
  *) printf 'FAIL: missing context index-commit args: %s\n' "$args_text" >&2; exit 1 ;;
esac
case "$args_text" in
  *"--head $head_sha"* ) ;;
  *) printf 'FAIL: missing immutable --head %s in args: %s\n' "$head_sha" "$args_text" >&2; exit 1 ;;
esac
case "$args_text" in
  *"--base $base_sha"* ) ;;
  *) printf 'FAIL: missing immutable --base %s in args: %s\n' "$base_sha" "$args_text" >&2; exit 1 ;;
esac
case "$args_text" in
  *"--base HEAD^"* ) printf 'FAIL: hook still passes symbolic HEAD^: %s\n' "$args_text" >&2; exit 1 ;;
esac

log_file="$ADOPTER/.git/rev-harness/post-commit-index.log"
for _ in $(seq 1 50); do
  [[ -s "$log_file" ]] && break
  sleep 0.1
done

if [[ ! -s "$log_file" ]]; then
  printf 'FAIL: post-commit hook did not write bounded evidence log\n' >&2
  exit 1
fi

if grep -Fq "$HOME" "$log_file"; then
  printf 'FAIL: post-commit evidence log leaked HOME path\n' >&2
  cat "$log_file" >&2
  exit 1
fi
if ! grep -Fq '<home>/private' "$log_file"; then
  printf 'FAIL: post-commit evidence log did not contain redacted fake output\n' >&2
  cat "$log_file" >&2
  exit 1
fi

printf 'PASS: post-commit index hook pins commit refs and writes redacted bounded log\n'
