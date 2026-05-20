#!/usr/bin/env bash
set -euo pipefail

SESSION_ID=""
OUTPUT_PATH=""
INPUTS=()

usage() {
  cat <<'EOF'
Usage:
  scripts/collect-delegation-metrics.sh --session-id <id> --inputs <file1> <file2> ... --output <path>

Aggregates REV_HARNESS_DELEGATION_METRIC JSONL lines from wrapper stderr captures.
EOF
}

die() {
  printf 'collect-delegation-metrics: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --session-id)
      [[ $# -ge 2 ]] || die "--session-id requires a value"
      SESSION_ID="$2"
      shift 2
      ;;
    --session-id=*)
      SESSION_ID="${1#--session-id=}"
      shift
      ;;
    --inputs)
      shift
      while [[ $# -gt 0 && "$1" != --* ]]; do
        INPUTS+=("$1")
        shift
      done
      ;;
    --output)
      [[ $# -ge 2 ]] || die "--output requires a value"
      OUTPUT_PATH="$2"
      shift 2
      ;;
    --output=*)
      OUTPUT_PATH="${1#--output=}"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$SESSION_ID" ]] || die "--session-id is required"
[[ -n "$OUTPUT_PATH" ]] || die "--output is required"
[[ "${#INPUTS[@]}" -gt 0 ]] || die "--inputs requires at least one file"
command -v jq >/dev/null 2>&1 || die "jq is required"

for input in "${INPUTS[@]}"; do
  [[ -f "$input" && ! -d "$input" ]] || die "input not found: $input"
done

mkdir -p "$(dirname "$OUTPUT_PATH")"

{
  for input in "${INPUTS[@]}"; do
    sed -n 's/^REV_HARNESS_DELEGATION_METRIC //p' "$input"
  done
} | jq -s \
  --arg session_id "$SESSION_ID" \
  --arg collected_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '
  def numeric_values($field):
    [ .[] | .[$field] | select(type == "number") ];

  def median_for($field):
    (numeric_values($field) | sort) as $values
    | ($values | length) as $n
    | if $n == 0 then null
      elif ($n % 2) == 1 then $values[($n / 2 | floor)]
      else (($values[($n / 2) - 1] + $values[($n / 2)]) / 2)
      end;

  def p75_for($field):
    (numeric_values($field) | sort) as $values
    | ($values | length) as $n
    | if $n == 0 then null
      else $values[((($n * 0.75) | ceil) - 1)]
      end;

  def total_for($field):
    (numeric_values($field)) as $values
    | if ($values | length) == 0 then null else ($values | add) end;

  {
    schema_version: 1,
    session_id: $session_id,
    collected_at: $collected_at,
    sample_count: length,
    samples: .,
    aggregates: {
      median: {
        tokens_in: median_for("tokens_in"),
        tokens_out: median_for("tokens_out"),
        duration_ms: median_for("duration_ms")
      },
      p75: {
        tokens_in: p75_for("tokens_in"),
        tokens_out: p75_for("tokens_out"),
        duration_ms: p75_for("duration_ms")
      },
      total: {
        tokens_in: total_for("tokens_in"),
        tokens_out: total_for("tokens_out"),
        duration_ms: total_for("duration_ms")
      }
    }
  }
  ' > "$OUTPUT_PATH"
