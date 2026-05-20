#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TASK_ID=""
SLICE_ID=""
PROFILE="focused"
COUNT_CARGO="NO"
RUN_ID=""
OUT_ROOT=""
ARTIFACT_ROOT=""
TIME_FORMAT=""
REAL_CARGO=""
STEPS=()

usage() {
  cat <<'EOF'
Usage:
  bash scripts/harness-runtime-baseline.sh \
    --task-id <task-id> \
    --slice-id <slice-id> \
    [--profile quick|focused] \
    [--count-cargo] \
    [--step '<slug>|<command>']

Measures orchestration / semantic / index runtime cost with low-overhead process
sampling. Artifacts are written under:
  .claude/tmp/runtime-baselines/<task-id>/<slice-id>/runs/<run-id>/

Recorded per step:
  - wall_ms
  - peak_rss_kb
  - cpu_ms
  - max_process_count
  - cargo_invocations

By default the script does not alter PATH, because semantic/runtime trust guards
may intentionally reject PATH-local cargo shims. Use --count-cargo only for
commands where PATH instrumentation is allowed.
  - status
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

validate_id() {
  local value="$1"
  local label="$2"

  [[ -n "$value" ]] || fail "missing required argument: $label"
  [[ "$value" != "." && "$value" != ".." ]] || fail "invalid $label: $value"
  [[ "$value" != *"/"* && "$value" != *"\\"* ]] || fail "invalid $label: $value"
  [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid $label: $value"
}

utc_now() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
  else
    printf '%s000\n' "$(date -u +%s)"
  fi
}

new_run_id() {
  if [[ -n "${HARNESS_RUNTIME_BASELINE_RUN_ID:-}" ]]; then
    validate_id "$HARNESS_RUNTIME_BASELINE_RUN_ID" "HARNESS_RUNTIME_BASELINE_RUN_ID"
    printf '%s\n' "$HARNESS_RUNTIME_BASELINE_RUN_ID"
    return 0
  fi
  printf '%s_%s\n' "$(date -u +%Y%m%dT%H%M%SZ)" "$$"
}

detect_time_format() {
  local probe_file=""

  probe_file="$(mktemp "${TMPDIR:-/tmp}/harness-runtime-time-probe.XXXXXX")"
  if /usr/bin/time -f '%e\t%M\t%U\t%S' bash -lc 'true' >/dev/null 2> "$probe_file"; then
    if awk -F '\t' 'NR == 1 && NF == 4 { ok=1 } END { exit ok ? 0 : 1 }' "$probe_file"; then
      /bin/rm -f "$probe_file"
      printf 'gnu\n'
      return 0
    fi
  elif awk -F '\t' 'NR == 1 && NF == 4 { ok=1 } END { exit ok ? 0 : 1 }' "$probe_file"; then
    /bin/rm -f "$probe_file"
    printf 'gnu\n'
    return 0
  fi

  : > "$probe_file"
  if /usr/bin/time -l bash -lc 'true' >/dev/null 2> "$probe_file"; then
    if parseable_bsd_time_file "$probe_file"; then
      /bin/rm -f "$probe_file"
      printf 'bsd\n'
      return 0
    fi
  elif parseable_bsd_time_file "$probe_file"; then
    /bin/rm -f "$probe_file"
    printf 'bsd\n'
    return 0
  fi

  : > "$probe_file"
  if /usr/bin/time -p bash -lc 'true' >/dev/null 2> "$probe_file"; then
    if parseable_posix_time_file "$probe_file"; then
      /bin/rm -f "$probe_file"
      printf 'posix\n'
      return 0
    fi
  elif parseable_posix_time_file "$probe_file"; then
    /bin/rm -f "$probe_file"
    printf 'posix\n'
    return 0
  fi

  /bin/rm -f "$probe_file"
  fail "unsupported /usr/bin/time implementation"
}

parseable_bsd_time_file() {
  local time_output_file="$1"

  awk '
    / real .* user .* sys$/ { timing=1 }
    /maximum resident set size$/ { rss=1 }
    /peak memory footprint$/ { rss=1 }
    END { exit (timing && rss) ? 0 : 1 }
  ' "$time_output_file"
}

parseable_posix_time_file() {
  local time_output_file="$1"

  awk '
    /^real[[:space:]]+[0-9.]+$/ { real=1 }
    /^user[[:space:]]+[0-9.]+$/ { user=1 }
    /^sys[[:space:]]+[0-9.]+$/ { sys=1 }
    END { exit (real && user && sys) ? 0 : 1 }
  ' "$time_output_file"
}

parse_time_file() {
  local time_output_file="$1"
  local sampled_peak_rss_kb="${2:-0}"
  local wall_ms=""
  local peak_rss_kb=""
  local user_secs=""
  local sys_secs=""
  local rss_value=""

  if [[ "$TIME_FORMAT" == "gnu" ]]; then
    wall_ms="$(awk -F '\t' 'NR == 1 { printf "%.0f\n", ($1 * 1000) }' "$time_output_file")"
    peak_rss_kb="$(awk -F '\t' 'NR == 1 { print $2 }' "$time_output_file")"
    user_secs="$(awk -F '\t' 'NR == 1 { print $3 }' "$time_output_file")"
    sys_secs="$(awk -F '\t' 'NR == 1 { print $4 }' "$time_output_file")"
  elif [[ "$TIME_FORMAT" == "bsd" ]]; then
    wall_ms="$(awk '/ real .* user .* sys$/ { printf "%.0f\n", ($1 * 1000); exit }' "$time_output_file")"
    user_secs="$(awk '/ real .* user .* sys$/ { print $3; exit }' "$time_output_file")"
    sys_secs="$(awk '/ real .* user .* sys$/ { print $5; exit }' "$time_output_file")"
    rss_value="$(awk '/maximum resident set size$/ { print $1; exit }' "$time_output_file")"
    if [[ -z "$rss_value" ]]; then
      rss_value="$(awk '/peak memory footprint$/ { print $1; exit }' "$time_output_file")"
    fi
    if [[ -n "$rss_value" ]]; then
      peak_rss_kb="$(awk -v rss_bytes="$rss_value" 'BEGIN { printf "%d\n", int((rss_bytes + 1023) / 1024) }')"
    else
      peak_rss_kb="$sampled_peak_rss_kb"
    fi
  else
    wall_ms="$(awk '/^real[[:space:]]+[0-9.]+$/ { printf "%.0f\n", ($2 * 1000); exit }' "$time_output_file")"
    user_secs="$(awk '/^user[[:space:]]+[0-9.]+$/ { print $2; exit }' "$time_output_file")"
    sys_secs="$(awk '/^sys[[:space:]]+[0-9.]+$/ { print $2; exit }' "$time_output_file")"
    peak_rss_kb="$sampled_peak_rss_kb"
  fi

  [[ "$wall_ms" =~ ^[0-9]+$ ]] || fail "failed to parse wall clock milliseconds"
  [[ "$peak_rss_kb" =~ ^[0-9]+$ ]] || fail "failed to parse peak RSS kilobytes"
  [[ -n "$user_secs" && -n "$sys_secs" ]] || fail "failed to parse CPU seconds"
  awk -v user_secs="$user_secs" -v sys_secs="$sys_secs" -v wall_ms="$wall_ms" -v peak_rss_kb="$peak_rss_kb" \
    'BEGIN { printf "%s\t%s\t%.0f\n", wall_ms, peak_rss_kb, ((user_secs + sys_secs) * 1000) }'
}

default_steps() {
  case "$PROFILE" in
    quick)
      STEPS=(
        "orchestration_dry_run|bash test/integration/harness_release_gate.sh --tier local --dry-run"
        "semantic_index_benchmark|bash test/integration/semantic_index_benchmark_smoke_test.sh"
      )
      ;;
    focused)
      STEPS=(
        "orchestration_packet_validator|bash test/integration/orchestration_packet_validator_test.sh"
        "auto_orchestrate_preflight|bash test/integration/auto_orchestrate_packet_preflight_test.sh"
        "semantic_cli_contract|bash test/integration/semantic_cli_contract_parity_test.sh"
        "semantic_coordination|bash test/integration/semantic_coordination_test.sh"
        "semantic_index_benchmark|bash test/integration/semantic_index_benchmark_smoke_test.sh"
      )
      ;;
    *)
      fail "invalid --profile: $PROFILE"
      ;;
  esac
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
      --profile)
        PROFILE="${2:-}"
        shift 2
        ;;
      --step)
        STEPS+=("${2:-}")
        shift 2
        ;;
      --count-cargo)
        COUNT_CARGO="YES"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        fail "unknown argument: $1"
        ;;
    esac
  done
}

write_cargo_shim() {
  local shim_dir="$1"
  local cargo_log="$2"
  local cargo_shim="$shim_dir/cargo"

  cat > "$cargo_shim" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$HARNESS_RUNTIME_BASELINE_CARGO_LOG"
exec "$HARNESS_RUNTIME_BASELINE_REAL_CARGO" "$@"
EOF
  chmod +x "$cargo_shim"
}

pgid_process_count() {
  local pgid="$1"
  ps -ax -o pgid= 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid { count++ } END { print count + 0 }'
}

pgid_rss_kb() {
  local pgid="$1"
  ps -ax -o pgid=,rss= 2>/dev/null | awk -v pgid="$pgid" '$1 == pgid { sum += $2 } END { print sum + 0 }'
}

measure_step() {
  local slug="$1"
  local command_string="$2"
  local step_dir="$ARTIFACT_ROOT/$slug"
  local time_output_file=""
  local status_file=""
  local time_status_file=""
  local cargo_log=""
  local shim_dir=""
  local measured_path="$PATH"
  local pid=""
  local pgid=""
  local status=0
  local started_ms=""
  local completed_ms=""
  local metrics=""
  local wall_ms=""
  local peak_rss_kb=""
  local cpu_ms=""
  local max_process_count=0
  local current_process_count=0
  local current_rss_kb=0
  local sampled_peak_rss_kb=0
  local cargo_invocations=0
  local time_status=0

  validate_id "$slug" "step slug"
  mkdir -p "$step_dir"
  printf '%s\n' "$command_string" > "$step_dir/command.txt"
  : > "$step_dir/stdout.txt"
  : > "$step_dir/stderr.txt"
  time_output_file="$step_dir/time.txt"
  status_file="$step_dir/command_status.txt"
  time_status_file="$step_dir/time_status.txt"
  cargo_log="$step_dir/cargo-invocations.log"
  shim_dir="$step_dir/bin"
  mkdir -p "$shim_dir"
  : > "$cargo_log"
  if [[ "$COUNT_CARGO" == "YES" ]]; then
    write_cargo_shim "$shim_dir" "$cargo_log"
    measured_path="$shim_dir:$PATH"
  fi

  started_ms="$(now_ms)"
  printf '%s\n' "$(utc_now)" > "$step_dir/started_at_utc.txt"
  printf '%s\n' "$started_ms" > "$step_dir/started_ms.txt"

  if [[ "$TIME_FORMAT" == "gnu" ]]; then
    perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
      -- /usr/bin/time -o "$time_output_file" -f '%e\t%M\t%U\t%S' \
      env \
        PATH="$measured_path" \
        HARNESS_RUNTIME_BASELINE_REAL_CARGO="$REAL_CARGO" \
        HARNESS_RUNTIME_BASELINE_CARGO_LOG="$cargo_log" \
	        HARNESS_RUNTIME_BASELINE_COMMAND="$command_string" \
	        HARNESS_RUNTIME_BASELINE_STDOUT_FILE="$step_dir/stdout.txt" \
	        HARNESS_RUNTIME_BASELINE_STDERR_FILE="$step_dir/stderr.txt" \
	        HARNESS_RUNTIME_BASELINE_STATUS_FILE="$status_file" \
	        bash -lc 'exec >"$HARNESS_RUNTIME_BASELINE_STDOUT_FILE" 2>"$HARNESS_RUNTIME_BASELINE_STDERR_FILE"; eval "$HARNESS_RUNTIME_BASELINE_COMMAND"; rc=$?; printf "%s\n" "$rc" > "$HARNESS_RUNTIME_BASELINE_STATUS_FILE"; exit "$rc"' \
	      >/dev/null 2>&1 &
  elif [[ "$TIME_FORMAT" == "bsd" ]]; then
    perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
      -- /usr/bin/time -l \
      env \
        PATH="$measured_path" \
        HARNESS_RUNTIME_BASELINE_REAL_CARGO="$REAL_CARGO" \
        HARNESS_RUNTIME_BASELINE_CARGO_LOG="$cargo_log" \
	        HARNESS_RUNTIME_BASELINE_COMMAND="$command_string" \
	        HARNESS_RUNTIME_BASELINE_STDOUT_FILE="$step_dir/stdout.txt" \
	        HARNESS_RUNTIME_BASELINE_STDERR_FILE="$step_dir/stderr.txt" \
	        HARNESS_RUNTIME_BASELINE_STATUS_FILE="$status_file" \
	        bash -lc 'exec >"$HARNESS_RUNTIME_BASELINE_STDOUT_FILE" 2>"$HARNESS_RUNTIME_BASELINE_STDERR_FILE"; eval "$HARNESS_RUNTIME_BASELINE_COMMAND"; rc=$?; printf "%s\n" "$rc" > "$HARNESS_RUNTIME_BASELINE_STATUS_FILE"; exit "$rc"' \
	      2> "$time_output_file" &
  else
    perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
      -- /usr/bin/time -p \
      env \
        PATH="$measured_path" \
        HARNESS_RUNTIME_BASELINE_REAL_CARGO="$REAL_CARGO" \
        HARNESS_RUNTIME_BASELINE_CARGO_LOG="$cargo_log" \
        HARNESS_RUNTIME_BASELINE_COMMAND="$command_string" \
        HARNESS_RUNTIME_BASELINE_STDOUT_FILE="$step_dir/stdout.txt" \
        HARNESS_RUNTIME_BASELINE_STDERR_FILE="$step_dir/stderr.txt" \
        HARNESS_RUNTIME_BASELINE_STATUS_FILE="$status_file" \
        bash -lc 'exec >"$HARNESS_RUNTIME_BASELINE_STDOUT_FILE" 2>"$HARNESS_RUNTIME_BASELINE_STDERR_FILE"; eval "$HARNESS_RUNTIME_BASELINE_COMMAND"; rc=$?; printf "%s\n" "$rc" > "$HARNESS_RUNTIME_BASELINE_STATUS_FILE"; exit "$rc"' \
      2> "$time_output_file" &
  fi
  pid=$!
  pgid=$pid
  printf '%s\n' "$pid" > "$step_dir/pid.txt"
  printf '%s\n' "$pgid" > "$step_dir/pgid.txt"

  while kill -0 "$pid" 2>/dev/null; do
    current_process_count="$(pgid_process_count "$pgid")"
    if [[ "$current_process_count" -gt "$max_process_count" ]]; then
      max_process_count="$current_process_count"
    fi
    current_rss_kb="$(pgid_rss_kb "$pgid")"
    if [[ "$current_rss_kb" -gt "$sampled_peak_rss_kb" ]]; then
      sampled_peak_rss_kb="$current_rss_kb"
    fi
    sleep 0.1
  done

  if wait "$pid"; then
    time_status=0
  else
    time_status=$?
  fi
  completed_ms="$(now_ms)"
  [[ "$max_process_count" -gt 0 ]] || max_process_count=1
  printf '%s\n' "$time_status" > "$time_status_file"

  if [[ -s "$status_file" ]]; then
    status="$(sed -n '1p' "$status_file")"
  else
    status="$time_status"
  fi
  [[ "$status" =~ ^[0-9]+$ ]] || status=1

  metrics="$(parse_time_file "$time_output_file" "$sampled_peak_rss_kb")"
  wall_ms="$(printf '%s\n' "$metrics" | awk -F '\t' '{ print $1 }')"
  peak_rss_kb="$(printf '%s\n' "$metrics" | awk -F '\t' '{ print $2 }')"
  cpu_ms="$(printf '%s\n' "$metrics" | awk -F '\t' '{ print $3 }')"
  cargo_invocations="$(wc -l < "$cargo_log" | tr -d '[:space:]')"

  printf '%s\n' "$(utc_now)" > "$step_dir/completed_at_utc.txt"
  printf '%s\n' "$completed_ms" > "$step_dir/completed_ms.txt"
  printf '%s\n' "$status" > "$step_dir/status.txt"
  printf '%s\n' "$wall_ms" > "$step_dir/wall_ms.txt"
  printf '%s\n' "$peak_rss_kb" > "$step_dir/peak_rss_kb.txt"
  printf '%s\n' "$cpu_ms" > "$step_dir/cpu_ms.txt"
  printf '%s\n' "$max_process_count" > "$step_dir/max_process_count.txt"
  printf '%s\n' "$cargo_invocations" > "$step_dir/cargo_invocations.txt"

  printf 'YES\n' > "$step_dir/residual_cleanup_attempted.txt"
  current_process_count="$(pgid_process_count "$pgid")"
  printf '%s\n' "$current_process_count" > "$step_dir/residual_process_count.txt"
  if [[ "$current_process_count" -gt 0 ]]; then
    ps -ax -o pid,ppid,pgid,etime,stat,command > "$step_dir/process-snapshot-before-residual-kill.log" 2>/dev/null || true
  fi
  if kill -TERM -- -"$pgid" 2>/dev/null; then
    printf '0\n' > "$step_dir/residual_term_signal_status.txt"
  else
    printf '%s\n' "$?" > "$step_dir/residual_term_signal_status.txt"
  fi
  sleep 1
  if kill -KILL -- -"$pgid" 2>/dev/null; then
    printf '0\n' > "$step_dir/residual_kill_signal_status.txt"
  else
    printf '%s\n' "$?" > "$step_dir/residual_kill_signal_status.txt"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$slug" "$status" "$wall_ms" "$peak_rss_kb" "$cpu_ms" "$max_process_count" "$cargo_invocations" \
    >> "$ARTIFACT_ROOT/summary.tsv"

  return "$status"
}

write_baseline_json() {
  tail -n +2 "$ARTIFACT_ROOT/summary.tsv" | jq -Rn \
    --arg schema_version "harness-runtime-baseline/v1" \
    --arg producer "scripts/harness-runtime-baseline.sh" \
    --arg task_id "$TASK_ID" \
    --arg slice_id "$SLICE_ID" \
    --arg run_id "$RUN_ID" \
    --arg profile "$PROFILE" \
    --arg created_at "$(utc_now)" \
    '
      [inputs | split("\t") | select(length == 7) | {
        slug: .[0],
        status: (.[1] | tonumber),
        wall_ms: (.[2] | tonumber),
        peak_rss_kb: (.[3] | tonumber),
        cpu_ms: (.[4] | tonumber),
        max_process_count: (.[5] | tonumber),
        cargo_invocations: (.[6] | tonumber)
      }] as $steps
      | {
        schema_version: $schema_version,
        producer: $producer,
        task_id: $task_id,
        slice_id: $slice_id,
        run_id: $run_id,
        profile: $profile,
        created_at: $created_at,
        status: (if any($steps[]; .status != 0) then "FAIL" else "PASS" end),
        step_count: ($steps | length),
        total_wall_ms: ($steps | map(.wall_ms) | add // 0),
        total_cpu_ms: ($steps | map(.cpu_ms) | add // 0),
        peak_rss_kb_max: ($steps | map(.peak_rss_kb) | max // 0),
        max_process_count_max: ($steps | map(.max_process_count) | max // 0),
        cargo_invocations_total: ($steps | map(.cargo_invocations) | add // 0),
        slowest_by_wall_ms: ($steps | sort_by(.wall_ms) | reverse | .[0:5]),
        highest_by_peak_rss_kb: ($steps | sort_by(.peak_rss_kb) | reverse | .[0:5]),
        highest_by_cpu_ms: ($steps | sort_by(.cpu_ms) | reverse | .[0:5]),
        steps: $steps
      }
    ' > "$ARTIFACT_ROOT/baseline.json"
}

write_manifest() {
  jq -n \
    --arg schema_version "artifact-lifecycle/v1" \
    --arg owner "script" \
    --arg producer "scripts/harness-runtime-baseline.sh" \
    --arg purpose "runtime measurement baseline evidence" \
    --arg authority "docs/manual/harness-user-guide.md" \
    --arg task_id "$TASK_ID" \
    --arg slice_id "$SLICE_ID" \
    --arg run_id "$RUN_ID" \
    --arg state "active" \
    --arg disposition "active-evidence" \
    --arg latest_pointer "runtime-baseline-latest" \
    --arg safe_delete_class "never" \
    --arg manifest_path "${ARTIFACT_ROOT#"$PROJECT_ROOT"/}/artifact-lifecycle-manifest.json" \
    --arg created_at "$(utc_now)" \
    '$ARGS.named' > "$ARTIFACT_ROOT/artifact-lifecycle-manifest.json"
}

main() {
  local step=""
  local slug=""
  local command_string=""
  local fail_count=0

  require_command /usr/bin/time
  require_command awk
  require_command jq
  require_command perl
  require_command ps

  parse_args "$@"
  validate_id "$TASK_ID" "--task-id"
  validate_id "$SLICE_ID" "--slice-id"
  [[ "$PROFILE" == "quick" || "$PROFILE" == "focused" ]] || fail "invalid --profile: $PROFILE"
  if [[ "${#STEPS[@]}" -eq 0 ]]; then
    default_steps
  fi

  REAL_CARGO="${HARNESS_RUNTIME_BASELINE_REAL_CARGO:-$(command -v cargo || true)}"
  [[ -n "$REAL_CARGO" && -x "$REAL_CARGO" && ! -d "$REAL_CARGO" ]] || fail "missing executable cargo for cargo invocation accounting"
  TIME_FORMAT="$(detect_time_format)"
  RUN_ID="$(new_run_id)"
  OUT_ROOT="$PROJECT_ROOT/.claude/tmp/runtime-baselines/$TASK_ID/$SLICE_ID"
  ARTIFACT_ROOT="$OUT_ROOT/runs/$RUN_ID"

  if [[ -e "$ARTIFACT_ROOT" && ! -d "$ARTIFACT_ROOT" ]]; then
    fail "artifact root exists but is not a directory: $ARTIFACT_ROOT"
  fi
  if [[ -e "$ARTIFACT_ROOT" ]] && find "$ARTIFACT_ROOT" -mindepth 1 -print -quit | grep -q .; then
    fail "artifact root already exists and is non-empty: $ARTIFACT_ROOT"
  fi

  mkdir -p "$ARTIFACT_ROOT"
  printf 'slug\tstatus\twall_ms\tpeak_rss_kb\tcpu_ms\tmax_process_count\tcargo_invocations\n' > "$ARTIFACT_ROOT/summary.tsv"
  {
    printf 'project_root=%s\n' "$PROJECT_ROOT"
    printf 'task_id=%s\n' "$TASK_ID"
    printf 'slice_id=%s\n' "$SLICE_ID"
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'profile=%s\n' "$PROFILE"
    printf 'count_cargo=%s\n' "$COUNT_CARGO"
    printf 'time_format=%s\n' "$TIME_FORMAT"
    printf 'real_cargo=%s\n' "$REAL_CARGO"
    printf 'created_at=%s\n' "$(utc_now)"
  } > "$ARTIFACT_ROOT/env.txt"

  for step in "${STEPS[@]}"; do
    slug="${step%%|*}"
    command_string="${step#*|}"
    [[ -n "$slug" && "$command_string" != "$step" && -n "$command_string" ]] \
      || fail "invalid --step value, expected <slug>|<command>: $step"
    if ! measure_step "$slug" "$command_string"; then
      fail_count=$((fail_count + 1))
    fi
  done

  write_baseline_json
  write_manifest
  jq -n \
    --arg schema_version "artifact-lifecycle/latest-pointer/v1" \
    --arg producer "scripts/harness-runtime-baseline.sh" \
    --arg run_id "$RUN_ID" \
    --arg run_path "${ARTIFACT_ROOT#"$PROJECT_ROOT"/}" \
    --arg manifest_path "${ARTIFACT_ROOT#"$PROJECT_ROOT"/}/artifact-lifecycle-manifest.json" \
    --arg completed_at "$(utc_now)" \
    '$ARGS.named' > "$OUT_ROOT/latest.json"

  printf 'ARTIFACT_ROOT=%s\n' "$ARTIFACT_ROOT"
  printf 'BASELINE_JSON=%s\n' "$ARTIFACT_ROOT/baseline.json"

  [[ "$fail_count" -eq 0 ]] || exit 1
}

main "$@"
