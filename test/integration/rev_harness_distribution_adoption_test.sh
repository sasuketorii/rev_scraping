#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFLIGHT="$PROJECT_ROOT/scripts/rev-harness-distribution-adoption.sh"
TMP_ROOT=""

cleanup() {
  rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]]
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(printf '%s' "$json" | jq -r "$filter")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

write_skill_tree() {
  local dir="$1"

  mkdir -p "$dir/references"
  printf '%s\n' '---' 'name: rustskills-architecture' 'description: Example loader-compliant skill.' '---' '# RustSkills Architecture' \
    >"$dir/SKILL.md"
  printf '%s\n' 'reference body' >"$dir/references/reference.md"
}

setup_fixture() {
  local root="$1"
  local evidence_hash=""

  mkdir -p \
    "$root/.agent/registry" \
    "$root/.agent/skills" \
    "$root/.agent/generated/skills/codex" \
    "$root/.agent/active/sow" \
    "$root/.claude/skills" \
    "$root/codex-home/skills" \
    "$root/docs/manual"

  printf '%s\n' '# README' >"$root/README.md"
  printf '%s\n' '# Project Context' >"$root/.agent/PROJECT_CONTEXT.md"
  printf '%s\n' '# Harness User Guide' >"$root/docs/manual/harness-user-guide.md"
  printf '%s\n' 'base' >"$root/owned.txt"

  write_skill_tree "$root/.agent/skills/rustskills-architecture"
  cp -R "$root/.agent/skills/rustskills-architecture" "$root/.claude/skills/rustskills-architecture"
  cp -R "$root/.agent/skills/rustskills-architecture" "$root/.agent/generated/skills/codex/rustskills-architecture"
  cp -R "$root/.agent/skills/rustskills-architecture" "$root/codex-home/skills/rustskills-architecture"

  printf '%s\n' \
    '{' \
    '  "schema_version": "rev-harness-distribution-manifest/v1",' \
    '  "canonical": {"display_name": "Revharness", "machine_name": "rev_harness"},' \
    '  "legacy_aliases": ["agent_base", "agent-base"],' \
    '  "source_url": "TBD",' \
    '  "preserve_globs_semantics": "adoption-local-preserve-only",' \
    '  "preserve_globs": [".agent/PROJECT_CONTEXT.md", "src", "src/**"],' \
    '  "client_distribution": {' \
    '    "exclude_globs": [".agent/archive/**", ".claude/tmp/**", "workspace/**", "~/.semantic-mcp/*/semantic.db"],' \
    '    "ship_semantic_db": false,' \
    '    "semantic_db_regeneration": "Regenerate on first use."' \
    '  },' \
    '  "managed_candidate_globs": ["AGENTS.md", "scripts", "scripts/**"]' \
    '}' >"$root/.agent/registry/rev_harness_distribution_manifest.json"

  # shellcheck disable=SC2016
  printf '%s\n' \
    '{' \
    '  "schema_version": 2,' \
    '  "canonical_root": ".agent/skills",' \
    '  "loader_contract": {' \
    '    "required_file": "SKILL.md",' \
    '    "allowed_frontmatter_keys": ["name", "description"],' \
    '    "allowed_root_entries": ["SKILL.md", "agents", "assets", "references", "scripts"],' \
    '    "install_boundary": "Generated Codex projections are install-required unless installed into $CODEX_HOME/skills/<skill-name>."' \
    '  },' \
    '  "skills": [' \
    '    {' \
    '      "name": "rustskills-architecture",' \
    '      "canonical_source": {"path": ".agent/skills/rustskills-architecture", "role": "canonical-source"},' \
    '      "projections": [' \
    '        {' \
    '          "provider": "claude",' \
    '          "path": ".claude/skills/rustskills-architecture",' \
    '          "projection_kind": "byte-for-byte",' \
    '          "excluded_generated_metadata": [],' \
    '          "activation": {"status": "project-local-active", "auto_discoverable": true, "install_target": ".claude/skills/rustskills-architecture", "note": "Claude project-local skill projection."}' \
    '        },' \
    '        {' \
    '          "provider": "codex-generated",' \
    '          "path": ".agent/generated/skills/codex/rustskills-architecture",' \
    '          "projection_kind": "byte-for-byte",' \
    '          "excluded_generated_metadata": [],' \
    '          "activation": {"status": "install-required", "auto_discoverable": false, "install_target": "$CODEX_HOME/skills/rustskills-architecture", "note": "Generated Codex projection only."}' \
    '        },' \
    '        {' \
    '          "provider": "codex-installed",' \
    '          "path": "$CODEX_HOME/skills/rustskills-architecture",' \
    '          "projection_kind": "byte-for-byte",' \
    '          "excluded_generated_metadata": [],' \
    '          "activation": {"status": "installed-active", "auto_discoverable": true, "install_target": "$CODEX_HOME/skills/rustskills-architecture", "note": "Actual Codex skill home projection."}' \
    '        }' \
    '      ]' \
    '    }' \
    '  ]' \
    '}' >"$root/.agent/registry/skill_projection_manifest.json"

  mkdir -p "$root/.agent/active/sow/evidence"
  printf '%s\n' 'required evidence body' >"$root/.agent/active/sow/evidence/report.md"
  printf '%s\n' 'closed worker evidence' >"$root/.agent/active/sow/evidence/worker-closed.md"
  evidence_hash="$(hash_file "$root/.agent/active/sow/evidence/report.md")"

  printf '%s\n' \
    '{' \
    '  "schema_version": "rev-harness-dirty-surface/v1",' \
    '  "owned_review_set": ["owned.txt"],' \
    '  "paths": [' \
    '    {' \
    '      "path": "owned.txt",' \
    '      "owner": "distribution-test",' \
    '      "disposition": "owned by active slice",' \
    '      "include_in_review": true,' \
    '      "acceptance_relevant": true,' \
    '      "reason": "fixture dirty surface owned by adoption preflight test"' \
    '    }' \
    '  ],' \
    '  "hold_items": [],' \
    '  "expected_unrelated_paths": []' \
    '}' >"$root/.agent/active/sow/dirty-surface.json"
  jq -n --arg hash "$evidence_hash" '{
    schema_version: "rev-harness-evidence-manifest/v1",
    acceptance_eligible: true,
    artifacts: [
      {path: ".agent/active/sow/evidence/report.md", sha256: $hash, required: true}
    ],
    commands: [
      {command: "test -f .agent/active/sow/evidence/report.md", status: "PASS", required: true}
    ],
    reviewer_capsule: {
      plan_lgtm: {gate: "plan_lgtm", status: "LGTM", evidence_path: ".agent/active/sow/evidence/report.md"},
      implementation_lgtm: {gate: "implementation_lgtm", status: "pending", evidence_path: ".agent/active/sow/evidence/report.md"},
      security_lgtm: {gate: "security_lgtm", status: "not-requested", evidence_path: ".agent/active/sow/evidence/report.md"},
      release_acceptance: {gate: "release_acceptance", status: "not-attempted", evidence_path: ".agent/active/sow/evidence/report.md"}
    }
  }' >"$root/.agent/active/sow/evidence-manifest.json"
  jq -n '{
    schema_version: "rev-harness-worker-lifecycle/v1",
    workers: [
      {
        id: "worker-closed",
        state: "closed",
        spawned_at: "2026-04-30T00:00:00Z",
        completed_at: "2026-04-30T00:05:00Z",
        closed_at: "2026-04-30T00:06:00Z",
        artifact_paths: [".agent/active/sow/evidence/worker-closed.md"],
        runtime_observation: "not-observed"
      }
    ]
  }' >"$root/.agent/active/sow/worker-lifecycle.json"
  printf '%s\n' \
    '{' \
    '  "schema_version": "rev-harness-distribution-adoption-prerequisites/v1",' \
    '  "prerequisites": [' \
    '    {"name": "dirty surface manifest", "status": "present", "path": ".agent/active/sow/dirty-surface.json", "schema_version": "rev-harness-dirty-surface/v1"},' \
    '    {"name": "evidence manifest", "status": "present", "path": ".agent/active/sow/evidence-manifest.json", "schema_version": "rev-harness-evidence-manifest/v1"},' \
    '    {"name": "worker lifecycle manifest", "status": "present", "path": ".agent/active/sow/worker-lifecycle.json", "schema_version": "rev-harness-worker-lifecycle/v1"},' \
    '    {"name": "counter admission preflight", "status": "deferred", "reason": "not applicable to this fixture adoption packet"},' \
    '    {"name": "schema-micro-fix admission", "status": "BLOCK", "reason": "not a micro-fix fixture packet"}' \
    '  ]' \
    '}' >"$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.json"

  git -C "$root" init -q
  git -C "$root" config user.email "rev-harness@example.invalid"
  git -C "$root" config user.name "Rev Harness Test"
  git -C "$root" add .
  git -C "$root" commit -q -m "base"
  printf '%s\n' 'owned adoption preflight change' >>"$root/owned.txt"
}

run_preflight_for_root() {
  local root="$1"
  shift

  CODEX_HOME="$root/codex-home" bash "$PREFLIGHT" --root "$root" "$@"
}

write_placeholder_admission_prerequisite() {
  local root="$1"
  local name="$2"
  local path="$3"

  printf '%s\n' '{"schema_version":"rev-harness-admission-result/v1"}' >"$root/$path"
  jq \
    --arg name "$name" \
    --arg path "$path" \
    '(.prerequisites[] | select(.name == $name)) = {
      name: $name,
      status: "present",
      path: $path,
      schema_version: "rev-harness-admission-result/v1"
    }' \
    "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.json" \
    >"$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.tmp"
  mv "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.tmp" \
    "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.json"
  git -C "$root" add "$path" .agent/registry/rev_harness_distribution_adoption_prerequisites.json
  git -C "$root" commit -q -m "placeholder admission fixture"
}

test_fixture_passes_with_installed_codex_and_prerequisites() {
  local root="$TMP_ROOT/pass"
  local output=""

  setup_fixture "$root"
  output="$(run_preflight_for_root "$root" --check --json)"

  assert_json_field "$output" '.status' "PASS"
  assert_json_field "$output" '.adoption_enabled' "true"
  assert_json_field "$output" '.publish_enabled' "false"
  assert_json_field "$output" '.tag_enabled' "false"
  assert_json_field "$output" '.package_enabled' "false"
  assert_json_field "$output" '.skill_projection.acceptance_eligible' "true"
  assert_json_field "$output" '.skill_projection.projections[] | select(.provider == "codex-generated") | .activation_status' "install-required"
  assert_json_field "$output" '.skill_projection.projections[] | select(.provider == "codex-generated") | .auto_discoverable' "false"
  assert_json_field "$output" '.skill_projection.projections[] | select(.provider == "codex-installed") | .activation_status' "installed-active"
  assert_json_field "$output" '.prerequisites | length' "5"
}

test_missing_installed_codex_fails_closed() {
  local root="$TMP_ROOT/missing-installed"
  local output=""

  setup_fixture "$root"
  rm -rf "$root/codex-home/skills/rustskills-architecture"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-missing-installed.err")"; then
    fail "missing installed Codex skill should fail distribution/adoption preflight"
  fi

  assert_json_field "$output" '.status' "FAIL"
  assert_json_field "$output" '.adoption_enabled' "false"
  contains "$output" "skill projection acceptance check failed" \
    || fail "failure JSON should report skill projection failure"
}

test_missing_prerequisite_manifest_fails_closed() {
  local root="$TMP_ROOT/missing-prereq"
  local output=""

  setup_fixture "$root"
  rm -f "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.json"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-missing-prereq.err")"; then
    fail "missing prerequisite manifest should fail distribution/adoption preflight"
  fi

  assert_json_field "$output" '.status' "FAIL"
  assert_json_field "$output" '.adoption_enabled' "false"
  contains "$output" "missing prerequisite manifest evidence" \
    || fail "failure JSON should report missing prerequisite manifest evidence"
}

test_missing_client_distribution_exclude_fails_closed() {
  local root="$TMP_ROOT/missing-client-exclude"
  local output=""

  setup_fixture "$root"
  jq 'del(.client_distribution.exclude_globs)' \
    "$root/.agent/registry/rev_harness_distribution_manifest.json" \
    >"$root/.agent/registry/rev_harness_distribution_manifest.tmp"
  mv "$root/.agent/registry/rev_harness_distribution_manifest.tmp" \
    "$root/.agent/registry/rev_harness_distribution_manifest.json"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-missing-client-exclude.err")"; then
    fail "missing client distribution exclude globs should fail distribution/adoption preflight"
  fi

  assert_json_field "$output" '.status' "FAIL"
  assert_json_field "$output" '.adoption_enabled' "false"
  contains "$output" "invalid distribution manifest schema" \
    || fail "failure JSON should report invalid distribution manifest schema"
}

test_present_prerequisite_artifact_schema_mismatch_fails_closed() {
  local root="$TMP_ROOT/schema-mismatch"
  local output=""

  setup_fixture "$root"
  printf '%s\n' '{"schema_version":"wrong-schema","owned_review_set":[],"paths":[]}' \
    >"$root/.agent/active/sow/dirty-surface.json"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-schema-mismatch.err")"; then
    fail "prerequisite artifact schema mismatch should fail"
  fi

  assert_json_field "$output" '.status' "FAIL"
  contains "$output" "artifact schema does not match prerequisite evidence" \
    || fail "failure JSON should report prerequisite artifact schema mismatch"
}

test_empty_placeholder_prerequisite_artifacts_fail_closed() {
  local root="$TMP_ROOT/empty-placeholder"
  local output=""

  setup_fixture "$root"
  printf '%s\n' '{"schema_version":"rev-harness-evidence-manifest/v1"}' \
    >"$root/.agent/active/sow/evidence-manifest.json"
  git -C "$root" add .agent/active/sow/evidence-manifest.json
  git -C "$root" commit -q -m "empty evidence placeholder fixture"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-empty-placeholder.err")"; then
    fail "empty placeholder prerequisite artifacts should fail"
  fi

  assert_json_field "$output" '.status' "FAIL"
  contains "$output" "evidence manifest artifact is empty or lacks required fields" \
    || fail "failure JSON should reject empty placeholder prerequisite artifacts"
}

test_counter_admission_schema_only_placeholder_fails_closed() {
  local root="$TMP_ROOT/counter-admission-placeholder"
  local output=""

  setup_fixture "$root"
  write_placeholder_admission_prerequisite \
    "$root" \
    "counter admission preflight" \
    ".agent/active/sow/counter-admission-result.json"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-counter-admission-placeholder.err")"; then
    fail "schema_version-only counter admission artifact should fail"
  fi

  assert_json_field "$output" '.status' "FAIL"
  contains "$output" "admission result artifact is empty, placeholder, or not an ADMIT non-claim result" \
    || fail "failure JSON should reject schema-only counter admission placeholder"
}

test_schema_micro_fix_admission_schema_only_placeholder_fails_closed() {
  local root="$TMP_ROOT/schema-micro-fix-admission-placeholder"
  local output=""

  setup_fixture "$root"
  write_placeholder_admission_prerequisite \
    "$root" \
    "schema-micro-fix admission" \
    ".agent/active/sow/schema-micro-fix-admission-result.json"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-schema-micro-fix-admission-placeholder.err")"; then
    fail "schema_version-only schema-micro-fix admission artifact should fail"
  fi

  assert_json_field "$output" '.status' "FAIL"
  contains "$output" "admission result artifact is empty, placeholder, or not an ADMIT non-claim result" \
    || fail "failure JSON should reject schema-only schema-micro-fix admission placeholder"
}

test_prerequisite_path_symlink_parent_escape_fails_closed() {
  local root="$TMP_ROOT/symlink-parent"
  local outside="$TMP_ROOT/outside-prereq"
  local output=""

  setup_fixture "$root"
  mkdir -p "$outside"
  cp "$root/.agent/active/sow/evidence-manifest.json" "$outside/evidence-manifest.json"
  rm "$root/.agent/active/sow/evidence-manifest.json"
  ln -s "$outside" "$root/.agent/active/sow/linked-evidence"
  jq '
    (.prerequisites[] | select(.name == "evidence manifest") | .path) = ".agent/active/sow/linked-evidence/evidence-manifest.json"
  ' "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.json" >"$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.tmp"
  mv "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.tmp" "$root/.agent/registry/rev_harness_distribution_adoption_prerequisites.json"
  git -C "$root" add -A .agent/active/sow .agent/registry/rev_harness_distribution_adoption_prerequisites.json
  git -C "$root" commit -q -m "symlink prerequisite fixture"

  if output="$(run_preflight_for_root "$root" --check --json 2>"$TMP_ROOT/rev-harness-distribution-symlink-parent.err")"; then
    fail "symlink parent prerequisite path should fail"
  fi

  assert_json_field "$output" '.status' "FAIL"
  contains "$output" "symlink/realpath escape" \
    || fail "failure JSON should reject prerequisite symlink parent escape"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-distribution-adoption-test.XXXXXX")"

test_fixture_passes_with_installed_codex_and_prerequisites
test_missing_installed_codex_fails_closed
test_missing_prerequisite_manifest_fails_closed
test_missing_client_distribution_exclude_fails_closed
test_present_prerequisite_artifact_schema_mismatch_fails_closed
test_empty_placeholder_prerequisite_artifacts_fail_closed
test_counter_admission_schema_only_placeholder_fails_closed
test_schema_micro_fix_admission_schema_only_placeholder_fails_closed
test_prerequisite_path_symlink_parent_escape_fails_closed

printf 'PASS: rev_harness_distribution_adoption_test\n'
