#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT=""
PROJECT_ROOT=""
JANITOR=""
FIXTURE_ROOT=""
SYMLINK_ROOT=""
OUTSIDE_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  [[ "$haystack" == *"$needle"* ]]
}

cleanup() {
  /bin/rm -rf "${TMP_ROOT:-}"
}

trap cleanup EXIT

cleanup_legacy_fixed_tmp_residue() {
  /bin/rm -f \
    /tmp/rev-harness-janitor-apply.out \
    /tmp/rev-harness-janitor-apply.err \
    /tmp/rev-harness-janitor-symlink.out \
    /tmp/rev-harness-janitor-symlink.err \
    /tmp/rev-harness-janitor-outside.out \
    /tmp/rev-harness-janitor-outside.err \
    /tmp/rev-harness-janitor-outside-archive.out \
    /tmp/rev-harness-janitor-outside-archive.err \
    /tmp/rev-harness-janitor-outside-archive-dry.out \
    /tmp/rev-harness-janitor-outside-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-archive-dry.out \
    /tmp/rev-harness-janitor-symlink-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-component-dry.out \
    /tmp/rev-harness-janitor-symlink-component-dry.err \
    2>/dev/null || true
}

setup_test_project() {
  TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-janitor-test.XXXXXX")"
  TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
  PROJECT_ROOT="$TMP_ROOT/project"
  JANITOR="$PROJECT_ROOT/scripts/rev-harness-janitor.sh"
  FIXTURE_ROOT="$PROJECT_ROOT/.claude/tmp/rev-harness-janitor-test.$$"
  SYMLINK_ROOT="$PROJECT_ROOT/.claude/tmp/rev-harness-janitor-link.$$"

  mkdir -p "$PROJECT_ROOT/scripts" "$PROJECT_ROOT/.claude/tmp"
  cp "$REAL_PROJECT_ROOT/scripts/rev-harness-janitor.sh" "$PROJECT_ROOT/scripts/rev-harness-janitor.sh"
  cp "$REAL_PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh" "$PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh"
  chmod +x "$PROJECT_ROOT/scripts/rev-harness-janitor.sh" "$PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh"
  git -C "$PROJECT_ROOT" init -q
}

run_janitor() {
  (cd "$PROJECT_ROOT" && bash "$JANITOR" "$@")
}

reset_fixture() {
  /bin/rm -rf "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT"
}

make_run_dir() {
  local dir="$1"
  local stamp="$2"

  mkdir -p "$dir"
  printf 'summary\n' >"$dir/summary.md"
  touch -t "$stamp" "$dir" "$dir/summary.md"
}

test_help_documents_safety_contract() {
  local output=""

  output="$(run_janitor --help)"

  contains "$output" "This CLI never deletes files." || fail "help should document no-delete contract"
  contains "$output" "Active lineage and release evidence" || fail "help should document evidence protection"
  contains "$output" "archive is non-mutating in this slice" || fail "help should document dry-run archive contract"
}

test_inspect_summarizes_fixture_without_moving() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  printf 'pointer\n' >"$FIXTURE_ROOT/latest.txt"

  output="$(run_janitor inspect --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "janitor_command: inspect" || fail "inspect should identify command"
  contains "$output" "tmp_summary_scope: bounded-depth-2" || fail "inspect should use bounded summary by default"
  contains "$output" "tmp_size_bytes:" || fail "inspect should report tmp size"
  contains "$output" "tmp_file_count:" || fail "inspect should report file count"
  contains "$output" "candidate_count: 1" || fail "inspect should report candidate count"
  contains "$output" "action_count: 1" || fail "inspect should report action count"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "inspect must not move candidate"
}

test_inspect_default_avoids_unbounded_du_and_find() {
  local output=""
  local fakebin="$TMP_ROOT/fakebin-inspect"
  local real_find=""
  local real_du=""

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  mkdir -p "$FIXTURE_ROOT/deep/a/b"
  printf 'deep\n' >"$FIXTURE_ROOT/deep/a/b/not-counted-by-bounded-summary.txt"

  real_find="$(command -v find)"
  real_du="$(command -v du)"
  mkdir -p "$fakebin"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'has_maxdepth=false' \
    'for arg in "$@"; do' \
    '  [[ "$arg" == "-maxdepth" ]] && has_maxdepth=true' \
    'done' \
    'if [[ "$has_maxdepth" != true ]]; then' \
    '  printf "unbounded find rejected: %s\n" "$*" >&2' \
    '  exit 99' \
    'fi' \
    "exec \"$real_find\" \"\$@\"" \
    >"$fakebin/find"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "unbounded du rejected: %s\n" "$*" >&2' \
    'exit 99' \
    >"$fakebin/du"
  chmod +x "$fakebin/find" "$fakebin/du"

  output="$(PATH="$fakebin:$PATH" run_janitor inspect --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "tmp_summary_scope: bounded-depth-2" || fail "inspect should report bounded summary scope"
  contains "$output" "candidate_count: 1" || fail "bounded inspect should still report pruner candidate count"
  [[ -x "$real_du" ]] || fail "real du should exist for fixture sanity"
}

test_plan_is_dry_run() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "janitor_command: plan" || fail "plan should identify command"
  contains "$output" "archive_enabled: false" || fail "plan should not enable archive"
  contains "$output" "would_archive: 20200101_000001" || fail "plan should show dry-run archive candidate"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "plan must not move candidate"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "plan must not create archive output"
}

test_archive_without_archive_dir_is_dry_run() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_janitor archive --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "janitor_command: archive" || fail "archive should identify command"
  contains "$output" "archive_enabled: false" || fail "archive without archive-dir should remain dry-run"
  contains "$output" "would_archive: 20200101_000001" || fail "archive dry-run should show candidate"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "archive without archive-dir must not move candidate"
}

test_archive_with_archive_dir_is_dry_run_and_non_mutating() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_janitor archive --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --archive-dir "$FIXTURE_ROOT/.archive")"

  contains "$output" "archive_enabled: false" || fail "explicit archive-dir should not enable live archive"
  contains "$output" "archive_dir: $FIXTURE_ROOT/.archive" || fail "archive should echo validated archive dir"
  contains "$output" "would_archive: 20200101_000001" || fail "archive should report dry-run candidate"
  contains "$output" "reviewed authorization manifest" || fail "archive should explain authorization requirement"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source must remain during archive dry-run"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "archive dry-run must not create archive output"
  [[ ! -e "$PROJECT_ROOT/20200101_000001" ]] || fail "archive must not escape selected root"
}

test_json_archive_with_archive_dir_is_non_mutating() {
  local json=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  json="$(run_janitor archive --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --archive-dir "$FIXTURE_ROOT/.archive" --json)"

  printf '%s\n' "$json" | jq -e '
    .janitor_command == "archive"
    and .delete_enabled == false
    and .archive_enabled == false
    and .dry_run == true
    and .actions == ["20200101_000001"]
  ' >/dev/null || fail "archive JSON should remain dry-run and non-mutating"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "json archive must not move candidate"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "json archive dry-run must not create archive output"
}

test_json_plan_reports_no_delete_path() {
  local json=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .schema_version == "rev-harness-janitor/v1"
    and .janitor_command == "plan"
    and .delete_enabled == false
    and .archive_enabled == false
    and .dry_run == true
    and .candidate_count == 1
    and .action_count == 1
    and .actions == ["20200101_000001"]
  ' >/dev/null || fail "plan JSON schema/content should be agent-friendly"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "json plan must not move candidate"
}

test_plan_uses_single_tracked_file_probe_for_many_candidates() {
  local json=""
  local fakebin="$TMP_ROOT/fakebin"
  local count_file="$TMP_ROOT/git-ls-files-count.txt"
  local real_git=""
  local idx=""

  reset_fixture
  for idx in 1 2 3 4 5; do
    make_run_dir "$FIXTURE_ROOT/20200101_00000$idx" "202001010000"
  done

  real_git="$(command -v git)"
  mkdir -p "$fakebin"
  # shellcheck disable=SC2016
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$*" == *" ls-files "* ]]; then' \
    '  printf x >>"$GIT_LS_FILES_COUNT_FILE"' \
    'fi' \
    "exec \"$real_git\" \"\$@\"" \
    >"$fakebin/git"
  chmod +x "$fakebin/git"
  : >"$count_file"

  json="$(GIT_LS_FILES_COUNT_FILE="$count_file" PATH="$fakebin:$PATH" run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .candidate_count == 5
    and .action_count == 5
  ' >/dev/null || fail "bounded plan should still report all direct run candidates"
  [[ "$(wc -c <"$count_file" | tr -d '[:space:]')" == "1" ]] \
    || fail "plan should batch tracked-file protection instead of probing each candidate"
}

test_pruner_preserves_tracked_tmp_files_when_project_path_has_glob_metacharacters() {
  local glob_project="$TMP_ROOT/project-[x]"
  local glob_janitor="$glob_project/scripts/rev-harness-janitor.sh"
  local glob_fixture="$glob_project/.claude/tmp/20200101_000001"
  local json=""

  mkdir -p "$glob_project/scripts" "$glob_project/.claude/tmp"
  cp "$REAL_PROJECT_ROOT/scripts/rev-harness-janitor.sh" "$glob_janitor"
  cp "$REAL_PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh" "$glob_project/scripts/harness-active-artifact-pruner.sh"
  chmod +x "$glob_janitor" "$glob_project/scripts/harness-active-artifact-pruner.sh"
  git -C "$glob_project" init -q

  mkdir -p "$glob_fixture"
  printf 'tracked fixture\n' >"$glob_fixture/keep.txt"
  git -C "$glob_project" add .claude/tmp/20200101_000001/keep.txt

  json="$(
    cd "$glob_project"
    bash "$glob_janitor" plan --root .claude/tmp --keep-latest 0 --max-age-days 0 --json
  )"

  printf '%s\n' "$json" | jq -e '
    .candidate_count == 1
    and .protected_count == 1
    and .action_count == 0
    and .actions == []
  ' >/dev/null || fail "tracked tmp candidate should be protected when project path contains glob metacharacters"
  [[ -f "$glob_fixture/keep.txt" ]] || fail "tracked tmp file must remain in place"
}

test_plan_candidate_discovery_is_bounded_to_known_locations() {
  local json=""

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/random/deep/20200101_000002" "202001010000"
  make_run_dir "$FIXTURE_ROOT/task/runs/20200101_000003" "202001010000"
  mkdir -p "$FIXTURE_ROOT/manifested/deep/path"
  printf '%s\n' '{"schema_version":"artifact-lifecycle/v1","state":"superseded","latest_pointer":"none","pinned_baseline":"none","run_disposable":"YES","superseded_by":"newer","safe_delete_class":"scratch"}' \
    >"$FIXTURE_ROOT/manifested/deep/path/artifact-lifecycle-manifest.json"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .candidate_count == 3
    and (.actions | index("20200101_000001"))
    and (.actions | index("task/runs/20200101_000003"))
    and (.actions | index("manifested/deep/path"))
    and ((.actions | index("random/deep/20200101_000002")) | not)
  ' >/dev/null || fail "candidate discovery should use direct roots, runs children, and manifests only"
}

test_janitor_extensions_report_manifest_residue_without_mutation() {
  local json=""
  reset_fixture
  mkdir -p "$FIXTURE_ROOT/20200101_000001"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","artifacts":[],"reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/evidence-manifest.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-dirty-surface/v1","owned_review_set":[],"paths":[]}' \
    >"$FIXTURE_ROOT/20200101_000001/dirty-surface.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-worker-lifecycle/v1","workers":[{"state":"closed","artifact_paths":[]}]}' \
    >"$FIXTURE_ROOT/20200101_000001/worker-lifecycle.json"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .delete_enabled == false
    and .apply_enabled == false
    and .archive_enabled == false
    and .janitor_extensions.schema_version == "rev-harness-janitor-extensions/v1"
    and .janitor_extensions.delete_enabled == false
    and .janitor_extensions.apply_enabled == false
    and .janitor_extensions.project_state_mutation_enabled == false
    and .janitor_extensions.finding_count == 3
    and ([.janitor_extensions.findings[].residue_type] | sort == ["dirty_surface_manifest","evidence_manifest","worker_lifecycle_manifest"])
    and all(.janitor_extensions.findings[]; .planned_action == "inspect-only" and .delete_enabled == false and .archive_only_candidate == true)
    and (.janitor_extensions.findings[] | select(.residue_type == "evidence_manifest") | .has_reviewer_capsule == true)
    and (.janitor_extensions.findings[] | select(.residue_type == "dirty_surface_manifest") | .has_owned_review_set == true)
    and (.janitor_extensions.findings[] | select(.residue_type == "worker_lifecycle_manifest") | .has_worker_artifact_paths == true)
  ' >/dev/null || fail "janitor extension JSON should report manifest residue as inspect-only"

  [[ -f "$FIXTURE_ROOT/20200101_000001/evidence-manifest.json" ]] || fail "extension scan must not move evidence manifest"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "extension scan must not archive without archive command"
}

test_janitor_extension_scan_is_bounded_to_known_residue_locations() {
  local json=""
  reset_fixture
  mkdir -p "$FIXTURE_ROOT/20200101_000001/deep/a/b"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/evidence-manifest.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/deep/a/b/evidence-manifest.json"
  printf '%s\n' \
    '{"schema_version":"rev-harness-evidence-manifest/v1","reviewer_capsule":{}}' \
    >"$FIXTURE_ROOT/20200101_000001/unbounded-random.json"

  json="$(run_janitor plan --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"

  printf '%s\n' "$json" | jq -e '
    .janitor_extensions.finding_count == 1
    and .janitor_extensions.findings[0].path == "20200101_000001/evidence-manifest.json"
  ' >/dev/null || fail "extension scan should be bounded by maxdepth and known residue names"
}

test_apply_path_fails_closed() {
  local stdout_file="$TMP_ROOT/rev-harness-janitor-apply.out"
  local stderr_file="$TMP_ROOT/rev-harness-janitor-apply.err"
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  if run_janitor plan --root "$FIXTURE_ROOT" --apply >"$stdout_file" 2>"$stderr_file"; then
    fail "apply path should fail closed"
  fi
  contains "$(<"$stderr_file")" "apply is not supported" \
    || fail "apply failure should mention apply is not supported"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "apply failure must not move candidate"
}

test_symlink_and_path_escape_fail_closed() {
  local symlink_stdout="$TMP_ROOT/rev-harness-janitor-symlink.out"
  local symlink_stderr="$TMP_ROOT/rev-harness-janitor-symlink.err"
  local outside_stdout="$TMP_ROOT/rev-harness-janitor-outside.out"
  local outside_stderr="$TMP_ROOT/rev-harness-janitor-outside.err"
  local archive_stdout="$TMP_ROOT/rev-harness-janitor-outside-archive.out"
  local archive_stderr="$TMP_ROOT/rev-harness-janitor-outside-archive.err"
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  mkdir -p "$FIXTURE_ROOT/real-root"
  ln -s "$FIXTURE_ROOT/real-root" "$SYMLINK_ROOT"

  if run_janitor inspect --root "$SYMLINK_ROOT" >"$symlink_stdout" 2>"$symlink_stderr"; then
    fail "symlink root should fail closed"
  fi
  contains "$(<"$symlink_stderr")" "symlink" || fail "symlink failure should mention symlink"

  OUTSIDE_ROOT="$(mktemp -d "$TMP_ROOT/rev-harness-janitor-outside.XXXXXX")"
  if run_janitor plan --root "$OUTSIDE_ROOT" >"$outside_stdout" 2>"$outside_stderr"; then
    fail "repo-outside root should fail closed"
  fi
  contains "$(<"$outside_stderr")" "--root" || fail "outside root should mention root boundary"

  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$OUTSIDE_ROOT/archive" >"$archive_stdout" 2>"$archive_stderr"; then
    fail "repo-outside archive dir should fail closed"
  fi
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after archive path escape failure"
  [[ ! -e "$OUTSIDE_ROOT/archive" ]] || fail "outside archive dir should not be created"
}

test_archive_dry_run_validates_archive_dir() {
  local symlink_archive=""
  local component_target=""
  local component_link=""
  local outside_stdout="$TMP_ROOT/rev-harness-janitor-outside-archive-dry.out"
  local outside_stderr="$TMP_ROOT/rev-harness-janitor-outside-archive-dry.err"
  local symlink_stdout="$TMP_ROOT/rev-harness-janitor-symlink-archive-dry.out"
  local symlink_stderr="$TMP_ROOT/rev-harness-janitor-symlink-archive-dry.err"
  local component_stdout="$TMP_ROOT/rev-harness-janitor-symlink-component-dry.out"
  local component_stderr="$TMP_ROOT/rev-harness-janitor-symlink-component-dry.err"

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  OUTSIDE_ROOT="$(mktemp -d "$TMP_ROOT/rev-harness-janitor-outside-dry.XXXXXX")"
  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$OUTSIDE_ROOT/archive" \
    --dry-run >"$outside_stdout" 2>"$outside_stderr"; then
    fail "repo-outside archive dir dry-run should fail closed"
  fi
  contains "$(<"$outside_stderr")" "--archive-dir" \
    || fail "outside archive-dir dry-run failure should mention archive-dir"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after dry-run outside archive path failure"
  [[ ! -e "$OUTSIDE_ROOT/archive" ]] || fail "outside archive dir dry-run should not create archive dir"

  mkdir -p "$FIXTURE_ROOT/archive-target"
  symlink_archive="$FIXTURE_ROOT/archive-link"
  ln -s "$FIXTURE_ROOT/archive-target" "$symlink_archive"
  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$symlink_archive/" \
    --dry-run \
    --json >"$symlink_stdout" 2>"$symlink_stderr"; then
    fail "symlink archive dir dry-run should fail closed"
  fi
  contains "$(<"$symlink_stderr")" "symlink" \
    || fail "symlink archive-dir dry-run failure should mention symlink"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after dry-run symlink archive path failure"
  [[ ! -e "$FIXTURE_ROOT/archive-target/20200101_000001" ]] || fail "symlink archive dir dry-run should not move candidate"

  component_target="$FIXTURE_ROOT/component-target"
  component_link="$FIXTURE_ROOT/component-link"
  mkdir -p "$component_target"
  ln -s "$component_target" "$component_link"
  if run_janitor archive \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --archive-dir "$component_link/archive" \
    --dry-run >"$component_stdout" 2>"$component_stderr"; then
    fail "symlink archive path component dry-run should fail closed"
  fi
  contains "$(<"$component_stderr")" "symlink path component" \
    || fail "symlink path component dry-run failure should mention path component"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after dry-run symlink component failure"
  [[ ! -e "$component_target/archive" ]] || fail "symlink component dry-run should not create archive dir"
}

test_no_fixed_tmp_output_residue() {
  local path=""

  for path in \
    /tmp/rev-harness-janitor-apply.out \
    /tmp/rev-harness-janitor-apply.err \
    /tmp/rev-harness-janitor-symlink.out \
    /tmp/rev-harness-janitor-symlink.err \
    /tmp/rev-harness-janitor-outside.out \
    /tmp/rev-harness-janitor-outside.err \
    /tmp/rev-harness-janitor-outside-archive.out \
    /tmp/rev-harness-janitor-outside-archive.err \
    /tmp/rev-harness-janitor-outside-archive-dry.out \
    /tmp/rev-harness-janitor-outside-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-archive-dry.out \
    /tmp/rev-harness-janitor-symlink-archive-dry.err \
    /tmp/rev-harness-janitor-symlink-component-dry.out \
    /tmp/rev-harness-janitor-symlink-component-dry.err; do
    [[ ! -e "$path" ]] || fail "fixed /tmp residue should not remain: $path"
  done
}

cleanup_legacy_fixed_tmp_residue
setup_test_project

test_help_documents_safety_contract
test_inspect_summarizes_fixture_without_moving
test_inspect_default_avoids_unbounded_du_and_find
test_plan_is_dry_run
test_archive_without_archive_dir_is_dry_run
test_archive_with_archive_dir_is_dry_run_and_non_mutating
test_json_archive_with_archive_dir_is_non_mutating
test_json_plan_reports_no_delete_path
test_plan_uses_single_tracked_file_probe_for_many_candidates
test_pruner_preserves_tracked_tmp_files_when_project_path_has_glob_metacharacters
test_plan_candidate_discovery_is_bounded_to_known_locations
test_janitor_extensions_report_manifest_residue_without_mutation
test_janitor_extension_scan_is_bounded_to_known_residue_locations
test_apply_path_fails_closed
test_symlink_and_path_escape_fail_closed
test_archive_dry_run_validates_archive_dir
test_no_fixed_tmp_output_residue

printf 'PASS: rev_harness_janitor_test\n'
