#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  bash scripts/cleanup-codex-mcp-zombies.sh report [--ps-file <path>] [--include-semantic]
  bash scripts/cleanup-codex-mcp-zombies.sh kill --pids <pid[,pid...]> [--include-semantic] [--min-age-seconds <n>]
  bash scripts/cleanup-codex-mcp-zombies.sh kill --dry-run [--include-semantic] [--min-age-seconds <n>]

Notes:
  - `semantic-mcp --project-id ...` is excluded by default.
  - chrome-devtools MCP helpers and chrome-devtools-mcp-zombie-report.md are
    classified as lifecycle zombie-report residuals.
  - `kill` and `kill --dry-run` consider only candidates older than `--min-age-seconds` (default: 600).
  - live `kill` requires explicit PID confirmation via `--pids`.
  - `kill --ps-file` is allowed only with `--dry-run`.
EOF
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

MODE=""
DRY_RUN=0
INCLUDE_SEMANTIC=0
PS_FILE=""
MIN_AGE_SECONDS=600
REQUESTED_PIDS=""

if [[ $# -eq 0 ]]; then
  usage >&2
  exit 64
fi

MODE="$1"
shift

case "$MODE" in
  report|kill) ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    die "unknown mode: $MODE"
    ;;
esac

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      ;;
    --include-semantic)
      INCLUDE_SEMANTIC=1
      ;;
    --ps-file)
      shift
      [[ $# -gt 0 ]] || die "--ps-file requires a path"
      PS_FILE="$1"
      ;;
    --min-age-seconds)
      shift
      [[ $# -gt 0 ]] || die "--min-age-seconds requires a value"
      [[ "$1" =~ ^[0-9]+$ ]] || die "--min-age-seconds must be a non-negative integer"
      MIN_AGE_SECONDS="$1"
      ;;
    --pids)
      shift
      [[ $# -gt 0 ]] || die "--pids requires a comma-separated list"
      REQUESTED_PIDS="$1"
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
  shift
done

if [[ "$MODE" == "report" && "$DRY_RUN" -eq 1 ]]; then
  die "--dry-run is only valid with kill"
fi

if [[ "$MODE" == "report" && -n "$REQUESTED_PIDS" ]]; then
  die "--pids is only valid with kill"
fi

if [[ -n "$PS_FILE" && ! -f "$PS_FILE" ]]; then
  die "ps fixture not found: $PS_FILE"
fi

if [[ "$MODE" == "kill" && -n "$PS_FILE" && "$DRY_RUN" -ne 1 ]]; then
  die "kill --ps-file requires --dry-run"
fi

if [[ "$MODE" == "kill" && "$DRY_RUN" -eq 1 && -n "$REQUESTED_PIDS" ]]; then
  die "--pids is not valid with kill --dry-run"
fi

if [[ "$MODE" == "kill" && "$DRY_RUN" -ne 1 && -z "$REQUESTED_PIDS" ]]; then
  die "live kill requires --pids"
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-mcp-zombies.XXXXXX")"
trap '/bin/rm -rf "$TMP_DIR"' EXIT

INPUT_SOURCE="live-ps"
if [[ -n "$PS_FILE" ]]; then
  INPUT_SOURCE="$PS_FILE"
fi

capture_ps() {
  local destination="$1"
  if [[ -n "$PS_FILE" ]]; then
    cp "$PS_FILE" "$destination"
  else
    ps -Ao pid=,ppid=,rss=,etime=,args= > "$destination"
  fi
}

classify_args() {
  local args="$1"
  if [[ "$args" == *"/.bin/playwright-mcp"* ]]; then
    printf 'playwright_mcp_node\n'
    return 0
  fi
  if [[ "$args" == *"npm exec @playwright/mcp@latest"* ]]; then
    printf 'npm_exec_playwright_mcp\n'
    return 0
  fi
  if [[ "$args" == *"SkyComputerUseClient mcp"* ]]; then
    printf 'skycomputeruse_mcp\n'
    return 0
  fi
  if [[ "$args" == *"chrome-devtools-mcp"* || "$args" == *"@chrome-devtools/mcp"* ]]; then
    printf 'chrome_devtools_mcp\n'
    return 0
  fi
  if [[ "$INCLUDE_SEMANTIC" -eq 1 && "$args" == *"semantic-mcp --project-id "* ]]; then
    printf 'semantic_mcp\n'
    return 0
  fi
  return 1
}

etime_to_seconds() {
  local etime="$1"
  local days="0"
  local rest="$etime"
  local first=""
  local second=""
  local third=""

  if [[ "$rest" == *-* ]]; then
    days="${rest%%-*}"
    rest="${rest#*-}"
  fi

  IFS=':' read -r first second third <<< "$rest"
  if [[ -z "${third:-}" ]]; then
    third="$second"
    second="$first"
    first="0"
  fi

  printf '%s\n' "$((10#$days * 86400 + 10#$first * 3600 + 10#$second * 60 + 10#$third))"
}

collect_matches() {
  local ps_snapshot="$1"
  local output_file="$2"
  local line=""
  local pid=""
  local ppid=""
  local rss=""
  local etime=""
  local etime_seconds=""
  local args=""
  local kind=""

  : > "$output_file"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -n "$line" ]] || continue
    if [[ ! "$line" =~ ^[[:space:]]*([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([0-9]+)[[:space:]]+([^[:space:]]+)[[:space:]]+(.*)$ ]]; then
      continue
    fi
    pid="${BASH_REMATCH[1]}"
    ppid="${BASH_REMATCH[2]}"
    rss="${BASH_REMATCH[3]}"
    etime="${BASH_REMATCH[4]}"
    args="${BASH_REMATCH[5]}"
    if kind="$(classify_args "$args")"; then
      etime_seconds="$(etime_to_seconds "$etime")"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$pid" "$ppid" "$rss" "$etime" "$etime_seconds" "$args" >> "$output_file"
    fi
  done < "$ps_snapshot"
}

build_summary_json() {
  local rows_file="$1"
  local phase="$2"
  local output_json="$3"

  jq -Rn \
    --arg source "$INPUT_SOURCE" \
    --arg phase "$phase" '
      def zeroes:
        {
          playwright_mcp_node: 0,
          npm_exec_playwright_mcp: 0,
          skycomputeruse_mcp: 0,
          chrome_devtools_mcp: 0,
          semantic_mcp: 0
        };
      reduce (inputs | select(length > 0) | split("\t")) as $row (
        {counts: zeroes, rss_kb: zeroes, matches: []};
        .counts[$row[0]] += 1
        | .rss_kb[$row[0]] += ($row[3] | tonumber)
        | .matches += [
            {
              kind: $row[0],
              pid: ($row[1] | tonumber),
              ppid: ($row[2] | tonumber),
              rss_kb: ($row[3] | tonumber),
              etime: $row[4],
              etime_seconds: ($row[5] | tonumber),
              args: $row[6]
            }
          ]
      )
      | {
          source: $source,
          phase: $phase,
          total_matches: (.matches | length),
          total_rss_kb: ((.matches | map(.rss_kb) | add) // 0),
          counts: .counts,
          rss_kb: .rss_kb,
          matches: .matches
        }
    ' < "$rows_file" > "$output_json"
}

write_candidate_pid_file() {
  local rows_file="$1"
  local pid_file="$2"
  awk -F '\t' -v min_age="$MIN_AGE_SECONDS" '$6 >= min_age { print $2 }' "$rows_file" | sort -u > "$pid_file"
}

write_requested_pid_file() {
  local pid_csv="$1"
  local pid_file="$2"
  local unsorted_file="$TMP_DIR/requested-pids.unsorted"
  local token=""

  : > "$unsorted_file"
  printf '%s' "$pid_csv" | tr ',' '\n' | while IFS= read -r token || [[ -n "$token" ]]; do
    token="$(printf '%s' "$token" | tr -d '[:space:]')"
    [[ -n "$token" ]] || continue
    [[ "$token" =~ ^[0-9]+$ ]] || die "--pids must be a comma-separated list of integers"
    printf '%s\n' "$token" >> "$unsorted_file"
  done

  if [[ ! -s "$unsorted_file" ]]; then
    die "--pids must contain at least one pid"
  fi

  sort -u "$unsorted_file" > "$pid_file"
}

validate_requested_pids() {
  local candidate_pid_file="$1"
  local requested_pid_file="$2"
  local invalid_pid_file="$3"
  local invalid_csv=""

  comm -23 "$requested_pid_file" "$candidate_pid_file" > "$invalid_pid_file"
  if [[ -s "$invalid_pid_file" ]]; then
    invalid_csv="$(paste -sd, "$invalid_pid_file")"
    die "requested pids are not stale kill candidates: $invalid_csv"
  fi
}

write_pid_json() {
  local pid_file="$1"
  local output_json="$2"
  if [[ -s "$pid_file" ]]; then
    jq -Rn '[inputs | select(length > 0) | tonumber]' < "$pid_file" > "$output_json"
  else
    printf '[]\n' > "$output_json"
  fi
}

terminate_matches() {
  local pid_file="$1"
  local terminated_file="$2"
  local failed_signal_file="$3"
  local survivor_file="$4"
  local pid=""

  : > "$terminated_file"
  : > "$failed_signal_file"
  : > "$survivor_file"
  while IFS= read -r pid || [[ -n "$pid" ]]; do
    [[ -n "$pid" ]] || continue
    if ! kill -TERM "$pid" 2>/dev/null; then
      printf '%s\n' "$pid" >> "$failed_signal_file"
      continue
    fi
    sleep 0.2
    if kill -0 "$pid" 2>/dev/null; then
      kill -KILL "$pid" 2>/dev/null || true
      sleep 0.1
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      printf '%s\n' "$pid" >> "$terminated_file"
    else
      printf '%s\n' "$pid" >> "$survivor_file"
    fi
  done < "$pid_file"
}

REPORT_SNAPSHOT="$TMP_DIR/ps-report.txt"
REPORT_ROWS="$TMP_DIR/report-matches.tsv"
REPORT_JSON="$TMP_DIR/report-summary.json"

if [[ "$MODE" == "report" ]]; then
  capture_ps "$REPORT_SNAPSHOT"
  collect_matches "$REPORT_SNAPSHOT" "$REPORT_ROWS"
  build_summary_json "$REPORT_ROWS" "report" "$REPORT_JSON"
  cat "$REPORT_JSON"
  exit 0
fi

BEFORE_SNAPSHOT="$TMP_DIR/ps-before.txt"
BEFORE_ROWS="$TMP_DIR/before-matches.tsv"
BEFORE_JSON="$TMP_DIR/before-summary.json"
PID_FILE="$TMP_DIR/requested-pids.txt"
PID_JSON="$TMP_DIR/requested-pids.json"
TERMINATED_FILE="$TMP_DIR/terminated-pids.txt"
TERMINATED_JSON="$TMP_DIR/terminated-pids.json"
FAILED_SIGNAL_FILE="$TMP_DIR/failed-signal-pids.txt"
FAILED_SIGNAL_JSON="$TMP_DIR/failed-signal-pids.json"
SURVIVOR_FILE="$TMP_DIR/survivor-pids.txt"
SURVIVOR_JSON="$TMP_DIR/survivor-pids.json"
REQUESTED_INPUT_PID_FILE="$TMP_DIR/requested-input-pids.txt"
INVALID_REQUESTED_PID_FILE="$TMP_DIR/invalid-requested-pids.txt"

capture_ps "$BEFORE_SNAPSHOT"
collect_matches "$BEFORE_SNAPSHOT" "$BEFORE_ROWS"
build_summary_json "$BEFORE_ROWS" "$([[ "$DRY_RUN" -eq 1 ]] && printf 'kill-dry-run' || printf 'kill-before')" "$BEFORE_JSON"
write_candidate_pid_file "$BEFORE_ROWS" "$PID_FILE"
write_pid_json "$PID_FILE" "$PID_JSON"

if [[ "$DRY_RUN" -eq 1 ]]; then
  printf '[]\n' > "$TERMINATED_JSON"
  jq -n \
    --argjson kill_threshold_seconds "$MIN_AGE_SECONDS" \
    --slurpfile summary "$BEFORE_JSON" \
    --slurpfile would_kill "$PID_JSON" \
    --slurpfile terminated "$TERMINATED_JSON" \
    '($summary[0] + {kill_threshold_seconds: $kill_threshold_seconds, would_kill_pids: $would_kill[0], terminated_pids: $terminated[0]})'
  exit 0
fi

write_requested_pid_file "$REQUESTED_PIDS" "$REQUESTED_INPUT_PID_FILE"
validate_requested_pids "$PID_FILE" "$REQUESTED_INPUT_PID_FILE" "$INVALID_REQUESTED_PID_FILE"
write_pid_json "$REQUESTED_INPUT_PID_FILE" "$PID_JSON"

terminate_matches "$REQUESTED_INPUT_PID_FILE" "$TERMINATED_FILE" "$FAILED_SIGNAL_FILE" "$SURVIVOR_FILE"
write_pid_json "$TERMINATED_FILE" "$TERMINATED_JSON"
write_pid_json "$FAILED_SIGNAL_FILE" "$FAILED_SIGNAL_JSON"
write_pid_json "$SURVIVOR_FILE" "$SURVIVOR_JSON"

AFTER_SNAPSHOT="$TMP_DIR/ps-after.txt"
AFTER_ROWS="$TMP_DIR/after-matches.tsv"
AFTER_JSON="$TMP_DIR/after-summary.json"
RESULT_JSON="$TMP_DIR/kill-result.json"

capture_ps "$AFTER_SNAPSHOT"
collect_matches "$AFTER_SNAPSHOT" "$AFTER_ROWS"
build_summary_json "$AFTER_ROWS" "kill-after" "$AFTER_JSON"

jq -n \
  --argjson kill_threshold_seconds "$MIN_AGE_SECONDS" \
  --slurpfile requested "$PID_JSON" \
  --slurpfile terminated "$TERMINATED_JSON" \
  --slurpfile failed_signal "$FAILED_SIGNAL_JSON" \
  --slurpfile survivors "$SURVIVOR_JSON" \
  --slurpfile before "$BEFORE_JSON" \
  --slurpfile after "$AFTER_JSON" \
  '($before[0] + {
    phase: "kill",
    kill_threshold_seconds: $kill_threshold_seconds,
    requested_kill_pids: $requested[0],
    terminated_pids: $terminated[0],
    failed_signal_pids: $failed_signal[0],
    survivor_pids: $survivors[0],
    before: $before[0],
    after: $after[0]
  })' > "$RESULT_JSON"

cat "$RESULT_JSON"

if [[ -s "$FAILED_SIGNAL_FILE" || -s "$SURVIVOR_FILE" ]]; then
  exit 1
fi
