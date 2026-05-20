#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TASK_ID=""
SLICE_ID=""
FIXTURE_PATH=""
BASELINE_COMMAND=""
CANDIDATE_COMMAND=""
RUN_COUNT=3
TIME_FORMAT=""
RUN_ID=""
MANAGED_ROOT=""
ARTIFACT_ROOT=""
SHA256_TOOL=""
MODEL_POLICY_SOURCE_REL=".agent/registry/model_policy.json"
MODEL_POLICY_GENERATED_REL=".agent/generated/codex_model_policy.runtime.json"
MODEL_POLICY_SOURCE_SHA256=""
MODEL_POLICY_GENERATED_SHA256=""
MODEL_POLICY_GENERATED_SOURCE_POLICY_SHA256=""
MODEL_POLICY_GENERATED_SCHEMA_VERSION=""
MODEL_POLICY_GENERATED_CURRENT_MODEL=""
MODEL_POLICY_GENERATED_STABLE_DEFAULT_MODEL=""
MODEL_POLICY_GENERATED_MINIMUM_ALLOWED_MODEL=""

usage() {
  cat <<'EOF'
Usage:
  bash scripts/harness-benchmark.sh \
    --task-id <task-id> \
    --slice-id <slice-id> \
    --fixture <file-or-dir> \
    --baseline-command <command> \
    --candidate-command <command> \
    [--runs <count>]

Canonical benchmark/memory contract surface.

This script writes artifacts under:
  .claude/tmp/benchmarks/<task-id>/<slice-id>/runs/<run-id>/

Required artifacts:
  - artifact-lifecycle-manifest.json
  - model-policy-linkage.json
  - summary.tsv
  - fixture.sha256
  - env.txt
  - baseline_command.txt
  - candidate_command.txt
  - wall_ms_{baseline|candidate}_runNN.txt
  - peak_rss_kb_{baseline|candidate}_runNN.txt

Pointer / retention artifacts:
  - .claude/tmp/benchmarks/<task-id>/<slice-id>/latest.json
  - .claude/tmp/benchmarks/<task-id>/<slice-id>/baselines/<baseline-id>.json

Notes:
  - `--runs` defaults to `3`.
  - Commands are executed verbatim via `bash -lc`.
  - The fixture path is exposed to commands as HARNESS_BENCH_FIXTURE.
  - Existing non-empty artifact roots are rejected to keep the contract fail-closed.

Examples:
  bash scripts/harness-benchmark.sh \
    --task-id task-contract-v1 \
    --slice-id slice-001 \
    --fixture test/fixtures/sample.txt \
    --baseline-command 'cat "$HARNESS_BENCH_FIXTURE" >/dev/null' \
    --candidate-command 'wc -c "$HARNESS_BENCH_FIXTURE" >/dev/null'
EOF
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_command() {
  local name="$1"
  command -v "$name" >/dev/null 2>&1 || fail "missing required command: $name"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

new_run_id() {
  if [[ -n "${HARNESS_BENCH_RUN_ID:-}" ]]; then
    validate_id "$HARNESS_BENCH_RUN_ID" "HARNESS_BENCH_RUN_ID"
    printf '%s\n' "$HARNESS_BENCH_RUN_ID"
    return 0
  fi
  printf '%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

detect_sha256_tool() {
  if command -v shasum >/dev/null 2>&1; then
    printf 'shasum\n'
    return 0
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    printf 'sha256sum\n'
    return 0
  fi

  fail "missing required command: shasum or sha256sum"
}

validate_id() {
  local value="$1"
  local label="$2"

  [[ -n "$value" ]] || fail "missing required argument: $label"
  [[ "$value" != "." && "$value" != ".." ]] || fail "invalid $label: $value"
  [[ "$value" != *"/"* && "$value" != *"\\"* ]] || fail "invalid $label: $value"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid $label: $value"
}

resolve_existing_path() {
  local input_path="$1"
  local dir_part=""
  local base_part=""

  [[ -e "$input_path" ]] || fail "fixture does not exist: $input_path"

  dir_part="$(dirname "$input_path")"
  base_part="$(basename "$input_path")"
  (
    cd "$dir_part" &&
      printf '%s/%s\n' "$(pwd -P)" "$base_part"
  )
}

detect_time_format() {
  if /usr/bin/time -f '%e\t%M' bash -lc 'true' >/dev/null 2>&1; then
    printf 'gnu\n'
    return 0
  fi

  if /usr/bin/time -l bash -lc 'true' >/dev/null 2>&1; then
    printf 'bsd\n'
    return 0
  fi

  fail "unsupported /usr/bin/time implementation"
}

hash_file() {
  local path="$1"

  if [[ "$SHA256_TOOL" == "shasum" ]]; then
    shasum -a 256 "$path" | awk '{print $1}'
    return 0
  fi

  sha256sum "$path" | awk '{print $1}'
}

hash_stdin() {
  if [[ "$SHA256_TOOL" == "shasum" ]]; then
    shasum -a 256 | awk '{print $1}'
    return 0
  fi

  sha256sum | awk '{print $1}'
}

hash_directory() {
  local path="$1"
  local file_count=""

  file_count="$(find "$path" -type f | wc -l | tr -d '[:space:]')"
  [[ "${file_count:-0}" -gt 0 ]] || fail "fixture directory is empty: $path"

  find "$path" -type f | LC_ALL=C sort | while IFS= read -r file_path; do
    local file_hash=""
    local rel_path=""

    file_hash="$(hash_file "$file_path")"
    rel_path="${file_path#"$path"/}"
    printf '%s  %s\n' "$file_hash" "$rel_path"
  done | hash_stdin
}

compute_fixture_hash() {
  local path="$1"

  if [[ -f "$path" ]]; then
    hash_file "$path"
    return 0
  fi

  if [[ -d "$path" ]]; then
    hash_directory "$path"
    return 0
  fi

  fail "fixture must be a regular file or directory: $path"
}

run_tag() {
  printf '%02d' "$1"
}

wall_file_for() {
  local subject="$1"
  local run_number="$2"
  printf '%s/wall_ms_%s_run%s.txt\n' "$ARTIFACT_ROOT" "$subject" "$(run_tag "$run_number")"
}

rss_file_for() {
  local subject="$1"
  local run_number="$2"
  printf '%s/peak_rss_kb_%s_run%s.txt\n' "$ARTIFACT_ROOT" "$subject" "$(run_tag "$run_number")"
}

parse_time_file() {
  local time_output_file="$1"
  local wall_ms=""
  local peak_rss_kb=""
  local rss_value=""

  if [[ "$TIME_FORMAT" == "gnu" ]]; then
    wall_ms="$(awk -F '\t' 'NR == 1 { printf "%.0f\n", ($1 * 1000) }' "$time_output_file")"
    peak_rss_kb="$(awk -F '\t' 'NR == 1 { print $2 }' "$time_output_file")"
  else
    wall_ms="$(awk '/ real / { printf "%.0f\n", ($1 * 1000); exit }' "$time_output_file")"
    rss_value="$(awk '/maximum resident set size$/ { print $1; exit }' "$time_output_file")"
    if [[ -z "$rss_value" ]]; then
      rss_value="$(awk '/peak memory footprint$/ { print $1; exit }' "$time_output_file")"
    fi
    [[ -n "$rss_value" ]] || fail "failed to parse peak RSS from /usr/bin/time output"
    peak_rss_kb="$(awk -v rss_bytes="$rss_value" 'BEGIN { printf "%d\n", int((rss_bytes + 1023) / 1024) }')"
  fi

  [[ "$wall_ms" =~ ^[0-9]+$ ]] || fail "failed to parse wall clock milliseconds"
  [[ "$peak_rss_kb" =~ ^[0-9]+$ ]] || fail "failed to parse peak RSS kilobytes"
  printf '%s\t%s\n' "$wall_ms" "$peak_rss_kb"
}

measure_subject_run() {
  local subject="$1"
  local command_string="$2"
  local run_number="$3"
  local time_output_file=""
  local command_stdout_file=""
  local command_stderr_file=""
  local metrics=""
  local wall_ms=""
  local peak_rss_kb=""
  local run_label=""

  run_label="$(run_tag "$run_number")"
  time_output_file="$(mktemp "$ARTIFACT_ROOT/.${subject}_run${run_label}.XXXXXX")"
  command_stdout_file="$(mktemp "$ARTIFACT_ROOT/.${subject}_run${run_label}.stdout.XXXXXX")"
  command_stderr_file="$(mktemp "$ARTIFACT_ROOT/.${subject}_run${run_label}.stderr.XXXXXX")"

  if [[ "$TIME_FORMAT" == "gnu" ]]; then
    if /usr/bin/time -o "$time_output_file" -f '%e\t%M' \
      env \
        HARNESS_BENCH_FIXTURE="$FIXTURE_PATH" \
        HARNESS_BENCH_COMMAND="$command_string" \
        HARNESS_BENCH_STDOUT_FILE="$command_stdout_file" \
        HARNESS_BENCH_STDERR_FILE="$command_stderr_file" \
        bash -lc 'exec >"$HARNESS_BENCH_STDOUT_FILE" 2>"$HARNESS_BENCH_STDERR_FILE"; eval "$HARNESS_BENCH_COMMAND"' \
      >/dev/null 2>&1; then
      :
    else
      local status=$?
      rm -f "$command_stdout_file" "$command_stderr_file"
      rm -f "$time_output_file"
      fail "$subject run${run_label} failed (rc=$status)"
    fi
  else
    if /usr/bin/time -l env \
      HARNESS_BENCH_FIXTURE="$FIXTURE_PATH" \
      HARNESS_BENCH_COMMAND="$command_string" \
      HARNESS_BENCH_STDOUT_FILE="$command_stdout_file" \
      HARNESS_BENCH_STDERR_FILE="$command_stderr_file" \
      bash -lc 'exec >"$HARNESS_BENCH_STDOUT_FILE" 2>"$HARNESS_BENCH_STDERR_FILE"; eval "$HARNESS_BENCH_COMMAND"' \
      2>"$time_output_file"; then
      :
    else
      local status=$?
      rm -f "$command_stdout_file" "$command_stderr_file"
      rm -f "$time_output_file"
      fail "$subject run${run_label} failed (rc=$status)"
    fi
  fi

  metrics="$(parse_time_file "$time_output_file")"
  wall_ms="${metrics%%$'\t'*}"
  peak_rss_kb="${metrics##*$'\t'}"

  printf '%s\n' "$wall_ms" > "$(wall_file_for "$subject" "$run_number")"
  printf '%s\n' "$peak_rss_kb" > "$(rss_file_for "$subject" "$run_number")"

  rm -f "$command_stdout_file" "$command_stderr_file"
  rm -f "$time_output_file"
  printf '%s\t%s\n' "$wall_ms" "$peak_rss_kb"
}

write_env_file() {
  local fixture_hash="$1"
  local fixture_descriptor="$2"

  {
    printf 'project_root=%s\n' "$PROJECT_ROOT"
    printf 'task_id=%s\n' "$TASK_ID"
    printf 'slice_id=%s\n' "$SLICE_ID"
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'managed_root=%s\n' "$MANAGED_ROOT"
    printf 'artifact_root=%s\n' "$ARTIFACT_ROOT"
    printf 'fixture=%s\n' "$fixture_descriptor"
    printf 'fixture_sha256=%s\n' "$fixture_hash"
    printf 'runs=%s\n' "$RUN_COUNT"
    printf 'time_format=%s\n' "$TIME_FORMAT"
    printf 'sha256_tool=%s\n' "$SHA256_TOOL"
    printf 'pwd=%s\n' "$(pwd -P)"
    printf 'uname=%s\n' "$(uname -a)"
    printf 'utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'bash=%s\n' "${BASH_VERSION:-unknown}"
  } > "$ARTIFACT_ROOT/env.txt"
}

compute_model_policy_linkage() {
  local source_path="$PROJECT_ROOT/$MODEL_POLICY_SOURCE_REL"
  local generated_path="$PROJECT_ROOT/$MODEL_POLICY_GENERATED_REL"

  [[ -f "$source_path" ]] || fail "missing model policy source: $MODEL_POLICY_SOURCE_REL"
  [[ -f "$generated_path" ]] || fail "missing generated model policy artifact: $MODEL_POLICY_GENERATED_REL"
  jq empty "$source_path" >/dev/null || fail "invalid model policy source JSON: $MODEL_POLICY_SOURCE_REL"
  jq empty "$generated_path" >/dev/null || fail "invalid generated model policy JSON: $MODEL_POLICY_GENERATED_REL"

  MODEL_POLICY_SOURCE_SHA256="$(hash_file "$source_path")"
  MODEL_POLICY_GENERATED_SHA256="$(hash_file "$generated_path")"
  MODEL_POLICY_GENERATED_SOURCE_POLICY_SHA256="$(jq -r '.source_policy_sha256 // empty' "$generated_path")"
  MODEL_POLICY_GENERATED_SCHEMA_VERSION="$(jq -r '.schema_version // empty' "$generated_path")"
  MODEL_POLICY_GENERATED_CURRENT_MODEL="$(jq -r '.current_model // empty' "$generated_path")"
  MODEL_POLICY_GENERATED_STABLE_DEFAULT_MODEL="$(jq -r '.stable_default_model // empty' "$generated_path")"
  MODEL_POLICY_GENERATED_MINIMUM_ALLOWED_MODEL="$(jq -r '.minimum_allowed_model // empty' "$generated_path")"

  [[ "$(jq -r '.source_policy_path // empty' "$generated_path")" == "$MODEL_POLICY_SOURCE_REL" ]] \
    || fail "generated model policy source path drift: $MODEL_POLICY_GENERATED_REL"
  [[ "$MODEL_POLICY_GENERATED_SOURCE_POLICY_SHA256" == "$MODEL_POLICY_SOURCE_SHA256" ]] \
    || fail "generated model policy source digest drift: $MODEL_POLICY_GENERATED_REL"
}

write_model_policy_linkage() {
  local linked_at="$1"
  local linkage_path="$ARTIFACT_ROOT/model-policy-linkage.json"

  jq -n \
    --arg schema_version "harness-benchmark/model-policy-linkage/v1" \
    --arg producer "scripts/harness-benchmark.sh" \
    --arg task_id "$TASK_ID" \
    --arg slice_id "$SLICE_ID" \
    --arg run_id "$RUN_ID" \
    --arg linked_at "$linked_at" \
    --arg source_policy_path "$MODEL_POLICY_SOURCE_REL" \
    --arg source_policy_digest_algorithm "sha256" \
    --arg source_policy_sha256 "$MODEL_POLICY_SOURCE_SHA256" \
    --arg generated_policy_path "$MODEL_POLICY_GENERATED_REL" \
    --arg generated_policy_digest_algorithm "sha256" \
    --arg generated_policy_sha256 "$MODEL_POLICY_GENERATED_SHA256" \
    --arg generated_policy_schema_version "$MODEL_POLICY_GENERATED_SCHEMA_VERSION" \
    --arg generated_policy_source_policy_sha256 "$MODEL_POLICY_GENERATED_SOURCE_POLICY_SHA256" \
    --arg generated_policy_current_model "$MODEL_POLICY_GENERATED_CURRENT_MODEL" \
    --arg generated_policy_stable_default_model "$MODEL_POLICY_GENERATED_STABLE_DEFAULT_MODEL" \
    --arg generated_policy_minimum_allowed_model "$MODEL_POLICY_GENERATED_MINIMUM_ALLOWED_MODEL" \
    '$ARGS.named' > "$linkage_path"
}

write_lifecycle_manifest() {
  local fixture_hash="$1"
  local created_at="$2"
  local manifest_path="$ARTIFACT_ROOT/artifact-lifecycle-manifest.json"
  local manifest_rel="${manifest_path#"$PROJECT_ROOT"/}"

  jq -n \
    --arg schema_version "artifact-lifecycle/v1" \
    --arg owner "script" \
    --arg producer "scripts/harness-benchmark.sh" \
    --arg purpose "benchmark run evidence" \
    --arg authority "docs/manual/harness-user-guide.md" \
    --arg task_id "$TASK_ID" \
    --arg slice_id "$SLICE_ID" \
    --arg run_id "$RUN_ID" \
    --arg state "active" \
    --arg disposition "active-evidence" \
    --arg latest_pointer "comparable-latest" \
    --arg pinned_baseline "benchmark-$fixture_hash" \
    --arg run_disposable "NO" \
    --arg supersedes "none" \
    --arg superseded_by "none" \
    --arg ttl "none" \
    --arg archive_after "none" \
    --arg safe_delete_after "none" \
    --arg safe_delete_class "never" \
    --arg manifest_path "$manifest_rel" \
    --arg created_at "$created_at" \
    --arg completed_at "none" \
    '$ARGS.named' > "$manifest_path"
}

manifest_path_from_pointer() {
  local pointer_path="$1"
  local manifest_rel=""
  local manifest_path=""
  local managed_root_real=""
  local manifest_parent_real=""
  local manifest_real=""

  [[ -f "$pointer_path" && ! -L "$pointer_path" ]] || return 1
  manifest_rel="$(jq -r '.manifest_path // empty' "$pointer_path" 2>/dev/null || true)"
  [[ -n "$manifest_rel" ]] || return 1
  [[ "$manifest_rel" != /* ]] || return 1
  case "$manifest_rel" in
    *"/../"*|../*|*/..|.|..|*"//"*) return 1 ;;
  esac

  manifest_path="$PROJECT_ROOT/$manifest_rel"
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || return 1
  managed_root_real="$(cd "$MANAGED_ROOT" && pwd -P 2>/dev/null)" || return 1
  manifest_parent_real="$(cd "$(dirname "$manifest_path")" && pwd -P 2>/dev/null)" || return 1
  manifest_real="$manifest_parent_real/$(basename "$manifest_path")"
  case "$manifest_real" in
    "$managed_root_real"/runs/*/artifact-lifecycle-manifest.json) ;;
    *) return 1 ;;
  esac
  case "$manifest_path" in
    "$MANAGED_ROOT"/runs/*/artifact-lifecycle-manifest.json) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$manifest_path"
}

mark_manifest_superseded() {
  local manifest_path="$1"
  local retire_baseline="$2"
  local tmp_path=""

  [[ "$manifest_path" != "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json" ]] || return 0
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || return 0

  tmp_path="${manifest_path}.tmp"
  if [[ "$retire_baseline" == "YES" ]]; then
    jq \
      --arg superseded_by "$RUN_ID" \
      '.state = "superseded"
       | .latest_pointer = "none"
       | .pinned_baseline = "none"
       | .superseded_by = $superseded_by
       | .run_disposable = "YES"
       | .safe_delete_class = "archived-managed-run"' \
      "$manifest_path" > "$tmp_path"
  else
    jq \
      --arg superseded_by "$RUN_ID" \
      '.state = "superseded"
       | .latest_pointer = "none"
       | .superseded_by = $superseded_by
       | if (.pinned_baseline // "none") == "none" then
           .run_disposable = "YES" | .safe_delete_class = "archived-managed-run"
         else
           .run_disposable = "NO" | .safe_delete_class = "never"
         end' \
      "$manifest_path" > "$tmp_path"
  fi
  mv "$tmp_path" "$manifest_path"
}

retire_previous_pointer_manifest() {
  local pointer_path="$1"
  local retire_baseline="$2"
  local manifest_path=""

  [[ ! -e "$pointer_path" && ! -L "$pointer_path" ]] && return 0
  manifest_path="$(manifest_path_from_pointer "$pointer_path")" \
    || fail "invalid lifecycle pointer manifest path: $pointer_path"
  mark_manifest_superseded "$manifest_path" "$retire_baseline"
}

write_latest_and_baseline_pointers() {
  local fixture_hash="$1"
  local completed_at="$2"
  local latest_path="$MANAGED_ROOT/latest.json"
  local baseline_id="benchmark-$fixture_hash"
  local baseline_path="$MANAGED_ROOT/baselines/$baseline_id.json"
  local run_rel="${ARTIFACT_ROOT#"$PROJECT_ROOT"/}"
  local manifest_rel="${run_rel}/artifact-lifecycle-manifest.json"

  mkdir -p "$MANAGED_ROOT/baselines"
  retire_previous_pointer_manifest "$baseline_path" "YES"
  retire_previous_pointer_manifest "$latest_path" "NO"

  jq -n \
    --arg schema_version "artifact-lifecycle/latest-pointer/v1" \
    --arg producer "scripts/harness-benchmark.sh" \
    --arg task_id "$TASK_ID" \
    --arg slice_id "$SLICE_ID" \
    --arg run_id "$RUN_ID" \
    --arg run_path "$run_rel" \
    --arg manifest_path "$manifest_rel" \
    --arg completed_at "$completed_at" \
    '$ARGS.named' > "$latest_path"

  jq -n \
    --arg schema_version "artifact-lifecycle/baseline-pointer/v1" \
    --arg producer "scripts/harness-benchmark.sh" \
    --arg baseline_id "$baseline_id" \
    --arg task_id "$TASK_ID" \
    --arg slice_id "$SLICE_ID" \
    --arg fixture_sha256 "$fixture_hash" \
    --arg run_id "$RUN_ID" \
    --arg run_path "$run_rel" \
    --arg manifest_path "$manifest_rel" \
    --arg pinned_at "$completed_at" \
    '$ARGS.named' > "$baseline_path"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --task-id)
        TASK_ID="${2:-}"
        shift 2
        ;;
      --slice-id)
        SLICE_ID="${2:-}"
        shift 2
        ;;
      --fixture)
        FIXTURE_PATH="${2:-}"
        shift 2
        ;;
      --baseline-command)
        BASELINE_COMMAND="${2:-}"
        shift 2
        ;;
      --candidate-command)
        CANDIDATE_COMMAND="${2:-}"
        shift 2
        ;;
      --runs)
        RUN_COUNT="${2:-}"
        shift 2
        ;;
      --help|-h)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

main() {
  local fixture_hash=""
  local fixture_descriptor=""
  local summary_path=""
  local subject=""
  local command_string=""
  local run_number=0
  local metrics=""
  local wall_ms=""
  local peak_rss_kb=""

  require_command /usr/bin/time
  require_command awk
  require_command find
  require_command sort
  require_command jq

  parse_args "$@"

  validate_id "$TASK_ID" "--task-id"
  validate_id "$SLICE_ID" "--slice-id"
  [[ -n "$FIXTURE_PATH" ]] || fail "missing required argument: --fixture"
  [[ -n "$BASELINE_COMMAND" ]] || fail "missing required argument: --baseline-command"
  [[ -n "$CANDIDATE_COMMAND" ]] || fail "missing required argument: --candidate-command"
  [[ "$RUN_COUNT" =~ ^[1-9][0-9]*$ ]] || fail "invalid --runs: $RUN_COUNT"

  FIXTURE_PATH="$(resolve_existing_path "$FIXTURE_PATH")"
  TIME_FORMAT="$(detect_time_format)"
  SHA256_TOOL="$(detect_sha256_tool)"
  RUN_ID="$(new_run_id)"
  MANAGED_ROOT="$PROJECT_ROOT/.claude/tmp/benchmarks/$TASK_ID/$SLICE_ID"
  ARTIFACT_ROOT="$MANAGED_ROOT/runs/$RUN_ID"
  compute_model_policy_linkage

  if [[ -e "$ARTIFACT_ROOT" && ! -d "$ARTIFACT_ROOT" ]]; then
    fail "artifact root exists but is not a directory: $ARTIFACT_ROOT"
  fi

  if [[ -e "$ARTIFACT_ROOT" ]] && find "$ARTIFACT_ROOT" -mindepth 1 -print -quit | grep -q .; then
    fail "artifact root already exists and is non-empty: $ARTIFACT_ROOT"
  fi

  mkdir -p "$ARTIFACT_ROOT"
  write_model_policy_linkage "$(utc_now)"

  fixture_hash="$(compute_fixture_hash "$FIXTURE_PATH")"
  write_lifecycle_manifest "$fixture_hash" "$(utc_now)"
  if [[ -f "$FIXTURE_PATH" ]]; then
    fixture_descriptor="$FIXTURE_PATH"
  else
    fixture_descriptor="dir:$FIXTURE_PATH"
  fi

  printf '%s  %s\n' "$fixture_hash" "$fixture_descriptor" > "$ARTIFACT_ROOT/fixture.sha256"
  printf '%s\n' "$BASELINE_COMMAND" > "$ARTIFACT_ROOT/baseline_command.txt"
  printf '%s\n' "$CANDIDATE_COMMAND" > "$ARTIFACT_ROOT/candidate_command.txt"
  write_env_file "$fixture_hash" "$fixture_descriptor"

  summary_path="$ARTIFACT_ROOT/summary.tsv"
  printf 'subject\trun_index\twall_ms\tpeak_rss_kb\tfixture_sha256\tcommand_file\n' > "$summary_path"

  for subject in baseline candidate; do
    if [[ "$subject" == "baseline" ]]; then
      command_string="$BASELINE_COMMAND"
    else
      command_string="$CANDIDATE_COMMAND"
    fi

    run_number=1
    while [[ "$run_number" -le "$RUN_COUNT" ]]; do
      metrics="$(measure_subject_run "$subject" "$command_string" "$run_number")"
      wall_ms="${metrics%%$'\t'*}"
      peak_rss_kb="${metrics##*$'\t'}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$subject" \
        "$(run_tag "$run_number")" \
        "$wall_ms" \
        "$peak_rss_kb" \
        "$fixture_hash" \
        "${subject}_command.txt" \
        >> "$summary_path"
      run_number=$((run_number + 1))
    done
  done

  jq --arg completed_at "$(utc_now)" '.completed_at = $completed_at' \
    "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json" \
    > "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json.tmp"
  mv "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json.tmp" "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json"
  write_latest_and_baseline_pointers "$fixture_hash" "$(utc_now)"

  printf 'ARTIFACT_ROOT=%s\n' "$ARTIFACT_ROOT"
}

main "$@"
