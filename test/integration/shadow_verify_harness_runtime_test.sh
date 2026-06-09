#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHADOW_VERIFY="$PROJECT_ROOT/.claude/commands/lib/shadow_verify.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_repo() {
  local repo="$1"

  mkdir -p "$repo/scripts" "$repo/.agent/registry"
  cp "$PROJECT_ROOT/scripts/harness-check-planner.sh" "$repo/scripts/harness-check-planner.sh"
  cp "$PROJECT_ROOT/scripts/harness-block-router.sh" "$repo/scripts/harness-block-router.sh"
  cp "$PROJECT_ROOT/.agent/registry/harness_operating_modes.json" "$repo/.agent/registry/harness_operating_modes.json"
  cp "$PROJECT_ROOT/.agent/registry/harness_block_routing.json" "$repo/.agent/registry/harness_block_routing.json"
  chmod +x "$repo/scripts/harness-check-planner.sh" "$repo/scripts/harness-block-router.sh"

  cat > "$repo/scripts/quality_gate.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$repo/scripts/quality_gate.sh"

  cat > "$repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'base\n'
EOF

  git -C "$repo" init -q
  git -C "$repo" config user.email "shadow-verify-test@example.invalid"
  git -C "$repo" config user.name "Shadow Verify Test"
  git -C "$repo" add .
  git -C "$repo" commit -qm "initial"
}

run_shadow_verify() {
  local repo="$1"
  (
    export SHADOW_VERIFY_SAST_ENABLED=false
    source "$SHADOW_VERIFY"
    shadow_verify_run --phase impl --iter 1 --workdir "$repo" --gate levelB
  )
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(jq -r "$filter" <<< "$json")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

write_planner() {
  local repo="$1"
  local command="$2"

  cat > "$repo/scripts/harness-check-planner.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '$command'
EOF
  chmod +x "$repo/scripts/harness-check-planner.sh"
}

assert_planned_command_disallowed() {
  local result="$1"
  local command="$2"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.harness_check_planner.status' "fail"
  assert_json_field "$result" '.harness_check_planner.reason' "planned_command_disallowed"
  assert_json_field "$result" ".harness_check_planner.results[] | select(.command == \"$command\") | .reason" "planned_command_disallowed"
  assert_json_field "$result" ".harness_check_planner.results[] | select(.command == \"$command\") | .exit_code" "126"
}

test_planner_commands_run_on_changed_files() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF

  local result=""
  result="$(run_shadow_verify "$tmpdir/repo")" || fail "shadow verify should pass with valid planned checks"

  assert_json_field "$result" '.status' "pass"
  assert_json_field "$result" '.harness_check_planner.status' "pass"
  assert_json_field "$result" '.harness_check_planner.mode' "review"
  assert_json_field "$result" '(.harness_check_planner.commands | index("bash -n -- scripts/runtime_target.sh") != null)' "true"
  assert_json_field "$result" '(.harness_check_planner.command_count >= 1)' "true"

  local details=""
  details="$(jq -r '.details' <<< "$result")"
  grep -Fq "### [HARNESS_CHECK_PLANNER]" "$details" \
    || fail "details log should include harness planner section"
}

test_planned_check_failure_records_block_route() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
if then
EOF

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should fail when a planned check fails"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.harness_check_planner.status' "fail"
  assert_json_field "$result" '.harness_check_planner.reason' "planned_check_failed"
  assert_json_field "$result" '.harness_check_planner.block_route.block_type' "code-block"
  assert_json_field "$result" '.harness_check_planner.block_route.route_owner' "coder"
}

test_planner_missing_fails_closed() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  /bin/rm -f "$tmpdir/repo/scripts/harness-check-planner.sh"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should fail when planner is missing"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.harness_check_planner.status' "fail"
  assert_json_field "$result" '.harness_check_planner.reason' "planner_missing"
  assert_json_field "$result" '.harness_check_planner.block_route.block_type' "code-block"
}

test_planner_rejects_traversal_runtime_command() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF
  local command="bash -- test/integration/../../scripts/quality_gate.sh"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject traversal planned command"

  assert_planned_command_disallowed "$result" "$command"
}

test_planner_rejects_absolute_json_path() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF
  local command="jq empty -- /dev/zero"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject absolute planned path"

  assert_planned_command_disallowed "$result" "$command"
}

test_planner_rejects_changed_files_outside_set() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF
  local command="bash -n -- scripts/quality_gate.sh"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject planned path outside changed-files set"

  assert_planned_command_disallowed "$result" "$command"
}

test_planner_allows_diff_metadata_for_tracked_deletion() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mkdir -p "$tmpdir/repo/docs"
  printf 'delete me\n' > "$tmpdir/repo/docs/delete_me.md"
  git -C "$tmpdir/repo" add docs/delete_me.md
  git -C "$tmpdir/repo" commit -qm "add deletable doc"
  /bin/rm -f "$tmpdir/repo/docs/delete_me.md"

  local result=""
  result="$(run_shadow_verify "$tmpdir/repo")" || fail "shadow verify should pass diff metadata checks for tracked deletion"

  assert_json_field "$result" '.status' "pass"
  assert_json_field "$result" '.harness_check_planner.status' "pass"
  assert_json_field "$result" '(.harness_check_planner.commands | index("git diff --check -- docs/delete_me.md") != null)' "true"
  assert_json_field "$result" '(.harness_check_planner.commands | index("git diff --stat -- docs/delete_me.md") != null)' "true"
  assert_json_field "$result" '([.harness_check_planner.results[] | select(.reason == "planned_command_disallowed")] | length)' "0"
}

test_planner_diff_check_fails_for_untracked_trailing_whitespace() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mkdir -p "$tmpdir/repo/docs"
  printf 'untracked trailing space \n' > "$tmpdir/repo/docs/untracked.md"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should fail diff check for untracked trailing whitespace"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.harness_check_planner.status' "fail"
  assert_json_field "$result" '.harness_check_planner.reason' "planned_check_failed"
  assert_json_field "$result" '(.harness_check_planner.commands | index("git diff --check -- docs/untracked.md") != null)' "true"
  assert_json_field "$result" '.harness_check_planner.results[] | select(.command == "git diff --check -- docs/untracked.md") | .status' "fail"
  assert_json_field "$result" '.harness_check_planner.results[] | select(.command == "git diff --check -- docs/untracked.md") | .reason' "planned_check_failed"
}

test_planner_rejects_missing_shell_runtime_command() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  /bin/rm -f "$tmpdir/repo/scripts/runtime_target.sh"
  local command="bash -n -- scripts/runtime_target.sh"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject missing shell runtime command"

  assert_planned_command_disallowed "$result" "$command"
}

test_planner_rejects_missing_json_runtime_command() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mkdir -p "$tmpdir/repo/config"
  printf '{}\n' > "$tmpdir/repo/config/runtime.json"
  git -C "$tmpdir/repo" add config/runtime.json
  git -C "$tmpdir/repo" commit -qm "add runtime json"
  /bin/rm -f "$tmpdir/repo/config/runtime.json"
  local command="jq empty -- config/runtime.json"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject missing json runtime command"

  assert_planned_command_disallowed "$result" "$command"
}

test_planner_rejects_external_shell_symlink_without_execution() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mkdir -p "$tmpdir/repo/test/integration"
  cat > "$tmpdir/evil.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$tmpdir/executed"
EOF
  chmod +x "$tmpdir/evil.sh"
  ln -s "$tmpdir/evil.sh" "$tmpdir/repo/test/integration/evil.sh"

  local command="bash -- test/integration/evil.sh"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject external shell symlink"
  [[ ! -e "$tmpdir/executed" ]] || fail "external shell symlink target should not execute"

  assert_planned_command_disallowed "$result" "$command"
}

test_planner_rejects_external_json_symlink() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mkdir -p "$tmpdir/repo/test/fixtures"
  printf '{}\n' > "$tmpdir/external.json"
  ln -s "$tmpdir/external.json" "$tmpdir/repo/test/fixtures/evil.json"

  local command="jq empty -- test/fixtures/evil.json"
  write_planner "$tmpdir/repo" "$command"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject external json symlink"

  assert_planned_command_disallowed "$result" "$command"
}

test_rejects_external_planner_symlink_without_execution() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF
  cat > "$tmpdir/evil-planner.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$tmpdir/planner-executed"
printf '%s\n' 'bash -n -- scripts/runtime_target.sh'
EOF
  chmod +x "$tmpdir/evil-planner.sh"
  /bin/rm -f "$tmpdir/repo/scripts/harness-check-planner.sh"
  ln -s "$tmpdir/evil-planner.sh" "$tmpdir/repo/scripts/harness-check-planner.sh"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should reject external planner symlink"
  [[ ! -e "$tmpdir/planner-executed" ]] || fail "external planner symlink target should not execute"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.harness_check_planner.status' "fail"
  assert_json_field "$result" '.harness_check_planner.reason' "planner_untrusted"
}

test_rejects_external_router_symlink_without_execution() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  cat > "$tmpdir/repo/scripts/runtime_target.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'changed\n'
EOF
  cat > "$tmpdir/evil-router.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$tmpdir/router-executed"
printf '%s\n' '{"block_type":"code-block","route_owner":"attacker"}'
EOF
  chmod +x "$tmpdir/evil-router.sh"
  /bin/rm -f "$tmpdir/repo/scripts/harness-block-router.sh"
  ln -s "$tmpdir/evil-router.sh" "$tmpdir/repo/scripts/harness-block-router.sh"

  local result=""
  local rc=0
  result="$(run_shadow_verify "$tmpdir/repo")" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "shadow verify should fail closed with external router symlink"
  [[ ! -e "$tmpdir/router-executed" ]] || fail "external router symlink target should not execute"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.harness_check_planner.status' "fail"
  assert_json_field "$result" '.harness_check_planner.block_route.route_error' "harness_block_router_unavailable"
}

test_rejects_scripts_component_symlink_for_fixed_planner_router_without_execution() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mv "$tmpdir/repo/scripts" "$tmpdir/repo/evil-scripts"
  ln -s evil-scripts "$tmpdir/repo/scripts"

  cat > "$tmpdir/repo/evil-scripts/harness-check-planner.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$tmpdir/planner-executed"
printf '%s\n' 'bash -n -- scripts/runtime_target.sh'
EOF
  chmod +x "$tmpdir/repo/evil-scripts/harness-check-planner.sh"

  cat > "$tmpdir/repo/evil-scripts/harness-block-router.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
touch "$tmpdir/router-executed"
printf '%s\n' '{"block_type":"code-block","route_owner":"attacker"}'
EOF
  chmod +x "$tmpdir/repo/evil-scripts/harness-block-router.sh"

  local result=""
  local rc=0
  result="$(
    export SHADOW_VERIFY_SAST_ENABLED=false
    source "$SHADOW_VERIFY"
    mkdir -p "$tmpdir/repo/.claude/tmp/direct"
    _shadow_verify_run_harness_check_planner "$tmpdir/repo" "scripts/runtime_target.sh" "$tmpdir/repo/.claude/tmp/direct" "scripts-component"
  )" || rc=$?
  [[ "$rc" -ne 0 ]] || fail "fixed planner should reject scripts component symlink"
  [[ ! -e "$tmpdir/planner-executed" ]] || fail "planner under scripts component symlink should not execute"
  [[ ! -e "$tmpdir/router-executed" ]] || fail "router under scripts component symlink should not execute"

  assert_json_field "$result" '.status' "fail"
  assert_json_field "$result" '.reason' "planner_untrusted"
  assert_json_field "$result" '.block_route.route_error' "harness_block_router_unavailable"
}

test_rejects_scripts_component_symlink_for_projection_preflight() {
  local tmpdir=""
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  make_repo "$tmpdir/repo"
  mv "$tmpdir/repo/scripts" "$tmpdir/repo/evil-scripts"
  ln -s evil-scripts "$tmpdir/repo/scripts"

  cat > "$tmpdir/repo/evil-scripts/harness-projection-preflight.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF
  chmod +x "$tmpdir/repo/evil-scripts/harness-projection-preflight.sh"

  if (
    source "$SHADOW_VERIFY"
    _shadow_verify_prepare_planned_command "$tmpdir/repo" ".agent/registry/orchestration_policy_projection.json" "bash scripts/harness-projection-preflight.sh --validate"
  ); then
    fail "projection preflight should reject scripts component symlink"
  fi
}

test_planner_commands_run_on_changed_files
test_planned_check_failure_records_block_route
test_planner_missing_fails_closed
test_planner_rejects_traversal_runtime_command
test_planner_rejects_absolute_json_path
test_planner_rejects_changed_files_outside_set
test_planner_allows_diff_metadata_for_tracked_deletion
test_planner_diff_check_fails_for_untracked_trailing_whitespace
test_planner_rejects_missing_shell_runtime_command
test_planner_rejects_missing_json_runtime_command
test_planner_rejects_external_shell_symlink_without_execution
test_planner_rejects_external_json_symlink
test_rejects_external_planner_symlink_without_execution
test_rejects_external_router_symlink_without_execution
test_rejects_scripts_component_symlink_for_fixed_planner_router_without_execution
test_rejects_scripts_component_symlink_for_projection_preflight

printf 'PASS: shadow_verify_harness_runtime_test\n'
