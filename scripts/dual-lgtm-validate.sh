#!/usr/bin/env bash
set -euo pipefail

DEFAULT_REVIEWERS="opus,codex"
DEFAULT_METRICS_PATH=".agent/metrics/dual_lgtm_gap.jsonl"
LGTM_LITERAL="**Verdict**: ✅ LGTM (unconditional)"
REVIEWERS=""
VERDICT_ROWS=""

usage() {
  cat <<'EOF'
Usage:
  scripts/dual-lgtm-validate.sh --plan-id <plan-id> --round <round-int> \
    [--expected-reviewers opus,codex] [--evidence-dir <dir>] \
    [--strict | --soft] [--metrics-path <jsonl-path>]
  scripts/dual-lgtm-validate.sh --self-test
  scripts/dual-lgtm-validate.sh --help | -h

IDs are restricted to ASCII [A-Za-z0-9._:-]; reviewer ids must not contain ':'.
EOF
}

die_usage() { printf 'ERROR: %s\n' "$*" >&2; usage >&2; exit 3; }
fatal() { printf 'ERROR: %s\n' "$*" >&2; exit 2; }
json_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

sha256_file() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    fatal "neither shasum nor sha256sum is available"
  fi
}

valid_id() { case "$1" in ""|*[!A-Za-z0-9._:-]*) return 1 ;; *) return 0 ;; esac; }
valid_reviewer() { valid_id "$1" && case "$1" in *:*) return 1 ;; *) return 0 ;; esac; }

trim_space() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

parse_reviewers() {
  local raw="$1" part reviewer old_ifs
  REVIEWERS=""
  old_ifs="$IFS"; IFS=','
  for part in $raw; do
    reviewer="$(trim_space "$part")"
    [[ -n "$reviewer" ]] || die_usage "empty reviewer id in --expected-reviewers"
    valid_reviewer "$reviewer" || die_usage "invalid reviewer id: $reviewer"
    REVIEWERS="${REVIEWERS}${reviewer}
"
  done
  IFS="$old_ifs"
  [[ -n "$REVIEWERS" ]] || die_usage "--expected-reviewers produced no reviewers"
}

resolve_evidence_dir() {
  local plan_id="$1" explicit="$2" base candidate count found
  if [[ -n "$explicit" ]]; then
    [[ -d "$explicit" ]] || die_usage "--evidence-dir is not a directory: $explicit"
    printf '%s' "$explicit"; return 0
  fi
  base=".agent/active/${plan_id}"
  [[ -d "$base" ]] && { printf '%s' "$base"; return 0; }
  count=0; found=""
  for candidate in ".agent/active/${plan_id}-"*; do
    [[ -d "$candidate" ]] || continue
    count=$((count + 1)); found="$candidate"
  done
  [[ "$count" -eq 1 ]] && { printf '%s' "$found"; return 0; }
  [[ "$count" -gt 1 ]] && die_usage "multiple evidence-dir candidates for plan-id: $plan_id"
  die_usage "no evidence-dir found for plan-id: $plan_id"
}

emit_gap_row() {
  local metrics_path="$1" plan_id="$2" round="$3" gap_kind="$4" seen="$5" required="$6"
  local ts first reviewer verdict
  mkdir -p "$(dirname -- "$metrics_path")"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  {
    printf '{"ts":"%s","event":"dual_lgtm_gap","task_id":"%s","gap_kind":"%s","reviewers_seen":%s,"reviewers_required":%s,"verdicts":[' \
      "$(json_escape "$ts")" "$(json_escape "${plan_id}:r${round}")" "$(json_escape "$gap_kind")" "$seen" "$required"
    first=1
    while IFS='|' read -r reviewer verdict; do
      [[ -n "$reviewer" ]] || continue
      [[ "$first" -eq 0 ]] && printf ','
      printf '{"reviewer_id":"%s","verdict":"%s"}' "$(json_escape "$reviewer")" "$(json_escape "$verdict")"
      first=0
    done <<EOF
$VERDICT_ROWS
EOF
    printf '],"agent_family":"unknown"}\n'
  } >> "$metrics_path"
}

self_test_fail() { printf 'self-test: FAIL %s\n' "$*" >&2; exit 1; }

self_test() {
  local tmp evidence metrics out rc
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/dual_lgtm_selftest.XXXXXX")"
  SELFTEST_TMP="$tmp"; trap 'PATH=/bin:/usr/bin; /bin/rm -rf "${SELFTEST_TMP:-}"' EXIT
  evidence="$tmp/evidence"; metrics="$tmp/dual_lgtm_gap.jsonl"; mkdir -p "$evidence"
  printf '%s\n' "$LGTM_LITERAL" > "$evidence/review-opus-r1.md"
  printf '%s\n' "$LGTM_LITERAL" > "$evidence/review-codex-r1.md"

  rc=0; out="$(bash "$0" --plan-id selftest --round 1 --evidence-dir "$evidence" --metrics-path "$metrics" --strict 2>&1)" || rc=$?
  [[ "$rc" -eq 0 ]] || self_test_fail "confirmed run exited $rc: $out"
  [[ ! -s "$metrics" ]] || self_test_fail "confirmed run emitted metrics"

  /bin/rm -f "$evidence/review-codex-r1.md"
  rc=0; out="$(bash "$0" --plan-id selftest --round 1 --evidence-dir "$evidence" --metrics-path "$metrics" --strict 2>&1)" || rc=$?
  [[ "$rc" -eq 1 ]] || self_test_fail "missing reviewer run exited $rc: $out"
  [[ -s "$metrics" ]] || self_test_fail "missing reviewer run emitted no metrics"
  grep -F '"gap_kind":"missing_reviewer"' "$metrics" >/dev/null || self_test_fail "missing reviewer row lacks gap_kind"
  printf 'self-test: PASS\n'
}

main() {
  local plan_id="" round="" reviewers_raw="$DEFAULT_REVIEWERS" evidence_arg=""
  local metrics_path="$DEFAULT_METRICS_PATH" mode="strict" evidence_dir reviewer file
  local present=0 required=0 absent=0 mismatched=0 result gap_kind="" exit_code=0 verdict

  case "${1:-}" in
    --self-test) [[ "$#" -eq 1 ]] || die_usage "--self-test does not accept other arguments"; self_test; return 0 ;;
    --help|-h) usage; return 0 ;;
  esac

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --plan-id) plan_id="${2:-}"; shift 2 ;;
      --round) round="${2:-}"; shift 2 ;;
      --expected-reviewers) reviewers_raw="${2:-}"; shift 2 ;;
      --evidence-dir) evidence_arg="${2:-}"; shift 2 ;;
      --metrics-path) metrics_path="${2:-}"; shift 2 ;;
      --strict) mode="strict"; shift ;;
      --soft) mode="soft"; shift ;;
      --help|-h) usage; return 0 ;;
      *) die_usage "unknown argument: $1" ;;
    esac
  done

  valid_id "$plan_id" || die_usage "--plan-id must match [A-Za-z0-9._:-]+"
  [[ "$round" =~ ^[0-9]+$ && "$round" -gt 0 ]] || die_usage "--round must be a positive integer"
  [[ -n "$metrics_path" ]] || die_usage "--metrics-path must not be empty"
  parse_reviewers "$reviewers_raw"
  evidence_dir="$(resolve_evidence_dir "$plan_id" "$evidence_arg")"

  while IFS= read -r reviewer; do
    [[ -n "$reviewer" ]] || continue
    required=$((required + 1)); file="${evidence_dir}/review-${reviewer}-r${round}.md"
    if [[ ! -f "$file" ]]; then
      verdict="absent"; absent=$((absent + 1))
    else
      present=$((present + 1)); sha256_file "$file" >/dev/null
      if grep -F "$LGTM_LITERAL" "$file" >/dev/null; then verdict="lgtm"; else verdict="rejected"; mismatched=$((mismatched + 1)); fi
    fi
    VERDICT_ROWS="${VERDICT_ROWS}${reviewer}|${verdict}
"
  done <<EOF
$REVIEWERS
EOF

  if [[ "$absent" -gt 0 ]]; then
    result="pending"; gap_kind="missing_reviewer"; exit_code=1
  elif [[ "$mismatched" -gt 0 ]]; then
    result="blocked"; gap_kind="verdict_mismatch"; exit_code=2
  else
    result="confirmed"
  fi
  printf 'dual-lgtm: result=%s reviewers_seen=%s reviewers_required=%s evidence_dir=%s\n' "$result" "$present" "$required" "$evidence_dir"
  [[ -n "$gap_kind" ]] && emit_gap_row "$metrics_path" "$plan_id" "$round" "$gap_kind" "$present" "$required"
  [[ "$mode" == "soft" ]] && return 0
  return "$exit_code"
}

main "$@"
