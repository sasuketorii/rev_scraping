#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
UPGRADE="$PROJECT_ROOT/scripts/rev-harness-upgrade.sh"
MANIFEST="$PROJECT_ROOT/.agent/registry/rev_harness_distribution_manifest.json"
TEST_TMP_ROOT="$(cd "${TMPDIR:-/tmp}" && pwd -P)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_jq() {
  local json="$1"
  local filter="$2"
  local message="$3"

  printf '%s\n' "$json" | jq -e "$filter" >/dev/null || fail "$message"
}

make_legacy_fixture() {
  local target="$1"

  mkdir -p \
    "$target/.agent/active" \
    "$target/.claude/commands" \
    "$target/.codex" \
    "$target/.harness/agent-base" \
    "$target/.shared"

  printf '# agent_base legacy fixture\n' > "$target/AGENTS.md"
  printf 'legacy agent-base context\n' > "$target/.agent/PROJECT_CONTEXT.md"
  printf 'pid-fixture-123\n' > "$target/.shared/project_id"
  printf 'legacy command\n' > "$target/.claude/commands/legacy.md"
  printf 'model = "legacy"\n' > "$target/.codex/config.toml"
  jq -n '{name: "agent_base", version: "0.10.0"}' > "$target/.harness/agent-base/install.json"

  git -C "$target" init -q
  git -C "$target" add .
  git -C "$target" -c user.name='Test User' -c user.email='test@example.invalid' commit -qm 'legacy baseline'
}

test_manifest_contract() {
  jq empty "$MANIFEST"
  jq -e '
    .schema_version == "rev-harness-distribution-manifest/v1"
    and .canonical.display_name == "Revharness"
    and .canonical.machine_name == "rev_harness"
    and (.legacy_aliases | index("agent_base"))
    and (.legacy_aliases | index("agent-base"))
    and .source_url == "TBD"
    and .preserve_globs_semantics == "adoption-local-preserve-only"
    and (.preserve_globs | index(".shared/project_id"))
    and (.client_distribution.exclude_globs | index(".agent/archive/**"))
    and (.client_distribution.exclude_globs | index(".claude/tmp/**"))
    and (.client_distribution.exclude_globs | index("workspace/**"))
    and .client_distribution.ship_semantic_db == false
    and (.managed_candidate_globs | index(".claude/commands/**"))
    and (.merge_globs | index("AGENTS.md"))
  ' "$MANIFEST" >/dev/null || fail "manifest contract mismatch"
}

test_inspect_json_detects_legacy_state() {
  local tmp target inspect_json
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-inspect.XXXXXX")"
  target="$tmp/legacy"
  mkdir -p "$target"
  make_legacy_fixture "$target"

  inspect_json="$(bash "$UPGRADE" inspect --target "$target" --json)"

  assert_jq "$inspect_json" '.schema_version == "rev-harness-upgrade-inspect/v1"' "inspect schema mismatch"
  assert_jq "$inspect_json" '.git.is_repo == true' "inspect should detect git repo"
  assert_jq "$inspect_json" '.presence.agents_md == true' "inspect should detect AGENTS.md"
  assert_jq "$inspect_json" '.presence.agent_dir == true' "inspect should detect .agent"
  assert_jq "$inspect_json" '.presence.claude_dir == true' "inspect should detect .claude"
  assert_jq "$inspect_json" '.presence.codex_dir == true' "inspect should detect .codex"
  assert_jq "$inspect_json" '.presence.shared_project_id == true' "inspect should detect .shared/project_id"
  assert_jq "$inspect_json" '.project_id.value == "pid-fixture-123"' "inspect should preserve project_id value"
  assert_jq "$inspect_json" '.install_state.present == true and .install_state.version == "0.10.0"' "inspect should read install state"
  assert_jq "$inspect_json" '[.legacy_name_hits[].path] | index("AGENTS.md")' "inspect should report legacy name hits"
}

test_plan_json_preserves_project_id_and_blocks_dirty_managed_path() {
  local tmp target plan_file plan_json
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-plan.XXXXXX")"
  target="$tmp/legacy"
  mkdir -p "$target"
  make_legacy_fixture "$target"
  plan_file="$target/.claude/plan.json"
  printf '\nmanaged local edit\n' >> "$target/.claude/commands/legacy.md"

  bash "$UPGRADE" plan --target "$target" --source-ref refs/tags/v0.11.0 --output "$plan_file"
  [[ -f "$plan_file" ]] || fail "plan output file was not written"
  plan_json="$(cat "$plan_file")"

  assert_jq "$plan_json" '.schema_version == "rev-harness-upgrade-plan/v1"' "plan schema mismatch"
  assert_jq "$plan_json" '.from_version == "legacy"' "plan should classify legacy source"
  assert_jq "$plan_json" '.to_name == "rev_harness"' "plan target name mismatch"
  assert_jq "$plan_json" '.source_ref == "refs/tags/v0.11.0"' "plan source ref mismatch"
  assert_jq "$plan_json" '.apply.implemented == false and .apply.allowed == false' "plan should be inspect/plan only"
  assert_jq "$plan_json" '.preserve_paths | index(".shared/project_id")' "plan should preserve project_id path"
  assert_jq "$plan_json" '.client_distribution.exclude_globs | index(".claude/tmp/**")' "plan should expose client distribution exclusions"
  assert_jq "$plan_json" '.managed_candidate_paths | index(".claude/commands/legacy.md")' "plan should include managed candidate path"
  assert_jq "$plan_json" '.blockers[] | select(.code == "dirty_managed_path" and .path == ".claude/commands/legacy.md")' "plan should block dirty managed path"
}

test_plan_blocks_deleted_tracked_managed_path() {
  local tmp target plan_json
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-deleted.XXXXXX")"
  target="$tmp/legacy"
  mkdir -p "$target"
  make_legacy_fixture "$target"
  git -C "$target" rm -q .claude/commands/legacy.md

  plan_json="$(bash "$UPGRADE" plan --target "$target" --source-ref refs/tags/v0.11.0)"

  assert_jq "$plan_json" '.managed_candidate_paths | index(".claude/commands/legacy.md")' "plan should retain deleted tracked managed path inventory"
  assert_jq "$plan_json" '.blockers[] | select(.code == "dirty_managed_path" and .path == ".claude/commands/legacy.md" and (.git_status | contains("D")))' "plan should block deleted tracked managed path"
}

test_plan_blocks_renamed_tracked_managed_path() {
  local tmp target plan_json
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-renamed.XXXXXX")"
  target="$tmp/legacy"
  mkdir -p "$target"
  make_legacy_fixture "$target"
  git -C "$target" mv .claude/commands/legacy.md .claude/commands/renamed.md

  plan_json="$(bash "$UPGRADE" plan --target "$target" --source-ref refs/tags/v0.11.0)"

  assert_jq "$plan_json" '.managed_candidate_paths | index(".claude/commands/legacy.md")' "plan should retain renamed tracked managed path inventory"
  assert_jq "$plan_json" '.blockers[] | select(.code == "dirty_managed_path" and (.path | contains(".claude/commands/legacy.md")) and (.git_status | contains("R")))' "plan should block renamed tracked managed path"
}

test_inspect_and_plan_stdout_do_not_mutate_target() {
  local tmp target before after
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-readonly.XXXXXX")"
  target="$tmp/legacy"
  mkdir -p "$target"
  make_legacy_fixture "$target"

  before="$(git -C "$target" status --porcelain=v1 --untracked-files=all)"
  bash "$UPGRADE" inspect --target "$target" --json >/dev/null
  bash "$UPGRADE" plan --target "$target" --source-ref refs/tags/v0.11.0 >/dev/null
  after="$(git -C "$target" status --porcelain=v1 --untracked-files=all)"

  [[ "$before" == "$after" ]] || fail "inspect/plan stdout should not mutate target"
}

test_output_rejects_target_outside_absolute_path() {
  local tmp target outside
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-output-outside.XXXXXX")"
  target="$tmp/legacy"
  outside="$tmp/outside-plan.json"
  mkdir -p "$target"
  make_legacy_fixture "$target"

  if bash "$UPGRADE" plan --target "$target" --source-ref refs/tags/v0.11.0 --output "$outside" >/dev/null 2>&1; then
    fail "plan should reject absolute output outside target"
  fi
  [[ ! -e "$outside" ]] || fail "rejected outside output should not be written"
}

test_output_rejects_parent_symlink_escape() {
  local tmp target escape link_output
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-output-symlink.XXXXXX")"
  target="$tmp/legacy"
  escape="$tmp/escape"
  mkdir -p "$target" "$escape"
  make_legacy_fixture "$target"
  ln -s "$escape" "$target/.claude/tmp-link"
  link_output="$target/.claude/tmp-link/plan.json"

  if bash "$UPGRADE" plan --target "$target" --source-ref refs/tags/v0.11.0 --output "$link_output" >/dev/null 2>&1; then
    fail "plan should reject output with symlink parent component"
  fi
  [[ ! -e "$escape/plan.json" ]] || fail "symlink escape output should not be written"
}

test_symlink_target_and_component_are_rejected() {
  local tmp real target_link parent_link
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-target-symlink.XXXXXX")"
  real="$tmp/real/legacy"
  mkdir -p "$real" "$tmp/links"
  make_legacy_fixture "$real"
  ln -s "$real" "$tmp/link-target"
  ln -s "$tmp/real" "$tmp/links/real-link"
  target_link="$tmp/link-target"
  parent_link="$tmp/links/real-link/legacy"

  if bash "$UPGRADE" inspect --target "$target_link" --json >/dev/null 2>&1; then
    fail "inspect should reject symlink target"
  fi
  if bash "$UPGRADE" plan --target "$target_link" --source-ref refs/tags/v0.11.0 >/dev/null 2>&1; then
    fail "plan should reject symlink target"
  fi
  if bash "$UPGRADE" inspect --target "$parent_link" --json >/dev/null 2>&1; then
    fail "inspect should reject symlink target component"
  fi
  if bash "$UPGRADE" plan --target "$parent_link" --source-ref refs/tags/v0.11.0 >/dev/null 2>&1; then
    fail "plan should reject symlink target component"
  fi
}

test_apply_fails_closed_without_mutation() {
  local tmp target before after
  tmp="$(mktemp -d "$TEST_TMP_ROOT/rev-harness-upgrade-apply.XXXXXX")"
  target="$tmp/legacy"
  mkdir -p "$target"
  make_legacy_fixture "$target"

  before="$(git -C "$target" status --porcelain=v1 --untracked-files=all)"
  if bash "$UPGRADE" apply --target "$target" --source-ref refs/tags/v0.11.0 >/tmp/rev-harness-upgrade-apply.out 2>/tmp/rev-harness-upgrade-apply.err; then
    fail "apply should fail closed"
  fi
  after="$(git -C "$target" status --porcelain=v1 --untracked-files=all)"
  [[ "$before" == "$after" ]] || fail "apply placeholder should not mutate target"
  [[ ! -e "$target/.harness/rev-harness" ]] || fail "apply placeholder should not create rev-harness state"
}

test_manifest_contract
test_inspect_json_detects_legacy_state
test_plan_json_preserves_project_id_and_blocks_dirty_managed_path
test_plan_blocks_deleted_tracked_managed_path
test_plan_blocks_renamed_tracked_managed_path
test_inspect_and_plan_stdout_do_not_mutate_target
test_output_rejects_target_outside_absolute_path
test_output_rejects_parent_symlink_escape
test_symlink_target_and_component_are_rejected
test_apply_fails_closed_without_mutation

printf 'PASS: rev_harness_upgrade_test\n'
