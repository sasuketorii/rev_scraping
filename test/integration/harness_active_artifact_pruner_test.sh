#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PRUNER="$PROJECT_ROOT/scripts/harness-active-artifact-pruner.sh"
FIXTURE_ROOT="$PROJECT_ROOT/.claude/tmp/pruner-test.$$"
PRUNER_OUTPUT_ROOT="$FIXTURE_ROOT/test-output"
OUTSIDE_ROOT=""

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

contains() {
  local haystack="$1"
  local needle="$2"
  grep -Fq -- "$needle" <<<"$haystack"
}

cleanup() {
  /bin/rm -rf "$FIXTURE_ROOT"
  if [[ -n "$OUTSIDE_ROOT" ]]; then
    /bin/rm -rf "$OUTSIDE_ROOT"
  fi
}

trap cleanup EXIT

cleanup_legacy_fixed_tmp_residue() {
  /bin/rm -f /tmp/harness-pruner-*.out /tmp/harness-pruner-*.err 2>/dev/null || true
}

run_pruner() {
  (cd "$PROJECT_ROOT" && bash "$PRUNER" "$@")
}

output_path() {
  local name="$1"

  mkdir -p "$PRUNER_OUTPUT_ROOT"
  printf '%s/%s\n' "$PRUNER_OUTPUT_ROOT" "$name"
}

reset_fixture() {
  /bin/rm -rf "$FIXTURE_ROOT"
  mkdir -p "$FIXTURE_ROOT" "$PRUNER_OUTPUT_ROOT"
}

make_run_dir() {
  local dir="$1"
  local stamp="$2"

  mkdir -p "$dir"
  printf 'summary\n' >"$dir/summary.md"
  touch -t "$stamp" "$dir" "$dir/summary.md"
}

write_lifecycle_manifest() {
  local dir="$1"
  local state="$2"
  local run_disposable="$3"
  local latest_pointer="${4:-none}"
  local pinned_baseline="${5:-none}"
  local safe_delete_class="${6:-scratch}"
  local superseded_by="${7:-none}"

  mkdir -p "$dir"
  jq -n \
    --arg schema_version "artifact-lifecycle/v1" \
    --arg owner "script" \
    --arg producer "test" \
    --arg purpose "pruner fixture" \
    --arg authority "test/integration/harness_active_artifact_pruner_test.sh" \
    --arg task_id "task-pruner" \
    --arg slice_id "slice-pruner" \
    --arg run_id "$(basename "$dir")" \
    --arg state "$state" \
    --arg disposition "scratch" \
    --arg latest_pointer "$latest_pointer" \
    --arg pinned_baseline "$pinned_baseline" \
    --arg run_disposable "$run_disposable" \
    --arg supersedes "none" \
    --arg superseded_by "$superseded_by" \
    --arg ttl "none" \
    --arg archive_after "none" \
    --arg safe_delete_after "none" \
    --arg safe_delete_class "$safe_delete_class" \
    --arg manifest_path "fixture/artifact-lifecycle-manifest.json" \
    --arg created_at "2020-01-01T00:00:00Z" \
    --arg completed_at "2020-01-01T00:00:00Z" \
    '$ARGS.named' > "$dir/artifact-lifecycle-manifest.json"
}

json_field() {
  local json="$1"
  local filter="$2"

  jq -r "$filter" <<<"$json"
}

test_dry_run_does_not_move() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  output="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "would_archive: 20200101_000001" || fail "dry-run should report candidate"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "dry-run should not move candidate"
}

test_latest_pointers_are_kept() {
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  printf '{}\n' >"$FIXTURE_ROOT/last_result.json"
  printf 'summary\n' >"$FIXTURE_ROOT/last_summary.txt"
  printf 'feedback\n' >"$FIXTURE_ROOT/last_feedback.md"

  run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >/dev/null

  [[ -f "$FIXTURE_ROOT/last_result.json" ]] || fail "last_result.json should remain"
  [[ -f "$FIXTURE_ROOT/last_summary.txt" ]] || fail "last_summary.txt should remain"
  [[ -f "$FIXTURE_ROOT/last_feedback.md" ]] || fail "last_feedback.md should remain"
  [[ -d "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "old run dir should archive"
}

test_keep_latest_retains_newest_n() {
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/20200102_000002" "202001020000"
  make_run_dir "$FIXTURE_ROOT/20200103_000003" "202001030000"

  run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 1 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >/dev/null

  [[ -d "$FIXTURE_ROOT/20200103_000003" ]] || fail "newest run should be kept"
  [[ -d "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "oldest run should archive"
  [[ -d "$FIXTURE_ROOT/.archive/20200102_000002" ]] || fail "second oldest run should archive"
}

test_max_age_selects_only_old_dirs() {
  local json=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/20990101_000001" "209901010000"

  json="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 14 --json)"

  [[ "$(json_field "$json" '.action_count')" == "1" ]] || fail "only old dir should be selected"

  run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 14 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >/dev/null

  [[ -d "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "old run should archive"
  [[ -d "$FIXTURE_ROOT/20990101_000001" ]] || fail "fresh run should remain"
}

test_manifest_candidate_allows_named_run_and_protects_latest() {
  local output=""
  reset_fixture
  write_lifecycle_manifest "$FIXTURE_ROOT/named-scratch.ABC123" "superseded" "YES" "none" "none" "scratch" "next-run"
  write_lifecycle_manifest "$FIXTURE_ROOT/active-run.XYZ789" "active" "NO" "latest" "none" "never"
  touch -t "202001010000" "$FIXTURE_ROOT/named-scratch.ABC123" "$FIXTURE_ROOT/active-run.XYZ789"

  output="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"

  contains "$output" "would_archive: named-scratch.ABC123 (manifest-managed)" \
    || fail "manifest-managed named scratch should be reported"
  contains "$output" "active-run.XYZ789" \
    && fail "active latest manifest should not be archived"

  run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/archive" >/dev/null

  [[ -d "$FIXTURE_ROOT/archive/named-scratch.ABC123" ]] || fail "manifest-managed named scratch should archive"
  [[ -d "$FIXTURE_ROOT/active-run.XYZ789" ]] || fail "active latest manifest should remain"
}

test_superseded_manifest_requires_superseded_by() {
  local output=""
  reset_fixture
  write_lifecycle_manifest "$FIXTURE_ROOT/superseded-without-link.ABC123" "superseded" "YES" "none" "none" "scratch" "none"
  touch -t "202001010000" "$FIXTURE_ROOT/superseded-without-link.ABC123"

  output="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0)"
  contains "$output" "superseded-without-link.ABC123" \
    && fail "superseded manifest without superseded_by should remain protected"
  return 0
}

test_partial_timestamp_pid_run_is_archive_candidate() {
  local json=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20260425T010203Z_12345" "202001010000"

  json="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"
  [[ "$(json_field "$json" '.action_count')" == "1" ]] || fail "timestamp_pid run should be classified"
  jq -e '.actions == ["20260425T010203Z_12345"]' <<<"$json" >/dev/null \
    || fail "timestamp_pid run should appear in JSON actions"
}

test_noop_json_actions_is_empty_array() {
  local json=""
  reset_fixture

  json="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"
  [[ "$(json_field "$json" '.action_count')" == "0" ]] || fail "empty fixture should have zero actions"
  jq -e '.actions == []' <<<"$json" >/dev/null \
    || fail "no-op JSON actions should be []"
}

test_named_mktemp_legacy_is_archive_only_candidate() {
  local json=""
  reset_fixture
  mkdir -p "$FIXTURE_ROOT/plan-review.PufjuT"
  printf 'scratch\n' > "$FIXTURE_ROOT/plan-review.PufjuT/scratch.txt"
  touch -t "202001010000" "$FIXTURE_ROOT/plan-review.PufjuT"

  json="$(run_pruner --root "$FIXTURE_ROOT" --keep-latest 0 --max-age-days 0 --json)"
  [[ "$(json_field "$json" '.action_count')" == "1" ]] || fail "named mktemp scratch should be classified"
  jq -e '.actions[0] == "plan-review.PufjuT"' <<<"$json" >/dev/null \
    || fail "named mktemp scratch should appear in JSON actions"
}

test_gnu_stat_mtime_takes_precedence_over_nonnumeric_stat_f() {
  local shim_dir=""
  local stat_log=""

  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/20200103_000003" "202001030000"
  shim_dir="$FIXTURE_ROOT/stat-shim-bin"
  stat_log="$FIXTURE_ROOT/stat-shim.log"
  mkdir -p "$shim_dir"
  cat >"$shim_dir/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

printf '%s\n' "$*" >>"${STAT_SHIM_LOG:?}"

if [[ "${1:-}" == "-c" && "${2:-}" == "%Y" ]]; then
  case "${3:-}" in
    *20200103_000003) printf '300\n' ;;
    *20200101_000001) printf '100\n' ;;
    *) printf '1\n' ;;
  esac
  exit 0
fi

if [[ "${1:-}" == "-f" && "${2:-}" == "%m" ]]; then
  printf 'not a numeric mtime\n'
  exit 0
fi

printf 'unexpected stat invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$shim_dir/stat"

  STAT_SHIM_LOG="$stat_log" PATH="$shim_dir:$PATH" run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 1 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >/dev/null

  [[ -d "$FIXTURE_ROOT/20200103_000003" ]] || fail "GNU stat mtime should keep newest run"
  [[ -d "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "GNU stat mtime should archive older run"
  contains "$(<"$stat_log")" "-c %Y" || fail "GNU stat form should be used for mtime"
}

test_mtime_rejects_nonnumeric_stat_output() {
  local shim_dir=""
  local stdout_file=""
  local stderr_file=""

  reset_fixture
  stdout_file="$(output_path harness-pruner-nonnumeric-stat.out)"
  stderr_file="$(output_path harness-pruner-nonnumeric-stat.err)"
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  shim_dir="$FIXTURE_ROOT/stat-shim-bin"
  mkdir -p "$shim_dir"
  cat >"$shim_dir/stat" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" == "-c" && "${2:-}" == "%Y" ]]; then
  exit 1
fi

if [[ "${1:-}" == "-f" && "${2:-}" == "%m" ]]; then
  printf 'not a numeric mtime\n'
  exit 0
fi

printf 'unexpected stat invocation: %s\n' "$*" >&2
exit 2
EOF
  chmod +x "$shim_dir/stat"

  if PATH="$shim_dir:$PATH" run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 >"$stdout_file" 2>"$stderr_file"; then
    fail "nonnumeric stat output should fail closed"
  fi

  contains "$(<"$stderr_file")" "could not determine integer mtime" \
    || fail "nonnumeric stat failure should report integer mtime error"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain after nonnumeric stat failure"
}

test_fail_closed_roots() {
  local symlink_root="$PROJECT_ROOT/.claude/tmp/pruner-test-link.$$"
  local symlink_stdout=""
  local symlink_stderr=""
  local symlink_trailing_stdout=""
  local symlink_trailing_stderr=""
  local symlink_dot_stdout=""
  local symlink_dot_stderr=""
  local outside_stdout=""
  local outside_stderr=""
  local slash_stdout=""
  local slash_stderr=""
  local empty_stdout=""
  local empty_stderr=""
  reset_fixture
  symlink_stdout="$(output_path harness-pruner-symlink.out)"
  symlink_stderr="$(output_path harness-pruner-symlink.err)"
  symlink_trailing_stdout="$(output_path harness-pruner-symlink-trailing.out)"
  symlink_trailing_stderr="$(output_path harness-pruner-symlink-trailing.err)"
  symlink_dot_stdout="$(output_path harness-pruner-symlink-dot.out)"
  symlink_dot_stderr="$(output_path harness-pruner-symlink-dot.err)"
  outside_stdout="$(output_path harness-pruner-outside.out)"
  outside_stderr="$(output_path harness-pruner-outside.err)"
  slash_stdout="$(output_path harness-pruner-slash.out)"
  slash_stderr="$(output_path harness-pruner-slash.err)"
  empty_stdout="$(output_path harness-pruner-empty.out)"
  empty_stderr="$(output_path harness-pruner-empty.err)"
  mkdir -p "$FIXTURE_ROOT/real-root"
  ln -s "$FIXTURE_ROOT/real-root" "$symlink_root"

  if run_pruner --root "$symlink_root" >"$symlink_stdout" 2>"$symlink_stderr"; then
    /bin/rm -f "$symlink_root"
    fail "symlink root should fail closed"
  fi

  if run_pruner --root "$symlink_root/" >"$symlink_trailing_stdout" 2>"$symlink_trailing_stderr"; then
    /bin/rm -f "$symlink_root"
    fail "trailing slash symlink root should fail closed"
  fi

  if run_pruner --root "$symlink_root/." >"$symlink_dot_stdout" 2>"$symlink_dot_stderr"; then
    /bin/rm -f "$symlink_root"
    fail "slash-dot symlink root should fail closed"
  fi
  /bin/rm -f "$symlink_root"

  OUTSIDE_ROOT="$(mktemp -d)"
  if run_pruner --root "$OUTSIDE_ROOT" >"$outside_stdout" 2>"$outside_stderr"; then
    fail "repo-outside root should fail closed"
  fi

  if run_pruner --root / >"$slash_stdout" 2>"$slash_stderr"; then
    fail "/ root should fail closed"
  fi

  if run_pruner --root '' >"$empty_stdout" 2>"$empty_stderr"; then
    fail "empty root should fail closed"
  fi
}

test_execute_archives_inside_archive_dir_only() {
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/task-a/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/task-a/20200102_000002" "202001020000"

  run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >/dev/null

  [[ -d "$FIXTURE_ROOT/.archive/task-a/20200101_000001" ]] || fail "nested old run should archive under archive dir"
  [[ -d "$FIXTURE_ROOT/.archive/task-a/20200102_000002" ]] || fail "nested second run should archive under archive dir"
  [[ ! -d "$FIXTURE_ROOT/task-a/20200101_000001" ]] || fail "old run should move from source"
  [[ ! -e "$PROJECT_ROOT/20200101_000001" ]] || fail "archive should not escape root"
}

test_execute_archives_nested_timestamp_parent_once() {
  local output=""
  reset_fixture
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/20200101_000001/20200102_000002" "202001020000"
  touch -t "202001010000" "$FIXTURE_ROOT/20200101_000001"

  output="$(run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive")"

  contains "$output" "action_count: 1" || fail "nested timestamp parent should be the only action"
  contains "$output" "archived: 20200101_000001 ->" || fail "parent timestamp dir should archive"
  contains "$output" "archived: 20200101_000001/20200102_000002 ->" \
    && fail "nested timestamp child should not be archived separately"
  [[ -d "$FIXTURE_ROOT/.archive/20200101_000001/20200102_000002" ]] \
    || fail "archived parent should contain nested timestamp child"
  [[ ! -e "$FIXTURE_ROOT/20200101_000001" ]] || fail "source parent should move atomically"
}

test_execute_destination_conflict_does_not_partially_move() {
  local stdout_file=""
  local stderr_file=""
  reset_fixture
  stdout_file="$(output_path harness-pruner-conflict.out)"
  stderr_file="$(output_path harness-pruner-conflict.err)"
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  make_run_dir "$FIXTURE_ROOT/20200102_000002" "202001020000"
  make_run_dir "$FIXTURE_ROOT/.archive/20200101_000001" "202001010000"

  if run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >"$stdout_file" 2>"$stderr_file"; then
    fail "archive destination conflict should fail"
  fi

  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "conflicted source should remain"
  [[ -d "$FIXTURE_ROOT/20200102_000002" ]] || fail "earlier preflight candidate should not be moved"
  [[ -d "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "existing archive conflict should remain"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200102_000002" ]] || fail "no candidate should archive after preflight conflict"
}

test_execute_dangling_symlink_destination_conflict_does_not_partially_move() {
  local stdout_file=""
  local stderr_file=""
  reset_fixture
  stdout_file="$(output_path harness-pruner-dangling-conflict.out)"
  stderr_file="$(output_path harness-pruner-dangling-conflict.err)"
  make_run_dir "$FIXTURE_ROOT/20200103_000003" "202001030000"
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"
  mkdir -p "$FIXTURE_ROOT/.archive"
  ln -s "$FIXTURE_ROOT/.archive/missing-target" "$FIXTURE_ROOT/.archive/20200101_000001"

  if run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >"$stdout_file" 2>"$stderr_file"; then
    fail "dangling symlink archive destination conflict should fail"
  fi

  [[ -d "$FIXTURE_ROOT/20200103_000003" ]] || fail "unconflicted source should remain after dangling symlink destination preflight"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "conflicted source should remain after dangling symlink destination preflight"
  [[ -L "$FIXTURE_ROOT/.archive/20200101_000001" ]] || fail "dangling symlink archive conflict should remain"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200103_000003" ]] || fail "no candidate should archive before dangling symlink conflict failure"
}

test_execute_destination_parent_file_conflict_does_not_partially_move() {
  local stdout_file=""
  local stderr_file=""
  reset_fixture
  stdout_file="$(output_path harness-pruner-parent-conflict.out)"
  stderr_file="$(output_path harness-pruner-parent-conflict.err)"
  make_run_dir "$FIXTURE_ROOT/20200103_000003" "202001030000"
  make_run_dir "$FIXTURE_ROOT/task-a/20200102_000002" "202001020000"
  mkdir -p "$FIXTURE_ROOT/.archive"
  printf 'not a directory\n' >"$FIXTURE_ROOT/.archive/task-a"

  if run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/.archive" >"$stdout_file" 2>"$stderr_file"; then
    fail "archive destination parent file conflict should fail"
  fi

  [[ -d "$FIXTURE_ROOT/20200103_000003" ]] || fail "unconflicted source should remain after parent conflict preflight"
  [[ -d "$FIXTURE_ROOT/task-a/20200102_000002" ]] || fail "conflicted nested source should remain"
  [[ -f "$FIXTURE_ROOT/.archive/task-a" ]] || fail "existing archive parent file should remain"
  [[ ! -e "$FIXTURE_ROOT/.archive/20200103_000003" ]] || fail "no candidate should archive before parent conflict failure"
}

test_execute_archive_dir_inside_candidate_does_not_partially_move() {
  local stdout_file=""
  local stderr_file=""
  reset_fixture
  stdout_file="$(output_path harness-pruner-inside-candidate.out)"
  stderr_file="$(output_path harness-pruner-inside-candidate.err)"
  make_run_dir "$FIXTURE_ROOT/20200103_000003" "202001030000"
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  if run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/20200101_000001/.archive" >"$stdout_file" 2>"$stderr_file"; then
    fail "archive dir inside candidate should fail"
  fi

  [[ -d "$FIXTURE_ROOT/20200103_000003" ]] || fail "unconflicted source should remain when archive dir is inside candidate"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "self-contained archive source should remain"
  [[ ! -e "$FIXTURE_ROOT/20200101_000001/.archive/20200103_000003" ]] || fail "no other candidate should archive into candidate-local archive"
}

test_execute_archive_dir_inside_kept_candidate_does_not_move() {
  local stdout_file=""
  local stderr_file=""
  reset_fixture
  stdout_file="$(output_path harness-pruner-kept-candidate-archive.out)"
  stderr_file="$(output_path harness-pruner-kept-candidate-archive.err)"
  make_run_dir "$FIXTURE_ROOT/20200103_000003" "202001030000"
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  if run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 1 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$FIXTURE_ROOT/20200103_000003/.archive" >"$stdout_file" 2>"$stderr_file"; then
    fail "archive dir inside kept candidate should fail"
  fi

  [[ -d "$FIXTURE_ROOT/20200103_000003" ]] || fail "kept candidate should remain"
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "old candidate should remain when archive dir is inside kept candidate"
  [[ ! -e "$FIXTURE_ROOT/20200103_000003/.archive" ]] || fail "archive dir should not be created inside kept candidate"
  [[ ! -e "$FIXTURE_ROOT/20200103_000003/.archive/20200101_000001" ]] || fail "old candidate should not archive into kept candidate"
}

test_execute_requires_archive_dir_inside_root() {
  local outside_archive=""
  local symlink_archive=""
  local no_archive_stdout=""
  local no_archive_stderr=""
  local bad_archive_stdout=""
  local bad_archive_stderr=""
  local outside_archive_stdout=""
  local outside_archive_stderr=""
  local archive_symlink_stdout=""
  local archive_symlink_stderr=""

  reset_fixture
  no_archive_stdout="$(output_path harness-pruner-no-archive.out)"
  no_archive_stderr="$(output_path harness-pruner-no-archive.err)"
  bad_archive_stdout="$(output_path harness-pruner-bad-archive.out)"
  bad_archive_stderr="$(output_path harness-pruner-bad-archive.err)"
  outside_archive_stdout="$(output_path harness-pruner-outside-archive.out)"
  outside_archive_stderr="$(output_path harness-pruner-outside-archive.err)"
  archive_symlink_stdout="$(output_path harness-pruner-archive-symlink-trailing.out)"
  archive_symlink_stderr="$(output_path harness-pruner-archive-symlink-trailing.err)"
  make_run_dir "$FIXTURE_ROOT/20200101_000001" "202001010000"

  if run_pruner --root "$FIXTURE_ROOT" --execute >"$no_archive_stdout" 2>"$no_archive_stderr"; then
    fail "execute without archive dir should fail"
  fi

  if run_pruner --root "$FIXTURE_ROOT" --execute --archive-dir "$PROJECT_ROOT/.claude/tmp" >"$bad_archive_stdout" 2>"$bad_archive_stderr"; then
    fail "archive dir outside selected root should fail"
  fi

  OUTSIDE_ROOT="$(mktemp -d)"
  outside_archive="$OUTSIDE_ROOT/archive"
  if run_pruner --root "$FIXTURE_ROOT" --execute --archive-dir "$outside_archive" >"$outside_archive_stdout" 2>"$outside_archive_stderr"; then
    fail "repo-outside archive dir should fail"
  fi
  [[ ! -e "$outside_archive" ]] || fail "repo-outside archive dir should not be created"

  mkdir -p "$FIXTURE_ROOT/archive-target"
  symlink_archive="$FIXTURE_ROOT/archive-link"
  ln -s "$FIXTURE_ROOT/archive-target" "$symlink_archive"
  if run_pruner \
    --root "$FIXTURE_ROOT" \
    --keep-latest 0 \
    --max-age-days 0 \
    --execute \
    --archive-dir "$symlink_archive/" >"$archive_symlink_stdout" 2>"$archive_symlink_stderr"; then
    fail "trailing slash symlink archive dir should fail closed"
  fi
  [[ -d "$FIXTURE_ROOT/20200101_000001" ]] || fail "source should remain when archive dir symlink fails"
}

test_no_fixed_tmp_output_residue() {
  local residue=""

  residue="$(find /tmp -maxdepth 1 \( -name 'harness-pruner-*.out' -o -name 'harness-pruner-*.err' \) -print -quit 2>/dev/null || true)"
  [[ -z "$residue" ]] || fail "fixed /tmp residue should not remain: $residue"
}

cleanup_legacy_fixed_tmp_residue

test_dry_run_does_not_move
test_latest_pointers_are_kept
test_keep_latest_retains_newest_n
test_max_age_selects_only_old_dirs
test_manifest_candidate_allows_named_run_and_protects_latest
test_superseded_manifest_requires_superseded_by
test_partial_timestamp_pid_run_is_archive_candidate
test_noop_json_actions_is_empty_array
test_named_mktemp_legacy_is_archive_only_candidate
test_gnu_stat_mtime_takes_precedence_over_nonnumeric_stat_f
test_mtime_rejects_nonnumeric_stat_output
test_fail_closed_roots
test_execute_archives_inside_archive_dir_only
test_execute_archives_nested_timestamp_parent_once
test_execute_destination_conflict_does_not_partially_move
test_execute_dangling_symlink_destination_conflict_does_not_partially_move
test_execute_destination_parent_file_conflict_does_not_partially_move
test_execute_archive_dir_inside_candidate_does_not_partially_move
test_execute_archive_dir_inside_kept_candidate_does_not_move
test_execute_requires_archive_dir_inside_root
test_no_fixed_tmp_output_residue

printf 'PASS: harness_active_artifact_pruner_test\n'
