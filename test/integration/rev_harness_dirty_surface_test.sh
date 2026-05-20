#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/rev-harness-dirty-surface.sh"
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

setup_repo() {
  local root="$1"

  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" config user.email "rev-harness@example.invalid"
  git -C "$root" config user.name "Rev Harness Test"

  printf '%s\n' "base" >"$root/owned.txt"
  printf '%s\n' "base" >"$root/unrelated.txt"
  git -C "$root" add owned.txt unrelated.txt
  git -C "$root" commit -q -m "base"

  printf '%s\n' "owned change" >>"$root/owned.txt"
  printf '%s\n' "unrelated change" >>"$root/unrelated.txt"
  printf '%s\n' "new evidence" >"$root/evidence.log"
}

write_valid_manifest() {
  local manifest="$1"

  mkdir -p "$(dirname "$manifest")"
  cat >"$manifest" <<'JSON'
{
  "schema_version": "rev-harness-dirty-surface/v1",
  "owned_review_set": ["owned.txt"],
  "expected_unrelated_paths": ["unrelated.txt"],
  "paths": [
    {
      "path": "evidence.log",
      "owner": "slice-c",
      "disposition": "protected evidence",
      "include_in_review": false,
      "acceptance_relevant": true,
      "reason": "verification artifact retained for review"
    },
    {
      "path": "owned.txt",
      "owner": "slice-c",
      "disposition": "owned by active slice",
      "include_in_review": true,
      "acceptance_relevant": true,
      "reason": "implementation surface for this slice"
    },
    {
      "path": "unrelated.txt",
      "owner": "user",
      "disposition": "unrelated user change",
      "include_in_review": false,
      "acceptance_relevant": false,
      "reason": "pre-existing user work outside this slice"
    }
  ],
  "hold_items": [
    {
      "id": "hold-note-1",
      "owner": "orchestrator",
      "disposition": "deferred",
      "include_in_review": false,
      "acceptance_relevant": false,
      "reason": "documented HOLD item not represented by git status"
    }
  ]
}
JSON
}

run_checker_for_root() {
  local root="$1"
  shift

  bash "$CHECKER" --root "$root" "$@"
}

assert_json_field() {
  local json="$1"
  local filter="$2"
  local expected="$3"
  local actual=""

  actual="$(printf '%s' "$json" | jq -r "$filter")"
  [[ "$actual" == "$expected" ]] || fail "expected $filter to be $expected, got $actual"
}

test_valid_manifest_passes_and_is_read_only() {
  local root="$TMP_ROOT/pass"
  local manifest="$TMP_ROOT/pass-manifest.json"
  local before=""
  local after=""
  local output=""

  setup_repo "$root"
  write_valid_manifest "$manifest"
  before="$(git -C "$root" status --porcelain=v1 -uall)"

  output="$(run_checker_for_root "$root" --check --manifest "$manifest" --json)"
  after="$(git -C "$root" status --porcelain=v1 -uall)"

  [[ "$before" == "$after" ]] || fail "dirty surface preflight must not mutate git state"
  assert_json_field "$output" ".status" "PASS"
  assert_json_field "$output" ".read_only" "true"
  assert_json_field "$output" ".dirty_path_count" "3"
  assert_json_field "$output" ".manifest_path_count" "3"
  assert_json_field "$output" ".hold_item_count" "1"
  assert_json_field "$output" ".owned_review_set | join(\",\")" "owned.txt"
  assert_json_field "$output" ".failures | length" "0"
}

test_text_output_is_deterministic_and_reviewer_friendly() {
  local root="$TMP_ROOT/text"
  local manifest="$TMP_ROOT/text-manifest.json"
  local output=""

  setup_repo "$root"
  write_valid_manifest "$manifest"

  output="$(run_checker_for_root "$root" --check --manifest "$manifest")"

  contains "$output" "dirty_surface_preflight: PASS" || fail "text output should report PASS"
  contains "$output" "read_only: true" || fail "text output should make read-only mode explicit"
  contains "$output" "dirty_path_count: 3" || fail "text output should include dirty count"
  contains "$output" "owned_review_set:" || fail "text output should include owned review set"
  contains "$output" "  owned.txt" || fail "text output should list owned path"
  contains "$output" "skipped_paths:" || fail "text output should list skipped paths"
  contains "$output" "unrelated.txt [unrelated user change]" || fail "text output should explain unrelated skip"
}

test_unowned_dirty_path_fails_closed() {
  local root="$TMP_ROOT/unowned"
  local manifest="$TMP_ROOT/unowned-manifest.json"
  local stdout_file="$TMP_ROOT/unowned.out"
  local stderr_file="$TMP_ROOT/unowned.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq 'del(.paths[] | select(.path == "evidence.log"))' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" >"$stdout_file" 2>"$stderr_file"; then
    fail "unowned dirty path should fail closed"
  fi

  [[ ! -s "$stdout_file" ]] || fail "text failure should not write stdout"
  contains "$(cat "$stderr_file")" "dirty path missing manifest ownership" \
    || fail "unowned dirty path failure should be explicit"
  contains "$(cat "$stderr_file")" "evidence.log" \
    || fail "unowned dirty path failure should name the path"
}

test_conflicting_owned_review_set_fails_closed() {
  local root="$TMP_ROOT/conflict"
  local manifest="$TMP_ROOT/conflict-manifest.json"
  local stderr_file="$TMP_ROOT/conflict.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '.owned_review_set = ["unrelated.txt"]' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" >/dev/null 2>"$stderr_file"; then
    fail "owned review set conflict should fail closed"
  fi

  contains "$(cat "$stderr_file")" "owned_review_set path is not review-included" \
    || fail "owned review conflict should explain include_in_review mismatch"
  contains "$(cat "$stderr_file")" "review-included path missing from owned_review_set" \
    || fail "owned review conflict should also name missing owned path"
}

test_acceptance_relevant_without_disposition_fails_closed() {
  local root="$TMP_ROOT/no-disposition"
  local manifest="$TMP_ROOT/no-disposition-manifest.json"
  local stderr_file="$TMP_ROOT/no-disposition.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '(.paths[] | select(.path == "owned.txt")) |= del(.disposition)' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" >/dev/null 2>"$stderr_file"; then
    fail "acceptance-relevant path without disposition should fail closed"
  fi

  contains "$(cat "$stderr_file")" "acceptance-relevant path lacks disposition" \
    || fail "acceptance-relevant disposition failure should be explicit"
  contains "$(cat "$stderr_file")" "owned.txt" \
    || fail "acceptance-relevant disposition failure should name the path"
}

test_hold_item_without_owner_fails_closed() {
  local root="$TMP_ROOT/hold-owner"
  local manifest="$TMP_ROOT/hold-owner-manifest.json"
  local stderr_file="$TMP_ROOT/hold-owner.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '(.hold_items[0]) |= del(.owner)' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" >/dev/null 2>"$stderr_file"; then
    fail "HOLD item without owner should fail closed"
  fi

  contains "$(cat "$stderr_file")" "HOLD item lacks owner" \
    || fail "HOLD owner failure should be explicit"
  contains "$(cat "$stderr_file")" "hold-note-1" \
    || fail "HOLD owner failure should name the item"
}

test_manifest_extra_path_fails_closed() {
  local root="$TMP_ROOT/extra"
  local manifest="$TMP_ROOT/extra-manifest.json"
  local stderr_file="$TMP_ROOT/extra.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '.paths += [{
    "path": "not-dirty.txt",
    "owner": "slice-c",
    "disposition": "deferred",
    "include_in_review": false,
    "acceptance_relevant": false,
    "reason": "stale entry"
  }]' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" >/dev/null 2>"$stderr_file"; then
    fail "extra manifest path should fail closed"
  fi

  contains "$(cat "$stderr_file")" "manifest path is not dirty" \
    || fail "extra manifest path failure should be explicit"
  contains "$(cat "$stderr_file")" "not-dirty.txt" \
    || fail "extra manifest path failure should name the path"
}

test_scalar_path_manifest_element_fails_closed_with_structured_json() {
  local root="$TMP_ROOT/scalar-path"
  local manifest="$TMP_ROOT/scalar-path-manifest.json"
  local stdout_file="$TMP_ROOT/scalar-path.out"
  local stderr_file="$TMP_ROOT/scalar-path.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '.paths = ["owned.txt"]' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" --json >"$stdout_file" 2>"$stderr_file"; then
    fail "scalar paths element should fail closed"
  fi

  [[ ! -s "$stderr_file" ]] || fail "scalar path JSON failure should not emit raw jq stderr"
  jq -e '
    .status == "FAIL"
    and .failures == [{
      "context": "manifest.paths",
      "message": "path entry must be an object",
      "path": "index:0"
    }]
  ' "$stdout_file" >/dev/null || fail "scalar path failure should be structured JSON"
}

test_non_array_paths_fails_closed_with_structured_json() {
  local root="$TMP_ROOT/non-array-paths"
  local manifest="$TMP_ROOT/non-array-paths-manifest.json"
  local stdout_file="$TMP_ROOT/non-array-paths.out"
  local stderr_file="$TMP_ROOT/non-array-paths.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '.paths = "not-array"' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" --json >"$stdout_file" 2>"$stderr_file"; then
    fail "non-array paths should fail closed"
  fi

  [[ ! -s "$stderr_file" ]] || fail "non-array paths JSON failure should not emit raw jq stderr"
  jq -e '
    .status == "FAIL"
    and .manifest_path_count == 0
    and .paths == []
    and .failures == [{
      "context": "manifest",
      "message": "schema_version, owned_review_set, paths, or hold_items shape is invalid",
      "path": .failures[0].path
    }]
    and (.failures[0].path | endswith("/non-array-paths-manifest.json"))
  ' "$stdout_file" >/dev/null || fail "non-array paths failure should be structured JSON"
}

test_scalar_hold_item_manifest_element_fails_closed_with_structured_json() {
  local root="$TMP_ROOT/scalar-hold"
  local manifest="$TMP_ROOT/scalar-hold-manifest.json"
  local stdout_file="$TMP_ROOT/scalar-hold.out"
  local stderr_file="$TMP_ROOT/scalar-hold.err"

  setup_repo "$root"
  write_valid_manifest "$manifest"
  jq '.hold_items = ["hold-note-1"]' "$manifest" >"$manifest.tmp"
  mv "$manifest.tmp" "$manifest"

  if run_checker_for_root "$root" --check --manifest "$manifest" --json >"$stdout_file" 2>"$stderr_file"; then
    fail "scalar hold item should fail closed"
  fi

  [[ ! -s "$stderr_file" ]] || fail "scalar hold item JSON failure should not emit raw jq stderr"
  jq -e '
    .status == "FAIL"
    and .failures == [{
      "context": "hold_items",
      "message": "HOLD item must be an object",
      "path": "index:0"
    }]
  ' "$stdout_file" >/dev/null || fail "scalar hold item failure should be structured JSON"
}

test_missing_default_manifest_fails_closed_with_structured_json() {
  local root="$TMP_ROOT/missing-default"
  local stdout_file="$TMP_ROOT/missing-default.out"
  local stderr_file="$TMP_ROOT/missing-default.err"

  setup_repo "$root"

  if run_checker_for_root "$root" --check --json >"$stdout_file" 2>"$stderr_file"; then
    fail "missing default manifest should fail closed"
  fi

  [[ ! -s "$stderr_file" ]] || fail "missing default manifest JSON failure should not emit stderr"
  jq -e '
    .status == "FAIL"
    and .manifest == ".agent/active/sow/rev_harness_90_point_dirty_surface_manifest.json"
    and .failures == [{
      "context": "manifest",
      "message": "missing dirty surface manifest",
      "path": ".agent/active/sow/rev_harness_90_point_dirty_surface_manifest.json"
    }]
  ' "$stdout_file" >/dev/null || fail "missing default manifest failure should be structured JSON"
}

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-dirty-surface-test.XXXXXX")"

test_valid_manifest_passes_and_is_read_only
test_text_output_is_deterministic_and_reviewer_friendly
test_unowned_dirty_path_fails_closed
test_conflicting_owned_review_set_fails_closed
test_acceptance_relevant_without_disposition_fails_closed
test_hold_item_without_owner_fails_closed
test_manifest_extra_path_fails_closed
test_scalar_path_manifest_element_fails_closed_with_structured_json
test_non_array_paths_fails_closed_with_structured_json
test_scalar_hold_item_manifest_element_fails_closed_with_structured_json
test_missing_default_manifest_fails_closed_with_structured_json

printf 'PASS: rev_harness_dirty_surface_test\n'
