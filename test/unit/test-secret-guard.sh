#!/usr/bin/env bash
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WRAPPER="$REPO_ROOT/scripts/rev-harness-secret-guard.sh"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/secret-guard-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_ROOT"
}
trap cleanup EXIT

pass() {
  printf 'PASS: %s\n' "$1"
  PASS=$((PASS + 1))
}

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  FAIL=$((FAIL + 1))
}

assert_contains() {
  local name="$1"
  local haystack="$2"
  local needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name (missing: $needle)"
  fi
}

assert_file_contains() {
  local name="$1"
  local path="$2"
  local needle="$3"
  if [[ -f "$path" ]] && grep -Fq -- "$needle" "$path"; then
    pass "$name"
  else
    fail "$name (missing file text: $needle)"
  fi
}

assert_file_absent() {
  local name="$1"
  local path="$2"
  if [[ ! -e "$path" ]]; then
    pass "$name"
  else
    fail "$name (unexpected path exists: $path)"
  fi
}

assert_exit() {
  local name="$1"
  local expected="$2"
  shift 2
  "$@" >/dev/null 2>&1
  local rc=$?
  if [[ "$rc" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name (exit=$rc expected=$expected)"
  fi
}

make_repo() {
  local name="$1"
  local repo="$TMP_ROOT/$name"
  mkdir -p "$repo"
  git -C "$repo" init -q
  printf '%s\n' "sample" > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name=Test -c user.email=test@example.invalid commit -qm init
  printf '%s\n' "$repo"
}

write_fake_agent_core() {
  local path="$1"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" > "${SECRET_GUARD_FAKE_ARGS_OUT:?}"
case "$*" in
  "secret scan --json"|"secret scan --files README.md --json")
    printf '{"schema_version":1,"findings":[]}\n'
    exit 0
    ;;
  *)
    printf 'fake-agent-core args: %s\n' "$*"
    exit "${SECRET_GUARD_FAKE_EXIT:-0}"
    ;;
esac
EOF
  chmod +x "$path"
}

FAKE_AGENT_CORE="$TMP_ROOT/fake-agent-core.sh"
FAKE_ARGS="$TMP_ROOT/fake-args.txt"
write_fake_agent_core "$FAKE_AGENT_CORE"

# 1. --help renders Usage.
help_output="$("$WRAPPER" --help 2>&1)"
assert_contains "--help renders Usage" "$help_output" "Usage:"

# 2. check --json exit 0 on clean repo via agent-core smoke.
SECRET_GUARD_AGENT_CORE_BIN="$FAKE_AGENT_CORE" \
SECRET_GUARD_FAKE_ARGS_OUT="$FAKE_ARGS" \
  "$WRAPPER" check --json >/dev/null 2>&1
rc=$?
if [[ "$rc" == "0" ]] && [[ "$(cat "$FAKE_ARGS")" == "secret scan --json" ]]; then
  pass "check --json exit 0 on clean repo"
else
  fail "check --json exit 0 on clean repo (exit=$rc args=$(cat "$FAKE_ARGS" 2>/dev/null))"
fi

# 3. check --staged-only passthrough.
SECRET_GUARD_AGENT_CORE_BIN="$FAKE_AGENT_CORE" \
SECRET_GUARD_FAKE_ARGS_OUT="$FAKE_ARGS" \
  "$WRAPPER" check --staged-only >/dev/null 2>&1
if [[ "$(cat "$FAKE_ARGS")" == "secret scan --staged-only" ]]; then
  pass "check --staged-only passthrough"
else
  fail "check --staged-only passthrough"
fi

# 4. check --files <path> passthrough.
SECRET_GUARD_AGENT_CORE_BIN="$FAKE_AGENT_CORE" \
SECRET_GUARD_FAKE_ARGS_OUT="$FAKE_ARGS" \
  "$WRAPPER" check --files README.md >/dev/null 2>&1
if [[ "$(cat "$FAKE_ARGS")" == "secret scan --files README.md" ]]; then
  pass "check --files passthrough"
else
  fail "check --files passthrough"
fi

# 5. install-hook pre-commit dry-run prints body and does not write.
repo="$(make_repo dry_run_pre_commit)"
dry_output="$(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" install-hook --type pre-commit --dry-run 2>&1)"
assert_contains "pre-commit dry-run renders staged body" "$dry_output" "check --staged-only"
assert_file_absent "pre-commit dry-run does not write hook" "$repo/.git/hooks/pre-commit"

# 6. install-hook pre-push dry-run prints hook-stdin path.
repo="$(make_repo dry_run_pre_push)"
dry_push_output="$(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" install-hook --type pre-push --dry-run 2>&1)"
assert_contains "pre-push dry-run renders hook-stdin body" "$dry_push_output" "check --hook-stdin pre-push"

# 7. install-hook pre-commit creates managed hook; managed reinstall is idempotent overwrite.
repo="$(make_repo install_managed)"
(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" install-hook --type pre-commit) >/dev/null 2>&1
assert_file_contains "install-hook creates pre-commit marker" "$repo/.git/hooks/pre-commit" "# revharness-secret-guard v1"
assert_exit "managed pre-commit reinstall succeeds" 0 bash -c 'cd "$1" && REV_HARNESS_CANONICAL_ROOT="$2" "$3" install-hook --type pre-commit' _ "$repo" "$REPO_ROOT" "$WRAPPER"

# 8. install-hook --force backs up non-managed hook and overwrites.
repo="$(make_repo force_backup)"
printf '%s\n' '#!/usr/bin/env bash' 'echo legacy' > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" install-hook --type pre-commit --force) >/dev/null 2>&1
backup_count="$(find "$repo/.git/hooks" -maxdepth 1 -type f -name 'pre-commit.before-harness-*' | wc -l | tr -d ' ')"
if [[ "$backup_count" == "1" ]] && grep -Fq "# revharness-secret-guard v1" "$repo/.git/hooks/pre-commit" 2>/dev/null; then
  pass "install-hook --force backs up and overwrites"
else
  fail "install-hook --force backs up and overwrites"
fi

# 9. uninstall-hook removes managed hook.
repo="$(make_repo uninstall_managed)"
(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" install-hook --type pre-commit) >/dev/null 2>&1
(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" uninstall-hook --type pre-commit) >/dev/null 2>&1
assert_file_absent "uninstall-hook removes managed hook" "$repo/.git/hooks/pre-commit"

# 10. uninstall-hook refuses non-managed hook.
repo="$(make_repo refuse_unmanaged)"
printf '%s\n' '#!/usr/bin/env bash' 'echo legacy' > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
assert_exit "uninstall-hook refuses non-managed hook" 1 bash -c 'cd "$1" && REV_HARNESS_CANONICAL_ROOT="$2" "$3" uninstall-hook --type pre-commit' _ "$repo" "$REPO_ROOT" "$WRAPPER"

# 11. uninstall-hook --restore-backup restores latest backup.
repo="$(make_repo restore_backup)"
printf '%s\n' '#!/usr/bin/env bash' 'echo legacy' > "$repo/.git/hooks/pre-commit"
chmod +x "$repo/.git/hooks/pre-commit"
(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" install-hook --type pre-commit --force) >/dev/null 2>&1
(cd "$repo" && REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$WRAPPER" uninstall-hook --type pre-commit --restore-backup) >/dev/null 2>&1
assert_file_contains "uninstall-hook --restore-backup restores legacy hook" "$repo/.git/hooks/pre-commit" "echo legacy"

# 12. unknown subcommand fail-closed exit 1.
assert_exit "unknown subcommand exits 1" 1 "$WRAPPER" does-not-exist

# 13. canonical guard fires from non-canonical vendored copy.
vendored="$TMP_ROOT/vendor"
mkdir -p "$vendored/scripts"
cp "$WRAPPER" "$vendored/scripts/rev-harness-secret-guard.sh"
cp "$REPO_ROOT/scripts/_canonical-guard.sh" "$vendored/scripts/_canonical-guard.sh"
chmod +x "$vendored/scripts/rev-harness-secret-guard.sh"
REV_HARNESS_CANONICAL_ROOT="$REPO_ROOT" "$vendored/scripts/rev-harness-secret-guard.sh" --help >/dev/null 2>&1
rc=$?
if [[ "$rc" == "70" ]]; then
  pass "canonical guard fires for vendored copy"
else
  fail "canonical guard fires for vendored copy (exit=$rc)"
fi

# 14. shell syntax pass.
assert_exit "bash -n secret guard wrapper" 0 bash -n "$WRAPPER"

printf -- '---\n'
printf 'Result: %s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" == "0" ]]
