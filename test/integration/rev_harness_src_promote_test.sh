#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROMOTE="$PROJECT_ROOT/scripts/rev-harness-src-promote.sh"
TMP_PARENT="$PROJECT_ROOT/.tmp-rev-harness-src-promote-test"
mkdir -p "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  rm -rf "$TMP_ROOT"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

fixture_path() {
  printf '%s/%s\n' "$TMP_ROOT" "$1"
}

make_fixture() {
  local name="$1"
  local fixture
  fixture="$(fixture_path "$name")"

  mkdir -p "$fixture/src/lib" "$fixture/target-repo"
  mkdir -p "$fixture/.agent" "$fixture/.claude" "$fixture/.codex" "$fixture/.agent_rules"
  mkdir -p "$fixture/.github" "$fixture/.shared"
  mkdir -p "$fixture/scripts" "$fixture/test/integration" "$fixture/tests/unit" "$fixture/docs"
  mkdir -p "$fixture/artifacts" "$fixture/evidence" "$fixture/tmp"

  printf 'console.log("ok");\n' >"$fixture/src/app.js"
  printf 'export const value = 1;\n' >"$fixture/src/lib/value.js"
  printf '{"state":true}\n' >"$fixture/.agent/state.json"
  printf 'harness docs\n' >"$fixture/docs/harness.md"
  printf '#!/usr/bin/env bash\n' >"$fixture/scripts/harness.sh"

  printf '%s\n' "$fixture"
}

run_promote() {
  local fixture="$1"
  shift
  (
    cd "$fixture"
    REV_HARNESS_SRC_PROMOTE_PROJECT_ROOT="$fixture" bash "$PROMOTE" "$@"
  )
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(printf '%s\n' "$json" | jq -r "$filter")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

assert_command_fails_without_stdout() {
  local test_name="$1"
  local fixture="$2"
  shift 2
  local stdout_file="$TMP_ROOT/${test_name}.out"
  local stderr_file="$TMP_ROOT/${test_name}.err"

  if run_promote "$fixture" "$@" >"$stdout_file" 2>"$stderr_file"; then
    fail "$test_name should fail"
  fi

  [[ ! -s "$stdout_file" ]] || fail "$test_name should not write stdout"
}

test_plan_lists_only_src_files() {
  local fixture=""
  local output=""
  fixture="$(make_fixture "only-src")"

  output="$(run_promote "$fixture" plan --target "$fixture/target-repo")"

  printf '%s\n' "$output" | jq empty || fail "plan output should be valid JSON"
  assert_json_field "$output" '.source_root' "$fixture/src"
  assert_json_field "$output" '.target_root' "$fixture/target-repo"
  assert_json_field "$output" '.included_files | length' "2"
  assert_json_field "$output" '.included_files | index("app.js") != null' "true"
  assert_json_field "$output" '.included_files | index("lib/value.js") != null' "true"
  assert_json_field "$output" '.included_files | any(startswith("../") or startswith(".agent/") or startswith("docs/") or startswith("scripts/"))' "false"
  assert_json_field "$output" '.excluded_harness_dirs | index(".agent") != null' "true"
  assert_json_field "$output" '.excluded_harness_dirs | index("scripts") != null' "true"
  assert_json_field "$output" '.source_tree.files | length' "2"
  assert_json_field "$output" '.source_tree.hash | type' "string"
}

test_output_writes_file_without_stdout() {
  local fixture=""
  local stdout_file=""
  local plan_file=""
  fixture="$(make_fixture "output-file")"
  stdout_file="$TMP_ROOT/output-file.stdout"
  plan_file="$TMP_ROOT/output-plan.json"

  run_promote "$fixture" plan --target "$fixture/target-repo" --output "$plan_file" >"$stdout_file"

  [[ ! -s "$stdout_file" ]] || fail "plan --output should not write stdout"
  jq empty "$plan_file" || fail "written plan should be valid JSON"
  assert_json_field "$(cat "$plan_file")" '.included_files | length' "2"
}

test_output_rejects_symlink_parent_escape() {
  local fixture=""
  local escape_dir=""
  local stdout_file=""
  local stderr_file=""
  fixture="$(make_fixture "output-symlink-parent")"
  escape_dir="$TMP_ROOT/output-escape"
  stdout_file="$TMP_ROOT/output-symlink-parent.stdout"
  stderr_file="$TMP_ROOT/output-symlink-parent.stderr"
  mkdir -p "$escape_dir"
  ln -s "$escape_dir" "$fixture/output-link"

  if run_promote "$fixture" plan --target "$fixture/target-repo" --output "$fixture/output-link/plan.json" >"$stdout_file" 2>"$stderr_file"; then
    fail "plan --output should reject symlink parent components"
  fi

  [[ ! -s "$stdout_file" ]] || fail "rejected symlink output should not write stdout"
  [[ ! -e "$escape_dir/plan.json" ]] || fail "rejected symlink output should not write through parent symlink"
}

test_output_rejects_symlink_directory_leaf_escape() {
  local fixture=""
  local escape_dir=""
  local stdout_file=""
  local stderr_file=""
  fixture="$(make_fixture "output-symlink-directory-leaf")"
  escape_dir="$TMP_ROOT/output-leaf-escape"
  stdout_file="$TMP_ROOT/output-symlink-directory-leaf.stdout"
  stderr_file="$TMP_ROOT/output-symlink-directory-leaf.stderr"
  mkdir -p "$escape_dir"
  ln -s "$escape_dir" "$fixture/outlink"

  if run_promote "$fixture" plan --target "$fixture/target-repo" --output "$fixture/outlink" >"$stdout_file" 2>"$stderr_file"; then
    fail "plan --output should reject symlink directory leaf"
  fi

  [[ ! -s "$stdout_file" ]] || fail "rejected symlink leaf output should not write stdout"
  [[ ! -e "$escape_dir/outlink" ]] || fail "rejected symlink leaf output should not write output in escape directory"
  if find "$escape_dir" -mindepth 1 -print -quit | grep -q .; then
    fail "rejected symlink leaf output should not leave tmp files in escape directory"
  fi
}

test_output_rejects_directory_leaf() {
  local fixture=""
  fixture="$(make_fixture "output-directory-leaf")"
  mkdir -p "$fixture/outdir"

  assert_command_fails_without_stdout "output-directory-leaf" "$fixture" plan --target "$fixture/target-repo" --output "$fixture/outdir"
}

test_empty_src_warns() {
  local fixture=""
  local output=""
  fixture="$(fixture_path "empty-src")"
  mkdir -p "$fixture/src" "$fixture/target-repo"

  output="$(run_promote "$fixture" plan --target "$fixture/target-repo")"

  assert_json_field "$output" '.included_files | length' "0"
  assert_json_field "$output" '.warnings[0].code' "empty_source"
}

test_rejects_target_inside_git() {
  local fixture=""
  fixture="$(make_fixture "git-target")"
  mkdir -p "$fixture/.git/objects"

  assert_command_fails_without_stdout "target-inside-git" "$fixture" plan --target "$fixture/.git/objects"
}

test_rejects_dangerous_target_case_variants() {
  local fixture=""
  fixture="$(make_fixture "dangerous-target-case-variants")"
  mkdir -p "$fixture/.Git/objects" "$fixture/.Agent" "$fixture/Test/integration"

  assert_command_fails_without_stdout "target-inside-git-case-variant" "$fixture" plan --target "$fixture/.Git/objects"
  assert_command_fails_without_stdout "target-dot-agent-case-variant" "$fixture" plan --target "$fixture/.Agent"
  assert_command_fails_without_stdout "target-test-case-variant" "$fixture" plan --target "$fixture/Test/integration"
}

test_rejects_dangerous_source_roots() {
  local fixture=""
  fixture="$(make_fixture "dangerous-source-roots")"
  mkdir -p "$fixture/.git/objects" "$fixture/src/.git/objects" "$fixture/src/tmp"

  assert_command_fails_without_stdout "source-dot-git" "$fixture" plan --source "$fixture/.git" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-dot-git-objects" "$fixture" plan --source "$fixture/.git/objects" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-src-dot-git-objects" "$fixture" plan --source "$fixture/src/.git/objects" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-src-tmp" "$fixture" plan --source "$fixture/src/tmp" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-dot-github" "$fixture" plan --source "$fixture/.github" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-dot-agent" "$fixture" plan --source "$fixture/.agent" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-dot-claude" "$fixture" plan --source "$fixture/.claude" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-dot-codex" "$fixture" plan --source "$fixture/.codex" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-dot-shared" "$fixture" plan --source "$fixture/.shared" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-scripts" "$fixture" plan --source "$fixture/scripts" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-test-integration" "$fixture" plan --source "$fixture/test/integration" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-tests" "$fixture" plan --source "$fixture/tests" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-docs" "$fixture" plan --source "$fixture/docs" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-artifacts" "$fixture" plan --source "$fixture/artifacts" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-evidence" "$fixture" plan --source "$fixture/evidence" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-tmp" "$fixture" plan --source "$fixture/tmp" --target "$fixture/target-repo"
}

test_rejects_dangerous_source_case_variants() {
  local fixture=""
  fixture="$(make_fixture "dangerous-source-case-variants")"
  mkdir -p "$fixture/src/.Git/objects" "$fixture/src/.Agent" "$fixture/src/Test/integration"
  mkdir -p "$fixture/src/.CLAUDE" "$fixture/src/.Codex"

  assert_command_fails_without_stdout "source-src-dot-git-case-variant" "$fixture" plan --source "$fixture/src/.Git/objects" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-src-dot-agent-case-variant" "$fixture" plan --source "$fixture/src/.Agent" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-src-test-case-variant" "$fixture" plan --source "$fixture/src/Test/integration" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-src-dot-claude-case-variant" "$fixture" plan --source "$fixture/src/.CLAUDE" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-src-dot-codex-case-variant" "$fixture" plan --source "$fixture/src/.Codex" --target "$fixture/target-repo"
}

test_rejects_dangerous_source_file_case_variants() {
  local fixture=""

  fixture="$(make_fixture "dangerous-source-file-dot-git-case-variant")"
  mkdir -p "$fixture/src/.Git/objects"
  printf 'danger\n' >"$fixture/src/.Git/objects/pack"
  assert_command_fails_without_stdout "source-file-dot-git-case-variant" "$fixture" plan --target "$fixture/target-repo"

  fixture="$(make_fixture "dangerous-source-file-dot-agent-case-variant")"
  mkdir -p "$fixture/src/.Agent"
  printf 'danger\n' >"$fixture/src/.Agent/state.json"
  assert_command_fails_without_stdout "source-file-dot-agent-case-variant" "$fixture" plan --target "$fixture/target-repo"

  fixture="$(make_fixture "dangerous-source-file-test-case-variant")"
  mkdir -p "$fixture/src/Test/integration"
  printf 'danger\n' >"$fixture/src/Test/integration/spec.sh"
  assert_command_fails_without_stdout "source-file-test-case-variant" "$fixture" plan --target "$fixture/target-repo"

  fixture="$(make_fixture "dangerous-source-file-dot-claude-case-variant")"
  mkdir -p "$fixture/src/.CLAUDE"
  printf 'danger\n' >"$fixture/src/.CLAUDE/settings.json"
  assert_command_fails_without_stdout "source-file-dot-claude-case-variant" "$fixture" plan --target "$fixture/target-repo"

  fixture="$(make_fixture "dangerous-source-file-dot-codex-case-variant")"
  mkdir -p "$fixture/src/.Codex"
  printf 'danger\n' >"$fixture/src/.Codex/config.toml"
  assert_command_fails_without_stdout "source-file-dot-codex-case-variant" "$fixture" plan --target "$fixture/target-repo"
}

test_rejects_source_symlink_component() {
  local fixture=""
  fixture="$(make_fixture "source-symlink")"
  ln -s "$fixture/src" "$fixture/src-link"

  assert_command_fails_without_stdout "source-symlink-component" "$fixture" plan --source "$fixture/src-link" --target "$fixture/target-repo"
}

test_rejects_source_project_root_and_outside_project() {
  local fixture=""
  local outside=""
  fixture="$(make_fixture "source-root-outside")"
  outside="$TMP_ROOT/outside-source"
  mkdir -p "$outside/.git/objects"

  assert_command_fails_without_stdout "source-project-root" "$fixture" plan --source "$fixture" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-outside-project" "$fixture" plan --source "$outside" --target "$fixture/target-repo"
  assert_command_fails_without_stdout "source-outside-dangerous" "$fixture" plan --source "$outside/.git/objects" --target "$fixture/target-repo"
}

test_rejects_target_equal_project_root() {
  local fixture=""
  fixture="$(make_fixture "project-root-target")"

  assert_command_fails_without_stdout "target-equals-project-root" "$fixture" plan --target "$fixture"
}

test_allows_project_root_target_with_explicit_plan_only_flag() {
  local fixture=""
  local output=""
  fixture="$(make_fixture "project-root-target-allowed")"

  output="$(run_promote "$fixture" plan --target "$fixture" --allow-target-project-root)"

  assert_json_field "$output" '.included_files | length' "2"
  assert_json_field "$output" '.warnings | any(.code == "target_equals_project_root_allowed_for_plan_only")' "true"
}

test_rejects_symlink_target_component() {
  local fixture=""
  fixture="$(make_fixture "symlink-target")"
  mkdir -p "$fixture/real-target"
  ln -s "$fixture/real-target" "$fixture/link-target"

  assert_command_fails_without_stdout "symlink-target" "$fixture" plan --target "$fixture/link-target"
}

test_rejects_non_directory_target() {
  local fixture=""
  fixture="$(make_fixture "file-target")"
  printf 'not a dir\n' >"$fixture/not-a-dir"

  assert_command_fails_without_stdout "non-directory-target" "$fixture" plan --target "$fixture/not-a-dir"
}

test_apply_fails_closed() {
  local fixture=""
  local plan_file=""
  fixture="$(make_fixture "apply-disabled")"
  plan_file="$TMP_ROOT/apply-disabled-plan.json"
  run_promote "$fixture" plan --target "$fixture/target-repo" --output "$plan_file"

  assert_command_fails_without_stdout "apply-disabled" "$fixture" apply --plan "$plan_file"
}

test_plan_lists_only_src_files
test_output_writes_file_without_stdout
test_output_rejects_symlink_parent_escape
test_output_rejects_symlink_directory_leaf_escape
test_output_rejects_directory_leaf
test_empty_src_warns
test_rejects_dangerous_source_roots
test_rejects_dangerous_source_case_variants
test_rejects_dangerous_source_file_case_variants
test_rejects_source_symlink_component
test_rejects_source_project_root_and_outside_project
test_rejects_target_inside_git
test_rejects_dangerous_target_case_variants
test_rejects_target_equal_project_root
test_allows_project_root_target_with_explicit_plan_only_flag
test_rejects_symlink_target_component
test_rejects_non_directory_target
test_apply_fails_closed

printf 'PASS: rev_harness_src_promote_test\n'
