#!/usr/bin/env bash
set -euo pipefail

BASELINE_PATH=""
POST_PATH=""
OUTPUT_PATH=""

usage() {
  cat <<'EOF'
Usage:
  scripts/compute-completion-delta.sh --baseline <baseline.json> --post <post.json> --output <delta.json>

Compares two delegation metrics collector outputs and emits delta JSON.
EOF
}

die() {
  printf 'compute-completion-delta: %s\n' "$*" >&2
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --baseline)
      [[ $# -ge 2 ]] || die "--baseline requires a value"
      BASELINE_PATH="$2"
      shift 2
      ;;
    --baseline=*)
      BASELINE_PATH="${1#--baseline=}"
      shift
      ;;
    --post)
      [[ $# -ge 2 ]] || die "--post requires a value"
      POST_PATH="$2"
      shift 2
      ;;
    --post=*)
      POST_PATH="${1#--post=}"
      shift
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

[[ -n "$BASELINE_PATH" ]] || die "--baseline is required"
[[ -n "$POST_PATH" ]] || die "--post is required"
[[ -n "$OUTPUT_PATH" ]] || die "--output is required"
[[ -f "$BASELINE_PATH" && ! -d "$BASELINE_PATH" ]] || die "baseline not found: $BASELINE_PATH"
[[ -f "$POST_PATH" && ! -d "$POST_PATH" ]] || die "post not found: $POST_PATH"
command -v jq >/dev/null 2>&1 || die "jq is required"

mkdir -p "$(dirname "$OUTPUT_PATH")"

jq -n \
  --slurpfile baseline "$BASELINE_PATH" \
  --slurpfile post "$POST_PATH" \
  '
  def ratio($post; $baseline):
    if ($baseline == null or $baseline == 0 or $post == null) then null else ($post / $baseline) end;

  def pct_change($post; $baseline):
    if ($baseline == null or $baseline == 0 or $post == null) then null else ((($post - $baseline) / $baseline) * 100) end;

  ($baseline[0]) as $b
  | ($post[0]) as $p
  | ($b.aggregates.median.tokens_in) as $b_tokens
  | ($p.aggregates.median.tokens_in) as $p_tokens
  | ($b.aggregates.median.duration_ms) as $b_duration
  | ($p.aggregates.median.duration_ms) as $p_duration
  | (pct_change($p_tokens; $b_tokens)) as $tokens_pct
  | (($tokens_pct != null) and ($tokens_pct <= -20)) as $threshold_met
  | {
      schema_version: 1,
      baseline_session: $b.session_id,
      post_session: $p.session_id,
      deltas: {
        tokens_in_median_ratio: ratio($p_tokens; $b_tokens),
        tokens_in_median_pct_change: $tokens_pct,
        tokens_in_median_threshold_met: $threshold_met,
        duration_ms_median_ratio: ratio($p_duration; $b_duration),
        drift_findings_total_post: ([ $p.samples[]? | (.drift_findings_total // 0) | select(type == "number") ] | add // 0)
      },
      verdict: (if $threshold_met then "MET" elif ($tokens_pct == null) then "PARTIAL" else "NOT_MET" end)
    }
  ' > "$OUTPUT_PATH"
