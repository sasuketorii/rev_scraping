#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/rev-harness-evidence-manifest.sh"
TMP_PARENT="$PROJECT_ROOT/.tmp-rev-harness-evidence-manifest-test"
mkdir -p "$TMP_PARENT"
TMP_ROOT="$(mktemp -d "$TMP_PARENT/run.XXXXXX")"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  /bin/rm -rf "$TMP_ROOT"
  rmdir "$TMP_PARENT" 2>/dev/null || true
}
trap cleanup EXIT

contains() {
  local haystack="$1"
  local needle="$2"

  [[ "$haystack" == *"$needle"* ]]
}

hash_file() {
  local path="$1"

  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

setup_fixture() {
  local root="$1"
  local artifact_hash=""

  mkdir -p "$root/evidence"
  printf 'artifact body\n' >"$root/evidence/report.md"
  artifact_hash="$(hash_file "$root/evidence/report.md")"

  jq -n --arg hash "$artifact_hash" '{
    schema_version: "rev-harness-evidence-manifest/v1",
    acceptance_eligible: true,
    artifacts: [
      {path: "evidence/report.md", sha256: $hash, required: true}
    ],
    commands: [
      {command: "test -f evidence/report.md", status: "PASS", required: true}
    ],
    reviewer_capsule: {
      plan_lgtm: {gate: "plan_lgtm", status: "LGTM", evidence_path: "evidence/report.md"},
      implementation_lgtm: {gate: "implementation_lgtm", status: "pending", evidence_path: "evidence/report.md"},
      security_lgtm: {gate: "security_lgtm", status: "not-requested", evidence_path: "evidence/report.md"},
      release_acceptance: {gate: "release_acceptance", status: "not-attempted", evidence_path: "evidence/report.md"}
    }
  }' >"$root/manifest.json"
}

setup_accepted_fixture() {
  local root="$1"

  setup_fixture "$root"
  jq '
    .reviewer_capsule.plan_lgtm.status = "LGTM"
    | .reviewer_capsule.implementation_lgtm.status = "LGTM"
    | .reviewer_capsule.security_lgtm.status = "LGTM"
    | .reviewer_capsule.release_acceptance.status = "accepted"
  ' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"
}

run_checker() {
  local root="$1"
  shift

  REV_HARNESS_EVIDENCE_PROJECT_ROOT="$root" bash "$CHECKER" "$@"
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(printf '%s\n' "$json" | jq -r "$filter")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

assert_fails_with() {
  local name="$1"
  local root="$2"
  local needle="$3"
  shift 3
  local stdout_file="$TMP_ROOT/$name.out"
  local stderr_file="$TMP_ROOT/$name.err"

  if run_checker "$root" "$@" >"$stdout_file" 2>"$stderr_file"; then
    fail "$name should fail"
  fi
  contains "$(cat "$stderr_file")" "$needle" || fail "$name failure should contain: $needle"
}

test_pending_capsule_manifest_passes_but_reports_derived_acceptance_false() {
  local root="$TMP_ROOT/pass"
  local output=""
  setup_fixture "$root"

  output="$(run_checker "$root" validate --manifest manifest.json --json)"

  assert_json_field "$output" '.schema_version' "rev-harness-evidence-manifest/v1"
  assert_json_field "$output" '.status' "PASS"
  assert_json_field "$output" '.acceptance_eligible' "false"
  assert_json_field "$output" '.manifest_claimed_acceptance_eligible' "true"
  assert_json_field "$output" '.derived_final_acceptance_eligible' "false"
  assert_json_field "$output" '.final_acceptance_requested' "false"
  assert_json_field "$output" '.artifact_count' "1"
  assert_json_field "$output" '.command_count' "1"
  assert_json_field "$output" '.failures | length' "0"
}

test_adversarial_acceptance_self_assertion_does_not_smuggle_json_true() {
  local root="$TMP_ROOT/self-assertion"
  local output=""
  setup_fixture "$root"
  jq '.acceptance_eligible = true' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  output="$(run_checker "$root" validate --manifest manifest.json --json)"

  assert_json_field "$output" '.status' "PASS"
  assert_json_field "$output" '.acceptance_eligible' "false"
  assert_json_field "$output" '.manifest_claimed_acceptance_eligible' "true"
  assert_json_field "$output" '.derived_final_acceptance_eligible' "false"
}

test_accepted_capsule_reports_derived_acceptance_true() {
  local root="$TMP_ROOT/accepted"
  local output=""
  setup_accepted_fixture "$root"

  output="$(run_checker "$root" validate --manifest manifest.json --json)"

  assert_json_field "$output" '.status' "PASS"
  assert_json_field "$output" '.acceptance_eligible' "true"
  assert_json_field "$output" '.manifest_claimed_acceptance_eligible' "true"
  assert_json_field "$output" '.derived_final_acceptance_eligible' "true"
}

test_missing_artifact_fails_closed() {
  local root="$TMP_ROOT/missing-artifact"
  setup_fixture "$root"
  /bin/rm -f "$root/evidence/report.md"

  assert_fails_with "missing-artifact" "$root" "missing artifact file" validate --manifest manifest.json
}

test_hash_mismatch_fails_closed() {
  local root="$TMP_ROOT/hash-mismatch"
  setup_fixture "$root"
  printf 'mutated\n' >"$root/evidence/report.md"

  assert_fails_with "hash-mismatch" "$root" "sha256 mismatch" validate --manifest manifest.json
}

test_required_command_failure_fails_closed() {
  local root="$TMP_ROOT/command-fail"
  setup_fixture "$root"
  jq '.commands[0].status = "FAIL"' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "command-fail" "$root" "required command did not PASS" validate --manifest manifest.json
}

test_command_required_string_true_fails_closed() {
  local root="$TMP_ROOT/command-required-string"
  setup_fixture "$root"
  jq '.commands[0].required = "true"' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "command-required-string" "$root" "required must be boolean" validate --manifest manifest.json
}

test_artifact_required_string_true_fails_closed() {
  local root="$TMP_ROOT/artifact-required-string-true"
  setup_fixture "$root"
  jq '.artifacts[0].required = "true"' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "artifact-required-string-true" "$root" "required must be boolean" validate --manifest manifest.json
}

test_artifact_required_string_false_fails_closed() {
  local root="$TMP_ROOT/artifact-required-string-false"
  setup_fixture "$root"
  jq '.artifacts[0].required = "false"' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "artifact-required-string-false" "$root" "required must be boolean" validate --manifest manifest.json
}

test_artifact_required_null_fails_closed() {
  local root="$TMP_ROOT/artifact-required-null"
  setup_fixture "$root"
  jq '.artifacts[0].required = null' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "artifact-required-null" "$root" "required must be boolean" validate --manifest manifest.json
}

test_extra_artifact_missing_required_fails_closed() {
  local root="$TMP_ROOT/artifact-missing-required"
  local extra_hash=""
  setup_fixture "$root"
  printf 'extra artifact body\n' >"$root/evidence/extra.md"
  extra_hash="$(hash_file "$root/evidence/extra.md")"
  jq --arg hash "$extra_hash" '
    .artifacts += [{path: "evidence/extra.md", sha256: $hash}]
  ' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "artifact-missing-required" "$root" "required must be boolean" validate --manifest manifest.json
}

test_artifact_required_number_fails_closed() {
  local root="$TMP_ROOT/artifact-required-number"
  setup_fixture "$root"
  jq '.artifacts[0].required = 1' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "artifact-required-number" "$root" "required must be boolean" validate --manifest manifest.json
}

test_artifact_required_malformed_type_fails_closed() {
  local root="$TMP_ROOT/artifact-required-object"
  setup_fixture "$root"
  jq '.artifacts[0].required = {"value": true}' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "artifact-required-object" "$root" "required must be boolean" validate --manifest manifest.json
}

test_final_acceptance_requires_acceptance_eligible_true() {
  local root="$TMP_ROOT/final-acceptance"
  setup_fixture "$root"
  jq '.acceptance_eligible = false' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "final-acceptance" "$root" "final acceptance requested" validate --manifest manifest.json --final-acceptance
}

test_final_acceptance_rejects_pending_capsule_gates() {
  local root="$TMP_ROOT/final-pending"
  setup_fixture "$root"

  assert_fails_with "final-pending" "$root" "final acceptance requires all capsule gates accepted with verified evidence" validate --manifest manifest.json --final-acceptance
}

test_reviewer_capsule_rejects_release_acceptance_lgtm_conflation() {
  local root="$TMP_ROOT/capsule-conflation"
  setup_fixture "$root"
  jq '.reviewer_capsule.release_acceptance.status = "LGTM"' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "capsule-conflation" "$root" "release acceptance must not be represented as LGTM" validate --manifest manifest.json
}

test_unsafe_artifact_path_fails_closed() {
  local root="$TMP_ROOT/unsafe-path"
  setup_fixture "$root"
  jq '.artifacts[0].path = "../outside.md"' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "unsafe-path" "$root" "safe repository-relative path" validate --manifest manifest.json
}

test_artifact_path_symlink_parent_escape_fails_closed() {
  local root="$TMP_ROOT/symlink-parent"
  local outside="$TMP_ROOT/outside-artifacts"
  local artifact_hash=""

  setup_fixture "$root"
  mkdir -p "$outside"
  printf 'outside artifact\n' >"$outside/report.md"
  /bin/rm -rf "$root/evidence"
  ln -s "$outside" "$root/evidence"
  artifact_hash="$(hash_file "$outside/report.md")"
  jq --arg hash "$artifact_hash" '
    .artifacts[0].path = "evidence/report.md"
    | .artifacts[0].sha256 = $hash
    | .reviewer_capsule.plan_lgtm.evidence_path = "evidence/report.md"
  ' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "symlink-parent" "$root" "symlink/realpath escape" validate --manifest manifest.json
}

test_missing_capsule_evidence_path_fails_closed() {
  local root="$TMP_ROOT/missing-capsule-evidence"
  setup_fixture "$root"
  jq 'del(.reviewer_capsule.plan_lgtm.evidence_path)' "$root/manifest.json" >"$root/manifest.tmp"
  mv "$root/manifest.tmp" "$root/manifest.json"

  assert_fails_with "missing-capsule-evidence" "$root" "missing evidence_path" validate --manifest manifest.json
}

test_pending_capsule_manifest_passes_but_reports_derived_acceptance_false
test_adversarial_acceptance_self_assertion_does_not_smuggle_json_true
test_accepted_capsule_reports_derived_acceptance_true
test_missing_artifact_fails_closed
test_hash_mismatch_fails_closed
test_required_command_failure_fails_closed
test_command_required_string_true_fails_closed
test_artifact_required_string_true_fails_closed
test_artifact_required_string_false_fails_closed
test_artifact_required_null_fails_closed
test_extra_artifact_missing_required_fails_closed
test_artifact_required_number_fails_closed
test_artifact_required_malformed_type_fails_closed
test_final_acceptance_requires_acceptance_eligible_true
test_final_acceptance_rejects_pending_capsule_gates
test_reviewer_capsule_rejects_release_acceptance_lgtm_conflation
test_unsafe_artifact_path_fails_closed
test_artifact_path_symlink_parent_escape_fails_closed
test_missing_capsule_evidence_path_fails_closed

printf 'PASS: rev_harness_evidence_manifest_test\n'
