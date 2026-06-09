#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
EVIDENCE_DIR="$REPO_ROOT/.agent/active/plan_20260526_hsdi-phase-H/T-H-1"

mkdir -p "$EVIDENCE_DIR"

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_install_artifacts() {
  local sandbox="$1"
  local label="$2"
  [[ -f "$sandbox/.shared/project_id" ]] || fail "$label missing .shared/project_id"
  [[ -f "$sandbox/.claude/settings.json" ]] || fail "$label missing .claude/settings.json"
  [[ -f "$sandbox/.git/hooks/pre-commit" ]] || fail "$label missing .git/hooks/pre-commit"

  local project_id
  project_id="$(head -1 "$sandbox/.shared/project_id" | tr -d '\r' | sed 's/[[:space:]]*$//')"
  [[ -n "$project_id" ]] || fail "$label empty project_id"
  [[ "$project_id" != revharness-* ]] || fail "$label self-style project_id: $project_id"
}

new_git_sandbox() {
  local sandbox
  sandbox="$(mktemp -d)"
  git -C "$sandbox" init -q
  printf '%s\n' "$sandbox"
}

cleanup_paths=()
cleanup() {
  cd "$REPO_ROOT" >/dev/null 2>&1 || true
  local path
  for path in "${cleanup_paths[@]:-}"; do
    [[ -n "$path" ]] && /bin/rm -rf "$path" 2>/dev/null || true
  done
}
trap cleanup EXIT

export REVHARNESS_PARALLEL_QUIESCE=1
export REV_HARNESS_SMOKE_SKIP_HEAVY=1

pre_sha="$(sha256_file "$REPO_ROOT/scripts/rev-harness")"
printf '%s  scripts/rev-harness\n' "$pre_sha" > "$EVIDENCE_DIR/rev-harness-sha256-pre-install.txt"

sandbox_one="$(new_git_sandbox)"
cleanup_paths+=("$sandbox_one")

(
  cd "$REPO_ROOT"
  bash scripts/rev-harness install --target "$sandbox_one"
) >/tmp/rev-harness-target-root-s1.out 2>/tmp/rev-harness-target-root-s1.err
assert_install_artifacts "$sandbox_one" "scenario1"

post_sha="$(sha256_file "$REPO_ROOT/scripts/rev-harness")"
printf '%s  scripts/rev-harness\n' "$post_sha" > "$EVIDENCE_DIR/rev-harness-sha256-post-install.txt"
[[ "$pre_sha" == "$post_sha" ]] || fail "scenario1 mutated scripts/rev-harness"
printf 'PASS scenario1 --target install: %s\n' "$sandbox_one"

sandbox_two="$(new_git_sandbox)"
cleanup_paths+=("$sandbox_two")
(
  cd "$sandbox_two"
  bash "$REPO_ROOT/scripts/rev-harness" install
) >/tmp/rev-harness-target-root-s2.out 2>/tmp/rev-harness-target-root-s2.err
assert_install_artifacts "$sandbox_two" "scenario2"
printf 'PASS scenario2 cwd install: %s\n' "$sandbox_two"

self_err="$(mktemp)"
cleanup_paths+=("$self_err")
set +e
(
  cd "$REPO_ROOT"
  bash scripts/rev-harness install
) >/tmp/rev-harness-target-root-s3.out 2>"$self_err"
self_rc=$?
set -e
[[ "$self_rc" -eq 72 ]] || fail "scenario3 expected exit 72, got $self_rc"
grep -q 'refusing self-install' "$self_err" || fail "scenario3 missing refusing self-install stderr"
printf 'PASS scenario3 self-install guard: exit=%s\n' "$self_rc"

printf 'PASS target-root-resolution: all scenarios passed\n'
