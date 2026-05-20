#!/usr/bin/env bash
# shadow_verify.sh — 機械的検証ゲート (Phase 3 / Task 3.1)
# Layer 3: lint/typecheck/test を一時worktreeで実行し、通過後のみレビューに進む
set -euo pipefail

SHADOW_VERIFY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SHADOW_VERIFY_LIB_DIR/utils.sh"

SHADOW_VERIFY_CHANGED_LIMIT="${SHADOW_VERIFY_CHANGED_LIMIT:-50}"
SHADOW_VERIFY_MAX_DIAGNOSTIC_LINES="${SHADOW_VERIFY_MAX_DIAGNOSTIC_LINES:-120}"
SHADOW_VERIFY_MAX_ATTEMPTS="${SHADOW_VERIFY_MAX_ATTEMPTS:-3}"
SHADOW_VERIFY_SAST_ENABLED="${SHADOW_VERIFY_SAST_ENABLED:-true}"
SHADOW_VERIFY_SAST_MAX_TARGETS="${SHADOW_VERIFY_SAST_MAX_TARGETS:-120}"
SHADOW_VERIFY_SEMGREP_CONFIG="${SHADOW_VERIFY_SEMGREP_CONFIG:-auto}"
SHADOW_VERIFY_CODEQL_QUERY_SUITE="${SHADOW_VERIFY_CODEQL_QUERY_SUITE:-codeql-suites/security-extended.qls}"
SHADOW_VERIFY_HARNESS_PLANNER_MODE="${SHADOW_VERIFY_HARNESS_PLANNER_MODE:-review}"
SHADOW_VERIFY_FULL_TEST_FALLBACK="false"
SHADOW_VERIFY_FULL_TEST_REASON=""
SHADOW_VERIFY_LAST_CHANGED_FILES_RAW=""
SHADOW_VERIFY_CHANGED_FILES_RESULT=""
SHADOW_VERIFY_PLANNED_COMMAND_ARGS=()

_shadow_verify_cache_dir() {
  local workdir="$1"
  echo "$workdir/.claude/tmp/shadow_verify"
}

_shadow_verify_last_result_file() {
  local workdir="$1"
  echo "$(_shadow_verify_cache_dir "$workdir")/last_result.json"
}

_shadow_verify_last_summary_file() {
  local workdir="$1"
  echo "$(_shadow_verify_cache_dir "$workdir")/last_summary.txt"
}

_shadow_verify_normalize_gate_level() {
  local raw_level="${1:-}"
  case "${raw_level^^}" in
    "")
      echo ""
      ;;
    A|LEVELA|LEVEL_A)
      echo "A"
      ;;
    B|LEVELB|LEVEL_B)
      echo "B"
      ;;
    C|LEVELC|LEVEL_C)
      echo "C"
      ;;
    *)
      echo ""
      return 1
      ;;
  esac
}

_shadow_verify_is_impl_like_phase() {
  local phase="$1"
  [[ "$phase" == "impl" || "$phase" == "fix" || "$phase" == "test" ]]
}

_shadow_verify_has_package_script() {
  local package_json="$1"
  local script_name="$2"

  if [[ ! -f "$package_json" ]]; then
    return 1
  fi

  jq -e --arg name "$script_name" '.scripts[$name] != null' "$package_json" >/dev/null 2>&1
}

_shadow_verify_resolve_node_runner() {
  local workdir="$1"

  if [[ -f "$workdir/pnpm-lock.yaml" ]] && command -v pnpm >/dev/null 2>&1; then
    echo "pnpm"
    return
  fi

  if [[ -f "$workdir/package-lock.json" ]] && command -v npm >/dev/null 2>&1; then
    echo "npm"
    return
  fi

  if command -v pnpm >/dev/null 2>&1; then
    echo "pnpm"
    return
  fi

  if command -v npm >/dev/null 2>&1; then
    echo "npm"
    return
  fi

  echo ""
}

_shadow_verify_has_pytest_runner() {
  if command -v pytest >/dev/null 2>&1; then
    return 0
  fi

  if command -v python >/dev/null 2>&1 && python -m pytest --version >/dev/null 2>&1; then
    return 0
  fi

  if command -v python3 >/dev/null 2>&1 && python3 -m pytest --version >/dev/null 2>&1; then
    return 0
  fi

  return 1
}

_shadow_verify_truthy() {
  local value="${1:-}"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|y|on)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_shadow_verify_find_codeql_database() {
  local workdir="$1"

  if [[ -n "${SHADOW_VERIFY_CODEQL_DATABASE:-}" && -d "${SHADOW_VERIFY_CODEQL_DATABASE:-}" ]]; then
    echo "${SHADOW_VERIFY_CODEQL_DATABASE}"
    return 0
  fi

  local candidate=""
  for candidate in \
    "$workdir/.codeql-db" \
    "$workdir/.codeql/database"
  do
    if [[ -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  done

  if [[ -d "$workdir/.codeql/databases" ]]; then
    candidate=$(find "$workdir/.codeql/databases" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -n 1 || true)
    if [[ -n "$candidate" && -d "$candidate" ]]; then
      echo "$candidate"
      return 0
    fi
  fi

  echo ""
}

_shadow_verify_run_sast() {
  local workdir="$1"
  local changed_files="$2"
  local cache_dir="$3"
  local run_id="$4"

  local semgrep_status="skipped"
  local semgrep_available="false"
  local semgrep_ran="false"
  local semgrep_critical=0
  local semgrep_high=0
  local semgrep_medium=0
  local semgrep_low=0
  local semgrep_total=0
  local semgrep_report="$cache_dir/${run_id}_sast_semgrep.json"
  local semgrep_log="$cache_dir/${run_id}_sast_semgrep.log"

  local codeql_status="skipped"
  local codeql_available="false"
  local codeql_ran="false"
  local codeql_critical=0
  local codeql_high=0
  local codeql_medium=0
  local codeql_low=0
  local codeql_total=0
  local codeql_report="$cache_dir/${run_id}_sast_codeql.sarif"
  local codeql_log="$cache_dir/${run_id}_sast_codeql.log"
  local codeql_db=""

  local warnings_tmp=""
  warnings_tmp=$(create_temp_file "shadow_verify_sast_warnings")
  : > "$warnings_tmp"
  : > "$semgrep_log"
  : > "$codeql_log"

  if ! _shadow_verify_truthy "$SHADOW_VERIFY_SAST_ENABLED"; then
    printf '%s\n' "sast_disabled" >> "$warnings_tmp"
    local disabled_warnings='[]'
    disabled_warnings=$(jq -R . "$warnings_tmp" | jq -s 'map(select(length > 0))')
    /bin/rm -f "$warnings_tmp"
    jq -nc \
      --argjson warnings "$disabled_warnings" \
      '{
        status: "skipped",
        findings: {critical: 0, high: 0, medium: 0, low: 0, total: 0},
        warnings: $warnings,
        tools: {
          semgrep: {available: false, ran: false, status: "skipped", critical: 0, high: 0, medium: 0, low: 0, total: 0, report: "", log: ""},
          codeql: {available: false, ran: false, status: "skipped", critical: 0, high: 0, medium: 0, low: 0, total: 0, report: "", log: "", database: ""}
        }
      }'
    return 0
  fi

  if command -v semgrep >/dev/null 2>&1; then
    semgrep_available="true"
    semgrep_ran="true"

    local semgrep_targets=()
    local max_targets="$SHADOW_VERIFY_SAST_MAX_TARGETS"
    if ! [[ "$max_targets" =~ ^[0-9]+$ ]] || [[ "$max_targets" -le 0 ]]; then
      max_targets=120
    fi

    if [[ "$changed_files" == "__FULL_TEST__" ]]; then
      semgrep_targets=(".")
    else
      local target_count=0
      local rel=""
      while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if [[ -f "$workdir/$rel" ]]; then
          semgrep_targets+=("$rel")
          target_count=$((target_count + 1))
          if [[ "$target_count" -ge "$max_targets" ]]; then
            break
          fi
        fi
      done <<< "$changed_files"
      if [[ ${#semgrep_targets[@]} -eq 0 ]]; then
        semgrep_targets=(".")
      fi
    fi

    local semgrep_rc=0
    if (cd "$workdir" && semgrep scan --config "$SHADOW_VERIFY_SEMGREP_CONFIG" --json --quiet "${semgrep_targets[@]}") >"$semgrep_report" 2>"$semgrep_log"; then
      semgrep_rc=0
    else
      semgrep_rc=$?
    fi

    if ! jq -e '.results? != null' "$semgrep_report" >/dev/null 2>&1; then
      if (cd "$workdir" && semgrep --config "$SHADOW_VERIFY_SEMGREP_CONFIG" --json --quiet "${semgrep_targets[@]}") >"$semgrep_report" 2>>"$semgrep_log"; then
        semgrep_rc=0
      else
        semgrep_rc=$?
      fi
    fi

    if jq -e '.results? != null' "$semgrep_report" >/dev/null 2>&1; then
      semgrep_critical=$(jq '[.results[]? | (.extra.severity // "" | ascii_upcase) | select(. == "CRITICAL")] | length' "$semgrep_report" 2>/dev/null || echo "0")
      semgrep_high=$(jq '[.results[]? | (.extra.severity // "" | ascii_upcase) | select(. == "HIGH" or . == "ERROR")] | length' "$semgrep_report" 2>/dev/null || echo "0")
      semgrep_medium=$(jq '[.results[]? | (.extra.severity // "" | ascii_upcase) | select(. == "MEDIUM" or . == "WARNING")] | length' "$semgrep_report" 2>/dev/null || echo "0")
      semgrep_low=$(jq '[.results[]? | (.extra.severity // "" | ascii_upcase) | select(. == "LOW" or . == "INFO")] | length' "$semgrep_report" 2>/dev/null || echo "0")
      semgrep_total=$(jq '[.results[]?] | length' "$semgrep_report" 2>/dev/null || echo "0")

      local semgrep_classified=0
      semgrep_classified=$((semgrep_critical + semgrep_high + semgrep_medium + semgrep_low))
      if [[ "$semgrep_total" -gt "$semgrep_classified" ]]; then
        semgrep_medium=$((semgrep_medium + semgrep_total - semgrep_classified))
      fi

      if [[ "$semgrep_critical" -gt 0 || "$semgrep_high" -gt 0 ]]; then
        semgrep_status="fail"
      elif [[ "$semgrep_total" -gt 0 ]]; then
        semgrep_status="warn"
      else
        semgrep_status="pass"
      fi
    else
      semgrep_status="warn"
      printf '%s\n' "semgrep_execution_failed" >> "$warnings_tmp"
      log_warn "shadow_verify: semgrep execution failed or produced invalid JSON (rc=$semgrep_rc)"
    fi
  else
    log_warn "shadow_verify: semgrep not installed, skipping SAST"
    printf '%s\n' "semgrep_not_installed" >> "$warnings_tmp"
  fi

  if command -v codeql >/dev/null 2>&1; then
    codeql_available="true"
    codeql_db=$(_shadow_verify_find_codeql_database "$workdir")
    if [[ -z "$codeql_db" ]]; then
      codeql_status="skipped"
      printf '%s\n' "codeql_database_not_found" >> "$warnings_tmp"
      log_warn "shadow_verify: codeql installed but database not found; skipping CodeQL SAST"
    else
      codeql_ran="true"
      local codeql_rc=0
      if (cd "$workdir" && codeql database analyze "$codeql_db" "$SHADOW_VERIFY_CODEQL_QUERY_SUITE" --format=sarif-latest --output="$codeql_report") >"$codeql_log" 2>&1; then
        codeql_rc=0
      else
        codeql_rc=$?
      fi

      if jq -e '.runs? != null' "$codeql_report" >/dev/null 2>&1; then
        local codeql_counts_json=""
        codeql_counts_json=$(jq -c '
          def secsev:
            ((.properties["security-severity"] // .properties.securitySeverity // "0") | tostring | tonumber? // 0);
          [
            .runs[]?.results[]?
            | (secsev) as $sev
            | ((.level // "") | ascii_downcase) as $level
            | if $sev >= 9 then
                "critical"
              elif ($sev >= 7 or $level == "error") then
                "high"
              elif ($sev >= 4 or $level == "warning") then
                "medium"
              else
                "low"
              end
          ] as $levels
          | {
              critical: ($levels | map(select(. == "critical")) | length),
              high: ($levels | map(select(. == "high")) | length),
              medium: ($levels | map(select(. == "medium")) | length),
              low: ($levels | map(select(. == "low")) | length),
              total: ($levels | length)
            }
        ' "$codeql_report" 2>/dev/null || echo '{"critical":0,"high":0,"medium":0,"low":0,"total":0}')

        codeql_critical=$(jq -r '.critical // 0' <<< "$codeql_counts_json" 2>/dev/null || echo "0")
        codeql_high=$(jq -r '.high // 0' <<< "$codeql_counts_json" 2>/dev/null || echo "0")
        codeql_medium=$(jq -r '.medium // 0' <<< "$codeql_counts_json" 2>/dev/null || echo "0")
        codeql_low=$(jq -r '.low // 0' <<< "$codeql_counts_json" 2>/dev/null || echo "0")
        codeql_total=$(jq -r '.total // 0' <<< "$codeql_counts_json" 2>/dev/null || echo "0")

        if [[ "$codeql_critical" -gt 0 || "$codeql_high" -gt 0 ]]; then
          codeql_status="fail"
        elif [[ "$codeql_total" -gt 0 ]]; then
          codeql_status="warn"
        else
          codeql_status="pass"
        fi
      else
        codeql_status="warn"
        printf '%s\n' "codeql_execution_failed" >> "$warnings_tmp"
        log_warn "shadow_verify: codeql execution failed or produced invalid SARIF (rc=$codeql_rc)"
      fi
    fi
  else
    log_warn "shadow_verify: codeql not installed, skipping SAST"
    printf '%s\n' "codeql_not_installed" >> "$warnings_tmp"
  fi

  local total_critical=0
  local total_high=0
  local total_medium=0
  local total_low=0
  local total_findings=0
  total_critical=$((semgrep_critical + codeql_critical))
  total_high=$((semgrep_high + codeql_high))
  total_medium=$((semgrep_medium + codeql_medium))
  total_low=$((semgrep_low + codeql_low))
  total_findings=$((semgrep_total + codeql_total))

  local overall_status="pass"
  if [[ "$total_critical" -gt 0 || "$total_high" -gt 0 ]]; then
    overall_status="fail"
  elif [[ "$semgrep_status" == "warn" || "$codeql_status" == "warn" || ("$semgrep_status" == "skipped" && "$codeql_status" == "skipped") ]]; then
    overall_status="warn"
  fi

  local warnings_json='[]'
  warnings_json=$(jq -R . "$warnings_tmp" | jq -s 'map(select(length > 0))')
  /bin/rm -f "$warnings_tmp"

  jq -nc \
    --arg status "$overall_status" \
    --argjson critical "$total_critical" \
    --argjson high "$total_high" \
    --argjson medium "$total_medium" \
    --argjson low "$total_low" \
    --argjson total "$total_findings" \
    --argjson warnings "$warnings_json" \
    --arg semgrep_status "$semgrep_status" \
    --argjson semgrep_available "$semgrep_available" \
    --argjson semgrep_ran "$semgrep_ran" \
    --argjson semgrep_critical "$semgrep_critical" \
    --argjson semgrep_high "$semgrep_high" \
    --argjson semgrep_medium "$semgrep_medium" \
    --argjson semgrep_low "$semgrep_low" \
    --argjson semgrep_total "$semgrep_total" \
    --arg semgrep_report "$semgrep_report" \
    --arg semgrep_log "$semgrep_log" \
    --arg codeql_status "$codeql_status" \
    --argjson codeql_available "$codeql_available" \
    --argjson codeql_ran "$codeql_ran" \
    --argjson codeql_critical "$codeql_critical" \
    --argjson codeql_high "$codeql_high" \
    --argjson codeql_medium "$codeql_medium" \
    --argjson codeql_low "$codeql_low" \
    --argjson codeql_total "$codeql_total" \
    --arg codeql_report "$codeql_report" \
    --arg codeql_log "$codeql_log" \
    --arg codeql_database "$codeql_db" \
    '{
      status: $status,
      findings: {
        critical: $critical,
        high: $high,
        medium: $medium,
        low: $low,
        total: $total
      },
      warnings: $warnings,
      tools: {
        semgrep: {
          available: $semgrep_available,
          ran: $semgrep_ran,
          status: $semgrep_status,
          critical: $semgrep_critical,
          high: $semgrep_high,
          medium: $semgrep_medium,
          low: $semgrep_low,
          total: $semgrep_total,
          report: $semgrep_report,
          log: $semgrep_log
        },
        codeql: {
          available: $codeql_available,
          ran: $codeql_ran,
          status: $codeql_status,
          critical: $codeql_critical,
          high: $codeql_high,
          medium: $codeql_medium,
          low: $codeql_low,
          total: $codeql_total,
          report: $codeql_report,
          log: $codeql_log,
          database: $codeql_database
        }
      }
    }'
}

_shadow_verify_count_issue_like_lines() {
  local file="$1"
  local count

  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi

  count=$(grep -Eic '(error|warn|failed|failure|panic|exception)' "$file" 2>/dev/null || true)
  count="${count:-0}"
  echo "$count"
}

_shadow_verify_extract_test_count() {
  local file="$1"
  local metric="$2"  # passed|failed
  local value=""

  if [[ ! -f "$file" ]]; then
    echo "0"
    return
  fi

  if [[ "$metric" == "passed" ]]; then
    value=$(grep -Eo '[0-9]+[[:space:]]+passed' "$file" 2>/dev/null | tail -1 | awk '{print $1}' || true)
  else
    value=$(grep -Eo '[0-9]+[[:space:]]+(failed|failing|failures?)' "$file" 2>/dev/null | tail -1 | awk '{print $1}' || true)
  fi

  echo "${value:-0}"
}

_shadow_verify_realpath() {
  local path="$1"

  if command -v realpath >/dev/null 2>&1; then
    realpath "$path"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$path"
    return
  fi

  (
    cd "$(dirname "$path")"
    printf '%s/%s\n' "$(pwd -P)" "$(basename "$path")"
  )
}

_shadow_verify_is_trusted_repo_script() {
  local root="$1"
  local script_path="$2"
  local relative_path="${3:-}"
  local root_real=""
  local script_real=""

  [[ -f "$script_path" && ! -L "$script_path" ]] || return 1
  if [[ -n "$relative_path" ]]; then
    relative_path="$(_shadow_verify_normalize_planned_path "$relative_path")" || return 1
    ! _shadow_verify_path_has_symlink_component "$root" "$relative_path" || return 1
  fi

  root_real="$(_shadow_verify_realpath "$root")" || return 1
  script_real="$(_shadow_verify_realpath "$script_path")" || return 1
  [[ "$script_real" == "$root_real"/* ]] || return 1
}

_shadow_verify_route_block_json() {
  local workdir="$1"
  local block_type="${2:-code-block}"
  local router="$workdir/scripts/harness-block-router.sh"
  local route_json=""

  if _shadow_verify_is_trusted_repo_script "$workdir" "$router" "scripts/harness-block-router.sh"; then
    if route_json=$(cd "$workdir" && bash scripts/harness-block-router.sh --type "$block_type" --json 2>/dev/null) \
      && jq -e 'type == "object"' >/dev/null 2>&1 <<< "$route_json"; then
      printf '%s\n' "$route_json"
      return 0
    fi
  fi

  jq -nc --arg block_type "$block_type" \
    '{block_type: $block_type, route_error: "harness_block_router_unavailable"}'
}

_shadow_verify_path_is_changed() {
  local normalized_path="$1"
  local changed_files="$2"
  local changed_path=""

  while IFS= read -r changed_path; do
    [[ -n "$changed_path" ]] || continue
    if [[ "$(_shadow_verify_normalize_planned_path "$changed_path" 2>/dev/null || true)" == "$normalized_path" ]]; then
      return 0
    fi
  done <<< "$changed_files"

  return 1
}

_shadow_verify_normalize_planned_path() {
  local raw_path="$1"
  local path="$raw_path"
  local part=""
  local -a path_parts=()

  [[ -n "$path" ]] || return 1
  [[ "$path" != /* ]] || return 1
  [[ "$path" != -* ]] || return 1
  [[ "$path" != *$'\n'* && "$path" != *$'\r'* && "$path" != *$'\t'* ]] || return 1
  [[ "$path" != *'\'* && "$path" != *"'"* && "$path" != *'"'* ]] || return 1

  while [[ "$path" == ./* ]]; do
    path="${path#./}"
  done

  IFS='/' read -r -a path_parts <<< "$path"
  for part in "${path_parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
  done

  printf '%s\n' "$path"
}

_shadow_verify_validate_planned_path() {
  local workdir="$1"
  local changed_files="$2"
  local raw_path="$3"
  local required_suffix="${4:-}"
  local normalized_path=""
  local workdir_real=""
  local path_real=""

  normalized_path="$(_shadow_verify_normalize_planned_path "$raw_path")" || return 1
  [[ -z "$required_suffix" || "$normalized_path" == *"$required_suffix" ]] || return 1
  [[ -f "$workdir/$normalized_path" && ! -L "$workdir/$normalized_path" ]] || return 1
  ! _shadow_verify_path_has_symlink_component "$workdir" "$normalized_path" || return 1
  workdir_real="$(_shadow_verify_realpath "$workdir")" || return 1
  path_real="$(_shadow_verify_realpath "$workdir/$normalized_path")" || return 1
  [[ "$path_real" == "$workdir_real"/* ]] || return 1
  _shadow_verify_path_is_changed "$normalized_path" "$changed_files" || return 1
  printf '%s\n' "$normalized_path"
}

_shadow_verify_path_has_symlink_component() {
  local workdir="$1"
  local normalized_path="$2"
  local current="$workdir"
  local part=""
  local -a path_parts=()

  IFS='/' read -r -a path_parts <<< "$normalized_path"
  for part in "${path_parts[@]}"; do
    current="$current/$part"
    [[ ! -L "$current" ]] || return 0
  done

  return 1
}

_shadow_verify_validate_planned_diff_path() {
  local workdir="$1"
  local changed_files="$2"
  local raw_path="$3"
  local normalized_path=""
  local workdir_real=""
  local path_real=""

  normalized_path="$(_shadow_verify_normalize_planned_path "$raw_path")" || return 1
  _shadow_verify_path_is_changed "$normalized_path" "$changed_files" || return 1
  ! _shadow_verify_path_has_symlink_component "$workdir" "$normalized_path" || return 1

  if [[ -e "$workdir/$normalized_path" || -L "$workdir/$normalized_path" ]]; then
    workdir_real="$(_shadow_verify_realpath "$workdir")" || return 1
    path_real="$(_shadow_verify_realpath "$workdir/$normalized_path")" || return 1
    [[ "$path_real" == "$workdir_real"/* ]] || return 1
  fi

  printf '%s\n' "$normalized_path"
}

_shadow_verify_prepare_planned_command() {
  local workdir="$1"
  local changed_files="$2"
  local command_line="$3"
  local normalized_path=""
  local token=""
  local -a tokens=()

  SHADOW_VERIFY_PLANNED_COMMAND_ARGS=()
  [[ -n "$command_line" ]] || return 1
  [[ "$command_line" != *$'\n'* && "$command_line" != *$'\r'* ]] || return 1

  read -r -a tokens <<< "$command_line"
  [[ "${#tokens[@]}" -gt 0 ]] || return 1
  for token in "${tokens[@]}"; do
    [[ "$token" != *[\;\&\|\<\>\`\$\\\'\"]* ]] || return 1
  done

  if [[ "${#tokens[@]}" -ge 5 && "${tokens[0]}" == "git" && "${tokens[1]}" == "diff" && ( "${tokens[2]}" == "--check" || "${tokens[2]}" == "--stat" ) && "${tokens[3]}" == "--" ]]; then
    SHADOW_VERIFY_PLANNED_COMMAND_ARGS=("git" "diff" "${tokens[2]}" "--")
    local git_path=""
    for git_path in "${tokens[@]:4}"; do
      normalized_path="$(_shadow_verify_validate_planned_diff_path "$workdir" "$changed_files" "$git_path")" || return 1
      SHADOW_VERIFY_PLANNED_COMMAND_ARGS+=("$normalized_path")
    done
    return 0
  fi

  if [[ "${#tokens[@]}" -eq 4 && "${tokens[0]}" == "bash" && "${tokens[1]}" == "-n" && "${tokens[2]}" == "--" ]]; then
    normalized_path="$(_shadow_verify_validate_planned_path "$workdir" "$changed_files" "${tokens[3]}" ".sh")" || return 1
    SHADOW_VERIFY_PLANNED_COMMAND_ARGS=("bash" "-n" "--" "$normalized_path")
    return 0
  fi

  if [[ "${#tokens[@]}" -eq 4 && "${tokens[0]}" == "jq" && "${tokens[1]}" == "empty" && "${tokens[2]}" == "--" ]]; then
    normalized_path="$(_shadow_verify_validate_planned_path "$workdir" "$changed_files" "${tokens[3]}" ".json")" || return 1
    SHADOW_VERIFY_PLANNED_COMMAND_ARGS=("jq" "empty" "--" "$normalized_path")
    return 0
  fi

  if [[ "${#tokens[@]}" -eq 3 && "${tokens[0]}" == "bash" && "${tokens[1]}" == "--" ]]; then
    normalized_path="$(_shadow_verify_validate_planned_path "$workdir" "$changed_files" "${tokens[2]}" ".sh")" || return 1
    [[ "$normalized_path" == test/integration/*.sh ]] || return 1
    [[ -x "$workdir/$normalized_path" ]] || return 1
    SHADOW_VERIFY_PLANNED_COMMAND_ARGS=("bash" "--" "$normalized_path")
    return 0
  fi

  if [[ "${#tokens[@]}" -eq 3 && "${tokens[0]}" == "bash" && "${tokens[1]}" == "scripts/harness-projection-preflight.sh" && "${tokens[2]}" == "--validate" ]]; then
    _shadow_verify_is_trusted_repo_script "$workdir" "$workdir/scripts/harness-projection-preflight.sh" "scripts/harness-projection-preflight.sh" || return 1
    _shadow_verify_path_is_changed ".agent/registry/orchestration_policy_projection.json" "$changed_files" || return 1
    SHADOW_VERIFY_PLANNED_COMMAND_ARGS=("bash" "scripts/harness-projection-preflight.sh" "--validate")
    return 0
  fi

  return 1
}

_shadow_verify_prepare_untracked_diff_check_paths() {
  local workdir="$1"
  local planned_path=""

  [[ "${#SHADOW_VERIFY_PLANNED_COMMAND_ARGS[@]}" -ge 5 ]] || return 0
  [[ "${SHADOW_VERIFY_PLANNED_COMMAND_ARGS[0]}" == "git" ]] || return 0
  [[ "${SHADOW_VERIFY_PLANNED_COMMAND_ARGS[1]}" == "diff" ]] || return 0
  [[ "${SHADOW_VERIFY_PLANNED_COMMAND_ARGS[2]}" == "--check" ]] || return 0
  [[ "${SHADOW_VERIFY_PLANNED_COMMAND_ARGS[3]}" == "--" ]] || return 0

  for planned_path in "${SHADOW_VERIFY_PLANNED_COMMAND_ARGS[@]:4}"; do
    [[ -e "$workdir/$planned_path" && ! -L "$workdir/$planned_path" ]] || continue
    if ! git -C "$workdir" ls-files --error-unmatch -- "$planned_path" >/dev/null 2>&1; then
      git -C "$workdir" add -N -- "$planned_path"
    fi
  done
}

_shadow_verify_run_harness_check_planner() {
  local workdir="$1"
  local changed_files="$2"
  local cache_dir="$3"
  local run_id="$4"
  local mode="${SHADOW_VERIFY_HARNESS_PLANNER_MODE:-review}"
  local planner="$workdir/scripts/harness-check-planner.sh"
  local command_file="$cache_dir/${run_id}_harness_check_planner.commands"
  local result_jsonl="$cache_dir/${run_id}_harness_check_planner.results.jsonl"
  local harness_log="$cache_dir/${run_id}_harness_check_planner.log"
  local route_json='{}'

  : > "$command_file"
  : > "$result_jsonl"
  : > "$harness_log"

  if [[ "$changed_files" == "__FULL_TEST__" ]]; then
    jq -nc \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      '{
        status: "skipped",
        mode: $mode,
        reason: "full_test_fallback",
        planner: "scripts/harness-check-planner.sh",
        command_count: 0,
        commands: [],
        results: [],
        log: $log
      }'
    return 0
  fi

  route_json=$(_shadow_verify_route_block_json "$workdir" "code-block")

  if [[ ! -f "$planner" ]]; then
    printf 'missing planner: scripts/harness-check-planner.sh\n' >> "$harness_log"
    jq -nc \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      --arg reason "planner_missing" \
      --argjson block_route "$route_json" \
      '{
        status: "fail",
        mode: $mode,
        reason: $reason,
        planner: "scripts/harness-check-planner.sh",
        command_count: 0,
        commands: [],
        results: [],
        block_route: $block_route,
        log: $log
      }'
    return 1
  fi

  if ! _shadow_verify_is_trusted_repo_script "$workdir" "$planner" "scripts/harness-check-planner.sh"; then
    printf 'untrusted planner: scripts/harness-check-planner.sh\n' >> "$harness_log"
    jq -nc \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      --arg reason "planner_untrusted" \
      --argjson block_route "$route_json" \
      '{
        status: "fail",
        mode: $mode,
        reason: $reason,
        planner: "scripts/harness-check-planner.sh",
        command_count: 0,
        commands: [],
        results: [],
        block_route: $block_route,
        log: $log
      }'
    return 1
  fi

  local planner_args=()
  local rel_path=""
  while IFS= read -r rel_path; do
    [[ -n "$rel_path" ]] || continue
    planner_args+=("$rel_path")
  done <<< "$changed_files"

  if [[ "${#planner_args[@]}" -eq 0 ]]; then
    printf 'planner received no changed files\n' >> "$harness_log"
    jq -nc \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      --arg reason "changed_files_empty" \
      --argjson block_route "$route_json" \
      '{
        status: "fail",
        mode: $mode,
        reason: $reason,
        planner: "scripts/harness-check-planner.sh",
        command_count: 0,
        commands: [],
        results: [],
        block_route: $block_route,
        log: $log
      }'
    return 1
  fi

  if ! (cd "$workdir" && bash scripts/harness-check-planner.sh --mode "$mode" -- "${planner_args[@]}") > "$command_file" 2>> "$harness_log"; then
    jq -nc \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      --arg reason "planner_failed" \
      --argjson block_route "$route_json" \
      '{
        status: "fail",
        mode: $mode,
        reason: $reason,
        planner: "scripts/harness-check-planner.sh",
        command_count: 0,
        commands: [],
        results: [],
        block_route: $block_route,
        log: $log
      }'
    return 1
  fi

  local command_count=0
  command_count=$(sed '/^[[:space:]]*$/d' "$command_file" | wc -l | tr -d ' ')
  if [[ "$command_count" -eq 0 ]]; then
    printf 'planner emitted no commands\n' >> "$harness_log"
    jq -nc \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      --arg reason "planner_empty" \
      --argjson block_route "$route_json" \
      '{
        status: "fail",
        mode: $mode,
        reason: $reason,
        planner: "scripts/harness-check-planner.sh",
        command_count: 0,
        commands: [],
        results: [],
        block_route: $block_route,
        log: $log
      }'
    return 1
  fi

  local overall_status="pass"
  local failure_reason=""
  local command_line=""
  local command_rc=0
  while IFS= read -r command_line; do
    [[ -n "$command_line" ]] || continue
    printf '### %s\n' "$command_line" >> "$harness_log"

    if ! _shadow_verify_prepare_planned_command "$workdir" "$changed_files" "$command_line"; then
      overall_status="fail"
      failure_reason="${failure_reason:-planned_command_disallowed}"
      printf 'DISALLOWED planned command\n\n' >> "$harness_log"
      jq -nc --arg command "$command_line" \
        '{command: $command, status: "fail", exit_code: 126, reason: "planned_command_disallowed"}' >> "$result_jsonl"
      continue
    fi

    command_rc=0
    if _shadow_verify_prepare_untracked_diff_check_paths "$workdir" >> "$harness_log" 2>&1; then
      :
    else
      command_rc=$?
      overall_status="fail"
      failure_reason="${failure_reason:-planned_check_failed}"
      jq -nc --arg command "$command_line" --argjson exit_code "$command_rc" \
        '{command: $command, status: "fail", exit_code: $exit_code, reason: "planned_check_failed"}' >> "$result_jsonl"
      printf '\n' >> "$harness_log"
      continue
    fi
    if (cd "$workdir" && "${SHADOW_VERIFY_PLANNED_COMMAND_ARGS[@]}") >> "$harness_log" 2>&1; then
      command_rc=0
      jq -nc --arg command "$command_line" \
        '{command: $command, status: "pass", exit_code: 0}' >> "$result_jsonl"
    else
      command_rc=$?
      overall_status="fail"
      failure_reason="${failure_reason:-planned_check_failed}"
      jq -nc --arg command "$command_line" --argjson exit_code "$command_rc" \
        '{command: $command, status: "fail", exit_code: $exit_code, reason: "planned_check_failed"}' >> "$result_jsonl"
    fi
    printf '\n' >> "$harness_log"
  done < "$command_file"

  local commands_json='[]'
  local results_json='[]'
  commands_json=$(jq -R . "$command_file" | jq -s 'map(select(length > 0))')
  results_json=$(jq -s '.' "$result_jsonl" 2>/dev/null || echo '[]')

  if [[ "$overall_status" == "pass" ]]; then
    jq -nc \
      --arg status "$overall_status" \
      --arg mode "$mode" \
      --arg log "$harness_log" \
      --argjson command_count "$command_count" \
      --argjson commands "$commands_json" \
      --argjson results "$results_json" \
      '{
        status: $status,
        mode: $mode,
        planner: "scripts/harness-check-planner.sh",
        command_count: $command_count,
        commands: $commands,
        results: $results,
        log: $log
      }'
    return 0
  fi

  jq -nc \
    --arg status "$overall_status" \
    --arg mode "$mode" \
    --arg log "$harness_log" \
    --arg reason "${failure_reason:-planned_check_failed}" \
    --argjson command_count "$command_count" \
    --argjson commands "$commands_json" \
    --argjson results "$results_json" \
    --argjson block_route "$route_json" \
    '{
      status: $status,
      mode: $mode,
      reason: $reason,
      planner: "scripts/harness-check-planner.sh",
      command_count: $command_count,
      commands: $commands,
      results: $results,
      block_route: $block_route,
      log: $log
    }'
  return 1
}

_shadow_verify_overlay_changed_files() {
  local src_dir="$1"
  local dst_dir="$2"
  local changed_files_raw="$3"
  local rel_path=""
  local src_path=""
  local dst_path=""
  local dst_parent=""

  if [[ -z "$changed_files_raw" ]]; then
    return 0
  fi

  while IFS= read -r rel_path; do
    [[ -z "$rel_path" ]] && continue
    src_path="$src_dir/$rel_path"
    dst_path="$dst_dir/$rel_path"
    dst_parent=$(dirname "$dst_path")

    if [[ -e "$src_path" || -L "$src_path" ]]; then
      mkdir -p "$dst_parent"
      if [[ -L "$src_path" ]]; then
        rm -rf "$dst_path"
        cp -Pp "$src_path" "$dst_path"
      elif [[ -d "$src_path" ]]; then
        rm -rf "$dst_path"
        cp -R "$src_path" "$dst_path"
      else
        rm -rf "$dst_path"
        cp -p "$src_path" "$dst_path"
      fi
    else
      rm -f "$dst_path" >/dev/null 2>&1 || true
    fi
  done <<< "$changed_files_raw"
}

# 4集合差分:
# 1. コミット済み差分: git diff --name-only HEAD~1 HEAD
# 2. ステージ済み: git diff --name-only --cached
# 3. 未ステージ: git diff --name-only
# 4. 未追跡: git ls-files --others --exclude-standard
# 全てをユニーク統合して changed_files を確定
# 対象ゼロ/過大検出時は "__FULL_TEST__" を返す
_determine_changed_files() {
  local workdir="${1:-.}"
  local threshold="${2:-$SHADOW_VERIFY_CHANGED_LIMIT}"
  local committed staged unstaged untracked combined
  local changed_count=0

  SHADOW_VERIFY_FULL_TEST_FALLBACK="false"
  SHADOW_VERIFY_FULL_TEST_REASON=""
  SHADOW_VERIFY_LAST_CHANGED_FILES_RAW=""
  SHADOW_VERIFY_CHANGED_FILES_RESULT=""

  committed=$(git -C "$workdir" diff --name-only HEAD~1 HEAD 2>/dev/null || true)
  staged=$(git -C "$workdir" diff --name-only --cached 2>/dev/null || true)
  unstaged=$(git -C "$workdir" diff --name-only 2>/dev/null || true)
  untracked=$(git -C "$workdir" ls-files --others --exclude-standard 2>/dev/null || true)

  combined=$(
    printf '%s\n%s\n%s\n%s\n' "$committed" "$staged" "$unstaged" "$untracked" |
      sed '/^[[:space:]]*$/d' |
      sort -u
  )
  SHADOW_VERIFY_LAST_CHANGED_FILES_RAW="$combined"

  if [[ -n "$combined" ]]; then
    changed_count=$(printf '%s\n' "$combined" | wc -l | tr -d ' ')
  fi

  if [[ "$changed_count" -eq 0 ]]; then
    SHADOW_VERIFY_FULL_TEST_FALLBACK="true"
    SHADOW_VERIFY_FULL_TEST_REASON="changed_files_zero"
    SHADOW_VERIFY_CHANGED_FILES_RESULT="__FULL_TEST__"
    echo "__FULL_TEST__"
    return 0
  fi

  if [[ "$changed_count" -gt "$threshold" ]]; then
    SHADOW_VERIFY_FULL_TEST_FALLBACK="true"
    SHADOW_VERIFY_FULL_TEST_REASON="changed_files_over_limit"
    SHADOW_VERIFY_CHANGED_FILES_RESULT="__FULL_TEST__"
    echo "__FULL_TEST__"
    return 0
  fi

  SHADOW_VERIFY_CHANGED_FILES_RESULT="$combined"
  printf '%s\n' "$combined"
}

# 命名規約:
# src/foo/bar.ts → test/foo/bar.test.ts, test/foo/bar.spec.ts
# src/foo/bar.sh → test/foo/bar_test.sh, test/foo/test_bar.sh
# lib/foo.py → test/test_foo.py, tests/test_foo.py
# マッチしないファイルはスキップ（全テストにフォールバックしない）
_select_affected_tests() {
  local changed_files="$1"
  local workdir="${2:-.}"
  local candidates=""
  local file rel dir base

  if [[ "$changed_files" == "__FULL_TEST__" ]]; then
    echo "__FULL_TEST__"
    return 0
  fi

  while IFS= read -r file; do
    [[ -z "$file" ]] && continue

    case "$file" in
      src/*.ts)
        rel="${file#src/}"
        base="${rel%.ts}"
        candidates+=$'\n'"test/${base}.test.ts"
        candidates+=$'\n'"test/${base}.spec.ts"
        ;;
      src/*.sh)
        rel="${file#src/}"
        dir=$(dirname "$rel")
        base=$(basename "$rel" .sh)
        candidates+=$'\n'"test/${dir}/${base}_test.sh"
        candidates+=$'\n'"test/${dir}/test_${base}.sh"
        ;;
      lib/*.py)
        rel="${file#lib/}"
        dir=$(dirname "$rel")
        base=$(basename "$rel" .py)
        if [[ "$dir" == "." ]]; then
          candidates+=$'\n'"test/test_${base}.py"
          candidates+=$'\n'"tests/test_${base}.py"
        else
          candidates+=$'\n'"test/${dir}/test_${base}.py"
          candidates+=$'\n'"tests/${dir}/test_${base}.py"
        fi
        ;;
    esac
  done <<< "$changed_files"

  if [[ -z "$candidates" ]]; then
    return 0
  fi

  printf '%s\n' "$candidates" |
    sed '/^[[:space:]]*$/d' |
    sort -u |
    while IFS= read -r test_path; do
      if [[ -f "$workdir/$test_path" ]]; then
        printf '%s\n' "$test_path"
      fi
    done
}

_shadow_verify_run_lint() {
  local workdir="$1"
  local log_file="$2"
  local changed_files="$3"
  local all_ok="true"
  local ran_any="false"
  local package_json="$workdir/package.json"

  : > "$log_file"

  if [[ -f "$package_json" ]]; then
    local runner
    runner=$(_shadow_verify_resolve_node_runner "$workdir")
    if [[ -n "$runner" ]] && _shadow_verify_has_package_script "$package_json" "lint"; then
      ran_any="true"
      log_info "[LINT] Running Node lint via $runner"
      if ! (cd "$workdir" && "$runner" run lint) >>"$log_file" 2>&1; then
        all_ok="false"
      fi
    fi
  fi

  if [[ -f "$workdir/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
    ran_any="true"
    log_info "[LINT] Running cargo clippy"
    if ! (cd "$workdir" && cargo clippy --all-targets --all-features -D warnings) >>"$log_file" 2>&1; then
      all_ok="false"
    fi
  fi

  if command -v shellcheck >/dev/null 2>&1; then
    local shell_targets=""
    if [[ "$changed_files" == "__FULL_TEST__" ]]; then
      shell_targets=$(cd "$workdir" && find scripts test .claude/commands -type f -name '*.sh' 2>/dev/null | sort -u || true)
    else
      shell_targets=$(printf '%s\n' "$changed_files" | grep -E '\.sh$' || true)
    fi

    if [[ -n "$shell_targets" ]]; then
      ran_any="true"
      log_info "[LINT] Running shellcheck for shell targets"
      while IFS= read -r sh_file; do
        [[ -z "$sh_file" ]] && continue
        if [[ -f "$workdir/$sh_file" ]]; then
          if ! (cd "$workdir" && shellcheck "$sh_file") >>"$log_file" 2>&1; then
            all_ok="false"
          fi
        fi
      done <<< "$shell_targets"
    fi
  fi

  if [[ "$ran_any" == "false" ]]; then
    printf '[LINT] No lint command configured\n' >> "$log_file"
  fi

  [[ "$all_ok" == "true" ]]
}

_shadow_verify_run_typecheck() {
  local workdir="$1"
  local log_file="$2"
  local all_ok="true"
  local ran_any="false"
  local package_json="$workdir/package.json"

  : > "$log_file"

  if [[ -f "$package_json" ]]; then
    local runner
    runner=$(_shadow_verify_resolve_node_runner "$workdir")
    if [[ -n "$runner" ]] && _shadow_verify_has_package_script "$package_json" "typecheck"; then
      ran_any="true"
      log_info "[TYPECHECK] Running Node typecheck via $runner"
      if ! (cd "$workdir" && "$runner" run typecheck) >>"$log_file" 2>&1; then
        all_ok="false"
      fi
    fi
  fi

  if [[ -f "$workdir/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
    ran_any="true"
    log_info "[TYPECHECK] Running cargo check"
    if ! (cd "$workdir" && cargo check --all-targets --all-features) >>"$log_file" 2>&1; then
      all_ok="false"
    fi
  fi

  if [[ -f "$workdir/pyproject.toml" || -f "$workdir/requirements.txt" ]]; then
    if command -v mypy >/dev/null 2>&1; then
      ran_any="true"
      log_info "[TYPECHECK] Running mypy"
      if ! (cd "$workdir" && mypy .) >>"$log_file" 2>&1; then
        all_ok="false"
      fi
    fi
  fi

  if [[ "$ran_any" == "false" ]]; then
    printf '[TYPECHECK] No typecheck command configured\n' >> "$log_file"
  fi

  [[ "$all_ok" == "true" ]]
}

_shadow_verify_run_tests() {
  local workdir="$1"
  local log_file="$2"
  local changed_files="$3"
  local selected_tests="$4"
  local all_ok="true"
  local ran_any="false"
  local full_mode="false"
  local package_json="$workdir/package.json"

  : > "$log_file"

  if [[ "$changed_files" == "__FULL_TEST__" ]]; then
    full_mode="true"
  fi

  if [[ -f "$package_json" ]]; then
    local runner
    runner=$(_shadow_verify_resolve_node_runner "$workdir")
    if [[ -n "$runner" ]] && _shadow_verify_has_package_script "$package_json" "test"; then
      local node_targets=""
      if [[ "$full_mode" == "false" ]]; then
        node_targets=$(printf '%s\n' "$selected_tests" | grep -E '^test/.*\.(test|spec)\.(ts|tsx|js|jsx)$' || true)
      fi

      if [[ "$full_mode" == "true" ]]; then
        ran_any="true"
        log_info "[TEST] Running full Node test suite"
        if ! (cd "$workdir" && "$runner" run test) >>"$log_file" 2>&1; then
          all_ok="false"
        fi
      elif [[ -n "$node_targets" ]]; then
        ran_any="true"
        local cmd=("$runner" run test --)
        while IFS= read -r t; do
          [[ -n "$t" ]] && cmd+=("$t")
        done <<< "$node_targets"
        log_info "[TEST] Running targeted Node tests"
        if ! (cd "$workdir" && "${cmd[@]}") >>"$log_file" 2>&1; then
          all_ok="false"
        fi
      else
        printf '[TEST] Node tests skipped (no affected test matched naming rules)\n' >> "$log_file"
      fi
    fi
  fi

  if [[ -f "$workdir/Cargo.toml" ]] && command -v cargo >/dev/null 2>&1; then
    ran_any="true"
    log_info "[TEST] Running cargo test"
    if ! (cd "$workdir" && cargo test) >>"$log_file" 2>&1; then
      all_ok="false"
    fi
  fi

  if [[ -f "$workdir/pyproject.toml" || -f "$workdir/requirements.txt" ]]; then
    local pytest_cmd=()
    if command -v pytest >/dev/null 2>&1; then
      pytest_cmd=(pytest)
    elif command -v python >/dev/null 2>&1; then
      pytest_cmd=(python -m pytest)
    elif command -v python3 >/dev/null 2>&1; then
      pytest_cmd=(python3 -m pytest)
    fi

    if [[ ${#pytest_cmd[@]} -gt 0 ]]; then
      local py_targets=""
      if [[ "$full_mode" == "false" ]]; then
        py_targets=$(printf '%s\n' "$selected_tests" | grep -E '^(test|tests)/.*\.py$' || true)
      fi

      if [[ "$full_mode" == "true" ]]; then
        ran_any="true"
        log_info "[TEST] Running full Python test suite"
        if ! (cd "$workdir" && "${pytest_cmd[@]}") >>"$log_file" 2>&1; then
          all_ok="false"
        fi
      elif [[ -n "$py_targets" ]]; then
        ran_any="true"
        local py_cmd=("${pytest_cmd[@]}")
        while IFS= read -r t; do
          [[ -n "$t" ]] && py_cmd+=("$t")
        done <<< "$py_targets"
        log_info "[TEST] Running targeted Python tests"
        if ! (cd "$workdir" && "${py_cmd[@]}") >>"$log_file" 2>&1; then
          all_ok="false"
        fi
      else
        printf '[TEST] Python tests skipped (no affected test matched naming rules)\n' >> "$log_file"
      fi
    fi
  fi

  local shell_targets=""
  if [[ "$full_mode" == "true" ]]; then
    if [[ -f "$workdir/test/run_tests.sh" ]]; then
      ran_any="true"
      log_info "[TEST] Running test/run_tests.sh"
      if ! (cd "$workdir" && bash test/run_tests.sh) >>"$log_file" 2>&1; then
        all_ok="false"
      fi
    else
      shell_targets=$(cd "$workdir" && find test tests -type f \( -name '*_test.sh' -o -name 'test_*.sh' \) 2>/dev/null | sort -u || true)
    fi
  else
    shell_targets=$(printf '%s\n' "$selected_tests" | grep -E '\.sh$' || true)
  fi

  if [[ -n "$shell_targets" ]]; then
    ran_any="true"
    log_info "[TEST] Running shell test files"
    while IFS= read -r sh_test; do
      [[ -z "$sh_test" ]] && continue
      if [[ -f "$workdir/$sh_test" ]]; then
        if ! (cd "$workdir" && bash "$sh_test") >>"$log_file" 2>&1; then
          all_ok="false"
        fi
      fi
    done <<< "$shell_targets"
  fi

  if [[ "$ran_any" == "false" ]]; then
    printf '[TEST] No applicable tests selected. Skipped by naming rules.\n' >> "$log_file"
  fi

  [[ "$all_ok" == "true" ]]
}

# lint + typecheck + test の結果を最大120行に圧縮
_generate_diagnostic_summary() {
  local lint_status="$1"
  local lint_issues="$2"
  local type_status="$3"
  local type_errors="$4"
  local test_status="$5"
  local test_passed="$6"
  local test_failed="$7"
  local details_file="$8"
  local max_lines="${9:-$SHADOW_VERIFY_MAX_DIAGNOSTIC_LINES}"
  local sast_status="${10:-skipped}"
  local sast_high="${11:-0}"
  local sast_critical="${12:-0}"
  local detail_budget=$((max_lines - 6))

  if [[ "$detail_budget" -lt 0 ]]; then
    detail_budget=0
  fi

  {
    echo "=== Shadow Verify Diagnostic Summary ==="
    echo "[LINT] $lint_status ($lint_issues issues)"
    echo "[TYPECHECK] $type_status ($type_errors errors)"
    echo "[TEST] $test_status ($test_passed passed, $test_failed failed)"
    echo "[SAST] $sast_status (high=$sast_high, critical=$sast_critical)"
    echo "--- Details (truncated to ${max_lines} lines) ---"
    if [[ -f "$details_file" ]]; then
      sed -n "1,${detail_budget}p" "$details_file"
    else
      echo "(details unavailable)"
    fi
  } | sed -n "1,${max_lines}p"
}

# QG-1/QG-2 fail-closed
_check_quality_gate() {
  local phase=""
  local workdir="."
  local gate_level=""
  local state_file="${STATE_FILE:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)
        [[ $# -ge 2 ]] || { log_error "_check_quality_gate: --phase requires value"; return 1; }
        phase="$2"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || { log_error "_check_quality_gate: --workdir requires value"; return 1; }
        workdir="$2"
        shift 2
        ;;
      --gate)
        [[ $# -ge 2 ]] || { log_error "_check_quality_gate: --gate requires value"; return 1; }
        gate_level="$2"
        shift 2
        ;;
      --state-file)
        [[ $# -ge 2 ]] || { log_error "_check_quality_gate: --state-file requires value"; return 1; }
        state_file="$2"
        shift 2
        ;;
      *)
        log_error "_check_quality_gate: unknown argument: $1"
        return 1
        ;;
    esac
  done

  if [[ -z "$phase" ]]; then
    log_error "_check_quality_gate: --phase is required"
    return 1
  fi

  local normalized_gate=""
  if [[ -n "$gate_level" ]]; then
    normalized_gate=$(_shadow_verify_normalize_gate_level "$gate_level") || {
      log_error "_check_quality_gate: invalid gate level: $gate_level"
      return 1
    }
  elif _shadow_verify_is_impl_like_phase "$phase"; then
    normalized_gate="B"
    log_info "[QG] gate level not specified. defaulting to levelB for phase=$phase"
  fi

  # QG-1: 既存ステータスが failed/skipped なら即失敗
  if _shadow_verify_is_impl_like_phase "$phase" && [[ -n "$state_file" && -f "$state_file" ]]; then
    local prior_status
    prior_status=$(jq -r '.quality_gate.status // empty' "$state_file" 2>/dev/null || true)
    if [[ "$prior_status" == "failed" || "$prior_status" == "skipped" ]]; then
      log_warn "[QG-1] quality_gate.status=$prior_status -> fail-closed"
      return 1
    fi
  fi

  # QG-2: 言語別必須コマンドの存在チェック
  local missing_cmd=0
  if [[ -f "$workdir/package.json" ]]; then
    if ! command -v pnpm >/dev/null 2>&1 && ! command -v npm >/dev/null 2>&1; then
      log_warn "[QG-2] package.json detected but neither pnpm nor npm is available"
      missing_cmd=1
    fi
  fi

  if [[ -f "$workdir/Cargo.toml" ]]; then
    if ! command -v cargo >/dev/null 2>&1; then
      log_warn "[QG-2] Cargo.toml detected but cargo is not available"
      missing_cmd=1
    fi
  fi

  if [[ -f "$workdir/requirements.txt" || -f "$workdir/pyproject.toml" ]]; then
    if ! _shadow_verify_has_pytest_runner; then
      log_warn "[QG-2] Python project detected but pytest runner is not available"
      missing_cmd=1
    fi
  fi

  if [[ "$missing_cmd" -ne 0 ]]; then
    return 1
  fi

  if [[ -z "$normalized_gate" ]]; then
    log_info "[QG] gate level is empty. quality gate command skipped."
    return 0
  fi

  local quality_gate_script="$workdir/scripts/quality_gate.sh"
  if [[ ! -x "$quality_gate_script" ]]; then
    log_warn "[QG] quality_gate.sh not executable: $quality_gate_script"
    return 1
  fi

  log_info "[QG] running quality gate: level=$normalized_gate"
  if ! (cd "$workdir" && "$quality_gate_script" --level "$normalized_gate"); then
    log_warn "[QG] quality gate failed"
    return 1
  fi

  log_info "[QG] quality gate passed"
  return 0
}

_shadow_verify_write_last_result() {
  local workdir="$1"
  local status="$2"
  local phase="$3"
  local iteration="$4"
  local diagnostics_file="$5"
  local details_file="$6"
  local changed_files_count="$7"
  local selected_tests_count="$8"
  local full_test_fallback="$9"
  local full_test_reason="${10:-}"
  local sast_json="${11:-{}}"
  local harness_check_planner_json="${12:-{}}"
  local last_result_file

  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$sast_json"; then
    sast_json='{}'
  fi
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$harness_check_planner_json"; then
    harness_check_planner_json='{}'
  fi

  local cache_dir
  cache_dir=$(_shadow_verify_cache_dir "$workdir")
  ensure_dir "$cache_dir"

  last_result_file=$(_shadow_verify_last_result_file "$workdir")
  jq -n \
    --arg status "$status" \
    --arg phase "$phase" \
    --argjson iteration "$iteration" \
    --arg diagnostics "$diagnostics_file" \
    --arg details "$details_file" \
    --arg timestamp "$(get_timestamp)" \
    --argjson changed_files_count "$changed_files_count" \
    --argjson selected_tests_count "$selected_tests_count" \
    --argjson full_test_fallback "$full_test_fallback" \
    --arg full_test_reason "$full_test_reason" \
    --argjson sast "$sast_json" \
    --argjson harness_check_planner "$harness_check_planner_json" \
    '{
      status: $status,
      phase: $phase,
      iteration: $iteration,
      diagnostics: $diagnostics,
      details: $details,
      timestamp: $timestamp,
      changed_files_count: $changed_files_count,
      selected_tests_count: $selected_tests_count,
      full_test_fallback: $full_test_fallback,
      full_test_reason: $full_test_reason,
      harness_check_planner: $harness_check_planner,
      sast: $sast
    }' > "$last_result_file"

  if [[ -f "$diagnostics_file" ]]; then
    cp "$diagnostics_file" "$(_shadow_verify_last_summary_file "$workdir")"
  fi
}

_shadow_verify_generate_escalation_report() {
  local workdir="$1"
  local phase="$2"
  local attempts="$3"
  shift 3
  local diagnostic_files=("$@")
  local cache_dir
  local ts
  local report_file

  cache_dir=$(_shadow_verify_cache_dir "$workdir")
  ensure_dir "$cache_dir"
  ts=$(date -u +"%Y%m%dT%H%M%SZ")
  report_file="$cache_dir/${phase}_shadow_escalation_${ts}.md"

  {
    printf '# Shadow Verify Escalation Report\n\n'
    printf -- '- Phase: %s\n' "$phase"
    printf -- '- Attempts: %s / %s\n' "$attempts" "$SHADOW_VERIFY_MAX_ATTEMPTS"
    printf -- '- Timestamp: %s\n\n' "$(get_timestamp)"
    printf '## Diagnostic Files\n'
    if [[ ${#diagnostic_files[@]} -eq 0 ]]; then
      printf -- '- (none)\n'
    else
      local f
      for f in "${diagnostic_files[@]}"; do
        printf -- '- %s\n' "$f"
      done
    fi
    printf '\n## Git Status\n'
    printf '```\n'
    git -C "$workdir" status --porcelain 2>/dev/null || printf '(git status unavailable)\n'
    printf '```\n'
  } > "$report_file"

  echo "$report_file"
}

_shadow_verify_run_inner() {
  local phase=""
  local iteration="1"
  local workdir="."
  local gate=""
  local state_file="${STATE_FILE:-}"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_run: --phase requires value"; return 1; }
        phase="$2"
        shift 2
        ;;
      --iter)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_run: --iter requires value"; return 1; }
        iteration="$2"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_run: --workdir requires value"; return 1; }
        workdir="$2"
        shift 2
        ;;
      --gate)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_run: --gate requires value"; return 1; }
        gate="$2"
        shift 2
        ;;
      --state-file)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_run: --state-file requires value"; return 1; }
        state_file="$2"
        shift 2
        ;;
      *)
        log_error "shadow_verify_run: unknown argument: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$phase" ]] || { log_error "shadow_verify_run: --phase is required"; return 1; }
  [[ "$iteration" =~ ^[0-9]+$ ]] || { log_error "shadow_verify_run: --iter must be numeric"; return 1; }
  ensure_cmd git
  ensure_cmd jq

  workdir="$(cd "$workdir" && pwd)"
  local cache_dir
  cache_dir=$(_shadow_verify_cache_dir "$workdir")
  ensure_dir "$cache_dir"

  if [[ "$phase" == "review" ]]; then
    local last_result_file
    last_result_file=$(_shadow_verify_last_result_file "$workdir")
    if [[ ! -f "$last_result_file" ]]; then
      local missing_result
      missing_result=$(jq -n \
        --arg status "fail" \
        --arg phase "$phase" \
        --arg diagnostics "$(_shadow_verify_last_summary_file "$workdir")" \
        '{status: $status, phase: $phase, diagnostics: $diagnostics, reason: "no_previous_shadow_result"}')
      printf '%s\n' "$missing_result"
      return 1
    fi

    local prior_status
    prior_status=$(jq -r '.status // "fail"' "$last_result_file")
    cat "$last_result_file"
    if [[ "$prior_status" == "pass" ]]; then
      return 0
    fi
    return 1
  fi

  if ! _shadow_verify_is_impl_like_phase "$phase"; then
    log_error "shadow_verify_run: unsupported phase '$phase' (expected impl/fix/test/review)"
    return 1
  fi

  _determine_changed_files "$workdir" >/dev/null
  local changed_files="${SHADOW_VERIFY_CHANGED_FILES_RESULT:-}"
  local changed_files_raw="${SHADOW_VERIFY_LAST_CHANGED_FILES_RAW:-}"
  local changed_files_count=0
  if [[ "$changed_files" != "__FULL_TEST__" ]]; then
    changed_files_count=$(printf '%s\n' "$changed_files" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  elif [[ -n "$changed_files_raw" ]]; then
    changed_files_count=$(printf '%s\n' "$changed_files_raw" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  fi

  local deletion_guard_fail_closed_json='{"verdict":"WARN","block":false,"shadow_verify_required":true,"deleted_paths":[],"warnings":["deletion_guard_error","analysis_failed"],"ci_entrypoint_deleted":[],"config_lock_deleted":[],"unsupported_parser_deletions":[],"deletion_guard_error":true,"details":"analysis_failed"}'
  local deletion_guard_json="$deletion_guard_fail_closed_json"
  if ! deletion_guard_json=$(_shadow_verify_analyze_non_code_deletions "$workdir" 2>/dev/null); then
    log_warn "Non-code deletion analysis failed, falling back to WARN (fail-closed)"
    deletion_guard_json="$deletion_guard_fail_closed_json"
  fi
  if ! jq -e 'type == "object" and (.verdict? != null)' >/dev/null 2>&1 <<< "$deletion_guard_json"; then
    log_warn "Non-code deletion analysis returned invalid JSON, falling back to WARN (fail-closed)"
    deletion_guard_json="$deletion_guard_fail_closed_json"
  fi

  local deletion_guard_verdict="PASS"
  deletion_guard_verdict=$(jq -r '.verdict // "PASS"' <<< "$deletion_guard_json" 2>/dev/null || echo "PASS")
  local deletion_guard_block="false"
  deletion_guard_block=$(jq -r '.block // false' <<< "$deletion_guard_json" 2>/dev/null || echo "false")
  local deletion_guard_shadow_required="false"
  deletion_guard_shadow_required=$(jq -r '.shadow_verify_required // false' <<< "$deletion_guard_json" 2>/dev/null || echo "false")

  local deletion_guard_warnings_json='[]'
  deletion_guard_warnings_json=$(jq -c '.warnings // []' <<< "$deletion_guard_json" 2>/dev/null || echo '[]')
  local deletion_guard_ci_json='[]'
  deletion_guard_ci_json=$(jq -c '.ci_entrypoint_deleted // []' <<< "$deletion_guard_json" 2>/dev/null || echo '[]')
  local deletion_guard_config_json='[]'
  deletion_guard_config_json=$(jq -c '.config_lock_deleted // []' <<< "$deletion_guard_json" 2>/dev/null || echo '[]')
  local deletion_guard_unsupported_json='[]'
  deletion_guard_unsupported_json=$(jq -c '.unsupported_parser_deletions // []' <<< "$deletion_guard_json" 2>/dev/null || echo '[]')

  local deletion_guard_warnings_line=""
  deletion_guard_warnings_line=$(jq -r '(.warnings // []) | join(",")' <<< "$deletion_guard_json" 2>/dev/null || echo "")
  local deletion_guard_ci_line=""
  deletion_guard_ci_line=$(jq -r '(.ci_entrypoint_deleted // []) | join(",")' <<< "$deletion_guard_json" 2>/dev/null || echo "")
  local deletion_guard_config_line=""
  deletion_guard_config_line=$(jq -r '(.config_lock_deleted // []) | join(",")' <<< "$deletion_guard_json" 2>/dev/null || echo "")
  local deletion_guard_unsupported_line=""
  deletion_guard_unsupported_line=$(jq -r '(.unsupported_parser_deletions // []) | join(",")' <<< "$deletion_guard_json" 2>/dev/null || echo "")

  if [[ "$deletion_guard_verdict" == "BLOCK" ]]; then
    log_error "shadow_verify: deletion guard BLOCK (ci_entrypoint_deletion) paths=${deletion_guard_ci_line:-none}"
  elif [[ "$deletion_guard_verdict" == "WARN" ]]; then
    log_warn "shadow_verify: deletion guard WARN warnings=${deletion_guard_warnings_line:-none}"
  fi

  local selected_tests
  selected_tests=$(_select_affected_tests "$changed_files" "$workdir" || true)
  local selected_tests_count=0
  if [[ -n "$selected_tests" && "$selected_tests" != "__FULL_TEST__" ]]; then
    selected_tests_count=$(printf '%s\n' "$selected_tests" | sed '/^[[:space:]]*$/d' | wc -l | tr -d ' ')
  fi

  local wt_parent=""
  local wt_dir=""
  local run_id
  run_id="$(date -u +"%Y%m%dT%H%M%SZ")_iter${iteration}_$$"
  local lint_log="$cache_dir/${run_id}_lint.log"
  local type_log="$cache_dir/${run_id}_typecheck.log"
  local test_log="$cache_dir/${run_id}_test.log"
  local qg_log="$cache_dir/${run_id}_quality_gate.log"
  local detail_log="$cache_dir/${run_id}_details.log"
  local summary_log="$cache_dir/${run_id}_summary.log"
  local result_json=""
  local setup_sast_json='{"status":"warn","findings":{"critical":0,"high":0,"medium":0,"low":0,"total":0},"warnings":["sast_not_executed_due_setup_failure"],"tools":{"semgrep":{"available":false,"ran":false,"status":"skipped","critical":0,"high":0,"medium":0,"low":0,"total":0,"report":"","log":""},"codeql":{"available":false,"ran":false,"status":"skipped","critical":0,"high":0,"medium":0,"low":0,"total":0,"report":"","log":"","database":""}}}'
  local setup_harness_json='{"status":"not_run","reason":"setup_failure_before_harness_planner","planner":"scripts/harness-check-planner.sh","command_count":0,"commands":[],"results":[]}'

  _emit_setup_failure_result() {
    local reason="$1"
    {
      echo "### Metadata"
      echo "phase=$phase"
      echo "iteration=$iteration"
      echo "workdir=$workdir"
      echo ""
      echo "### Internal Error"
      echo "$reason"
    } > "$detail_log"

    _generate_diagnostic_summary \
      "fail" "1" \
      "fail" "1" \
      "fail" "0" "1" \
      "$detail_log" "$SHADOW_VERIFY_MAX_DIAGNOSTIC_LINES" \
      "warn" "0" "0" > "$summary_log"

    _shadow_verify_write_last_result \
      "$workdir" "fail" "$phase" "$iteration" \
      "$summary_log" "$detail_log" "$changed_files_count" "$selected_tests_count" \
      "$SHADOW_VERIFY_FULL_TEST_FALLBACK" "$SHADOW_VERIFY_FULL_TEST_REASON" \
      "$setup_sast_json" "$setup_harness_json"

    result_json=$(jq -n \
      --arg status "fail" \
      --arg phase "$phase" \
      --argjson iteration "$iteration" \
      --arg diagnostics "$summary_log" \
      --arg details "$detail_log" \
      --arg reason "$reason" \
      --argjson changed_files_count "$changed_files_count" \
      --argjson selected_tests_count "$selected_tests_count" \
      --argjson full_test_fallback "$SHADOW_VERIFY_FULL_TEST_FALLBACK" \
      --arg full_test_reason "$SHADOW_VERIFY_FULL_TEST_REASON" \
      --argjson sast "$setup_sast_json" \
      --argjson harness_check_planner "$setup_harness_json" \
      '{
        status: $status,
        phase: $phase,
        iteration: $iteration,
        diagnostics: $diagnostics,
        details: $details,
        reason: $reason,
        changed_files_count: $changed_files_count,
        selected_tests_count: $selected_tests_count,
        full_test_fallback: $full_test_fallback,
        full_test_reason: $full_test_reason,
        harness_check_planner: $harness_check_planner,
        sast: $sast
      }')
    printf '%s\n' "$result_json"
  }

  _shadow_cleanup() {
    if [[ -n "${wt_dir:-}" ]]; then
      git -C "$workdir" worktree remove --force "$wt_dir" >/dev/null 2>&1 || true
    fi
    if [[ -n "${wt_parent:-}" && -d "$wt_parent" ]]; then
      rm -rf "$wt_parent" >/dev/null 2>&1 || true
    fi
  }
  trap _shadow_cleanup EXIT INT TERM

  wt_parent=$(create_temp_dir "shadow_verify_wt")
  wt_dir="$wt_parent/worktree"
  log_info "shadow_verify: create temporary worktree: $wt_dir"
  if ! git -C "$workdir" worktree add --detach "$wt_dir" HEAD >/dev/null; then
    log_error "shadow_verify: failed to create temporary worktree: $wt_dir"
    _emit_setup_failure_result "failed to create temporary worktree"
    return 1
  fi

  if ! _shadow_verify_overlay_changed_files "$workdir" "$wt_dir" "$changed_files_raw"; then
    log_error "shadow_verify: failed to sync changed files into temporary worktree"
    _emit_setup_failure_result "failed to sync changed files into temporary worktree"
    return 1
  fi

  local lint_status="pass"
  local type_status="pass"
  local test_status="pass"
  local qg_status="pass"
  local harness_status="pass"
  local harness_json='{}'
  local sast_json='{"status":"warn","findings":{"critical":0,"high":0,"medium":0,"low":0,"total":0},"warnings":["sast_not_executed"],"tools":{"semgrep":{"available":false,"ran":false,"status":"skipped","critical":0,"high":0,"medium":0,"low":0,"total":0,"report":"","log":""},"codeql":{"available":false,"ran":false,"status":"skipped","critical":0,"high":0,"medium":0,"low":0,"total":0,"report":"","log":"","database":""}}}'

  if ! harness_json=$(_shadow_verify_run_harness_check_planner "$wt_dir" "$changed_files" "$cache_dir" "$run_id"); then
    harness_status="fail"
  fi
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$harness_json"; then
    harness_status="fail"
    harness_json='{"status":"fail","reason":"harness_check_planner_invalid_json","planner":"scripts/harness-check-planner.sh","command_count":0,"commands":[],"results":[]}'
  fi

  if ! _shadow_verify_run_lint "$wt_dir" "$lint_log" "$changed_files"; then
    lint_status="fail"
  fi

  if ! _shadow_verify_run_typecheck "$wt_dir" "$type_log"; then
    type_status="fail"
  fi

  if ! _shadow_verify_run_tests "$wt_dir" "$test_log" "$changed_files" "$selected_tests"; then
    test_status="fail"
  fi

  if ! _check_quality_gate --phase "$phase" --workdir "$wt_dir" --gate "$gate" --state-file "$state_file" >"$qg_log" 2>&1; then
    qg_status="fail"
  fi

  sast_json=$(_shadow_verify_run_sast "$wt_dir" "$changed_files" "$cache_dir" "$run_id")
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$sast_json"; then
    log_warn "shadow_verify: invalid SAST result JSON, fallback to warn"
    sast_json='{"status":"warn","findings":{"critical":0,"high":0,"medium":0,"low":0,"total":0},"warnings":["sast_result_invalid_json"],"tools":{"semgrep":{"available":false,"ran":false,"status":"skipped","critical":0,"high":0,"medium":0,"low":0,"total":0,"report":"","log":""},"codeql":{"available":false,"ran":false,"status":"skipped","critical":0,"high":0,"medium":0,"low":0,"total":0,"report":"","log":"","database":""}}}'
  fi

  local sast_status="warn"
  sast_status=$(jq -r '.status // "warn"' <<< "$sast_json" 2>/dev/null || echo "warn")
  local sast_critical=0
  sast_critical=$(jq -r '.findings.critical // 0' <<< "$sast_json" 2>/dev/null || echo "0")
  local sast_high=0
  sast_high=$(jq -r '.findings.high // 0' <<< "$sast_json" 2>/dev/null || echo "0")
  local sast_medium=0
  sast_medium=$(jq -r '.findings.medium // 0' <<< "$sast_json" 2>/dev/null || echo "0")
  local sast_low=0
  sast_low=$(jq -r '.findings.low // 0' <<< "$sast_json" 2>/dev/null || echo "0")
  local sast_total=0
  sast_total=$(jq -r '.findings.total // 0' <<< "$sast_json" 2>/dev/null || echo "0")

  local lint_issues type_errors test_passed test_failed
  lint_issues=$(_shadow_verify_count_issue_like_lines "$lint_log")
  type_errors=$(_shadow_verify_count_issue_like_lines "$type_log")
  test_passed=$(_shadow_verify_extract_test_count "$test_log" "passed")
  test_failed=$(_shadow_verify_extract_test_count "$test_log" "failed")

  if [[ "$test_status" == "fail" && "$test_failed" == "0" ]]; then
    test_failed="1"
  fi

  {
    echo "### Metadata"
    echo "phase=$phase"
    echo "iteration=$iteration"
    echo "workdir=$workdir"
    echo "full_test_fallback=$SHADOW_VERIFY_FULL_TEST_FALLBACK"
    echo "full_test_reason=${SHADOW_VERIFY_FULL_TEST_REASON:-none}"
    echo ""
    echo "### Changed Files"
    if [[ "$changed_files" == "__FULL_TEST__" ]]; then
      echo "__FULL_TEST__"
    else
      printf '%s\n' "$changed_files"
    fi
    echo ""
    echo "### Selected Tests"
    if [[ -n "$selected_tests" ]]; then
      printf '%s\n' "$selected_tests"
    else
      echo "(none)"
    fi
    echo ""
    echo "### Deletion Guard"
    echo "verdict=$deletion_guard_verdict"
    echo "shadow_verify_required=$deletion_guard_shadow_required"
    echo "warnings=${deletion_guard_warnings_line:-none}"
    echo "ci_entrypoint_deleted=${deletion_guard_ci_line:-none}"
    echo "config_lock_deleted=${deletion_guard_config_line:-none}"
    echo "unsupported_parser_deletion=${deletion_guard_unsupported_line:-none}"
    echo ""
    echo "### [HARNESS_CHECK_PLANNER]"
    echo "status=$harness_status"
    jq -c '.' <<< "$harness_json" 2>/dev/null || true
    local harness_planner_log=""
    harness_planner_log=$(jq -r '.log // empty' <<< "$harness_json" 2>/dev/null || true)
    if [[ -n "$harness_planner_log" && -f "$harness_planner_log" ]]; then
      echo "--- [HARNESS_CHECK_PLANNER:LOG] ---"
      cat "$harness_planner_log" 2>/dev/null || true
      echo ""
    fi
    echo ""
    echo "### [QUALITY_GATE]"
    cat "$qg_log" 2>/dev/null || true
    echo ""
    echo "### [SAST]"
    echo "status=$sast_status"
    echo "critical=$sast_critical"
    echo "high=$sast_high"
    echo "medium=$sast_medium"
    echo "low=$sast_low"
    echo "total=$sast_total"
    jq -c '.' <<< "$sast_json" 2>/dev/null || true
    local semgrep_sast_log=""
    semgrep_sast_log=$(jq -r '.tools.semgrep.log // empty' <<< "$sast_json" 2>/dev/null || true)
    if [[ -n "$semgrep_sast_log" && -f "$semgrep_sast_log" ]]; then
      echo "--- [SAST:SEMGREP] ---"
      cat "$semgrep_sast_log" 2>/dev/null || true
      echo ""
    fi
    local codeql_sast_log=""
    codeql_sast_log=$(jq -r '.tools.codeql.log // empty' <<< "$sast_json" 2>/dev/null || true)
    if [[ -n "$codeql_sast_log" && -f "$codeql_sast_log" ]]; then
      echo "--- [SAST:CODEQL] ---"
      cat "$codeql_sast_log" 2>/dev/null || true
      echo ""
    fi
    echo "### [LINT]"
    cat "$lint_log" 2>/dev/null || true
    echo ""
    echo "### [TYPECHECK]"
    cat "$type_log" 2>/dev/null || true
    echo ""
    echo "### [TEST]"
    cat "$test_log" 2>/dev/null || true
  } > "$detail_log"

  _generate_diagnostic_summary \
    "$lint_status" "$lint_issues" \
    "$type_status" "$type_errors" \
    "$test_status" "$test_passed" "$test_failed" \
    "$detail_log" "$SHADOW_VERIFY_MAX_DIAGNOSTIC_LINES" \
    "$sast_status" "$sast_high" "$sast_critical" > "$summary_log"

  local overall_status="pass"
  if [[ "$harness_status" == "fail" || "$lint_status" == "fail" || "$type_status" == "fail" || "$test_status" == "fail" || "$qg_status" == "fail" || "$deletion_guard_block" == "true" || "$sast_status" == "fail" ]]; then
    overall_status="fail"
  fi

  _shadow_verify_write_last_result \
    "$workdir" "$overall_status" "$phase" "$iteration" \
    "$summary_log" "$detail_log" "$changed_files_count" "$selected_tests_count" \
    "$SHADOW_VERIFY_FULL_TEST_FALLBACK" "$SHADOW_VERIFY_FULL_TEST_REASON" \
    "$sast_json" "$harness_json"

  result_json=$(jq -n \
    --arg status "$overall_status" \
    --arg phase "$phase" \
    --argjson iteration "$iteration" \
    --arg diagnostics "$summary_log" \
    --arg details "$detail_log" \
    --arg lint_status "$lint_status" \
    --arg type_status "$type_status" \
    --arg test_status "$test_status" \
    --arg qg_status "$qg_status" \
    --arg harness_status "$harness_status" \
    --argjson harness_check_planner "$harness_json" \
    --argjson sast "$sast_json" \
    --arg deletion_guard_verdict "$deletion_guard_verdict" \
    --argjson deletion_guard_shadow_required "$deletion_guard_shadow_required" \
    --argjson deletion_guard_warnings "$deletion_guard_warnings_json" \
    --argjson deletion_guard_ci "$deletion_guard_ci_json" \
    --argjson deletion_guard_config "$deletion_guard_config_json" \
    --argjson deletion_guard_unsupported "$deletion_guard_unsupported_json" \
    --argjson changed_files_count "$changed_files_count" \
    --argjson selected_tests_count "$selected_tests_count" \
    --argjson full_test_fallback "$SHADOW_VERIFY_FULL_TEST_FALLBACK" \
    --arg full_test_reason "$SHADOW_VERIFY_FULL_TEST_REASON" \
    '{
      status: $status,
      phase: $phase,
      iteration: $iteration,
      diagnostics: $diagnostics,
      details: $details,
      lint: {status: $lint_status},
      typecheck: {status: $type_status},
      test: {status: $test_status},
      harness_check_planner: $harness_check_planner,
      quality_gate: {status: $qg_status},
      sast: $sast,
      deletion_guard: {
        verdict: $deletion_guard_verdict,
        shadow_verify_required: $deletion_guard_shadow_required,
        warnings: $deletion_guard_warnings,
        ci_entrypoint_deleted: $deletion_guard_ci,
        config_lock_deleted: $deletion_guard_config,
        unsupported_parser_deletions: $deletion_guard_unsupported
      },
      changed_files_count: $changed_files_count,
      selected_tests_count: $selected_tests_count,
      full_test_fallback: $full_test_fallback,
      full_test_reason: $full_test_reason
    }')

  printf '%s\n' "$result_json"

  if [[ "$overall_status" == "pass" ]]; then
    return 0
  fi
  return 1
}

shadow_verify_run() {
  # --phase <phase>: impl/fix のみ実行。review では前回結果を参照
  # --iter <n>: 現在のイテレーション番号
  # --workdir <dir>: 作業ディレクトリ（省略時はカレント）
  ( _shadow_verify_run_inner "$@" )
}

shadow_verify_loop() {
  local phase=""
  local start_iter="1"
  local workdir="."
  local gate=""
  local state_file="${STATE_FILE:-}"
  local reviewers="${REVIEWERS:-}"
  local coder_output="${CODER_OUT:-}"
  local review_output_dir=""
  local review_suffix=""
  local review_timeout="${REVIEWER_TIMEOUT:-7200}"
  local task_tmpdir=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --phase)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --phase requires value"; return 1; }
        phase="$2"
        shift 2
        ;;
      --iter)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --iter requires value"; return 1; }
        start_iter="$2"
        shift 2
        ;;
      --workdir)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --workdir requires value"; return 1; }
        workdir="$2"
        shift 2
        ;;
      --gate)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --gate requires value"; return 1; }
        gate="$2"
        shift 2
        ;;
      --state-file)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --state-file requires value"; return 1; }
        state_file="$2"
        shift 2
        ;;
      --reviewers)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --reviewers requires value"; return 1; }
        reviewers="$2"
        shift 2
        ;;
      --coder-output)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --coder-output requires value"; return 1; }
        coder_output="$2"
        shift 2
        ;;
      --review-output-dir)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --review-output-dir requires value"; return 1; }
        review_output_dir="$2"
        shift 2
        ;;
      --review-suffix)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --review-suffix requires value"; return 1; }
        review_suffix="$2"
        shift 2
        ;;
      --review-timeout)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --review-timeout requires value"; return 1; }
        review_timeout="$2"
        shift 2
        ;;
      --task-tmpdir)
        [[ $# -ge 2 ]] || { log_error "shadow_verify_loop: --task-tmpdir requires value"; return 1; }
        task_tmpdir="$2"
        shift 2
        ;;
      *)
        log_error "shadow_verify_loop: unknown argument: $1"
        return 1
        ;;
    esac
  done

  [[ -n "$phase" ]] || { log_error "shadow_verify_loop: --phase is required"; return 1; }
  [[ "$start_iter" =~ ^[0-9]+$ ]] || { log_error "shadow_verify_loop: --iter must be numeric"; return 1; }
  workdir="$(cd "$workdir" && pwd)"

  if [[ -z "$review_output_dir" ]]; then
    review_output_dir="$workdir/.claude/tmp"
  fi

  local attempt=0
  local iter="$start_iter"
  local diag_files=()
  local result_json=""

  while [[ "$attempt" -lt "$SHADOW_VERIFY_MAX_ATTEMPTS" ]]; do
    attempt=$((attempt + 1))
    log_info "shadow_verify_loop: attempt $attempt/$SHADOW_VERIFY_MAX_ATTEMPTS (phase=$phase, iter=$iter)"

    local run_rc=0
    result_json=$(shadow_verify_run --phase "$phase" --iter "$iter" --workdir "$workdir" --gate "$gate" --state-file "$state_file") || run_rc=$?

    local diag_file=""
    diag_file=$(printf '%s' "$result_json" | jq -r '.diagnostics // empty' 2>/dev/null || true)
    if [[ -n "$diag_file" ]]; then
      diag_files+=("$diag_file")
    fi

    if [[ "$run_rc" -eq 0 ]]; then
      log_success "shadow_verify_loop: verification passed"

      if declare -F reviewer_run_all >/dev/null 2>&1; then
        if [[ -n "$reviewers" && -n "$coder_output" && -f "$coder_output" ]]; then
          log_info "shadow_verify_loop: proceeding to reviewer_run_all()"
          local agg_reviews
          agg_reviews=$(reviewer_run_all "$reviewers" "$coder_output" "$review_output_dir" "$phase" "$review_suffix" "$review_timeout" "${task_tmpdir:-$review_output_dir}")
          printf '%s\n' "$agg_reviews"
        else
          log_warn "shadow_verify_loop: reviewer_run_all available but reviewers/coder_output is not ready"
        fi
      fi

      printf '%s\n' "$result_json"
      return 0
    fi

    if [[ -n "$diag_file" && -f "$diag_file" ]]; then
      cat "$diag_file"
    fi
    iter=$((iter + 1))
  done

  local escalation_report
  escalation_report=$(_shadow_verify_generate_escalation_report "$workdir" "$phase" "$attempt" "${diag_files[@]}")
  log_error "shadow_verify_loop: failed after $attempt attempts. escalation report: $escalation_report"
  printf '%s\n' "$escalation_report"
  return 1
}

shadow_verify_usage() {
  cat <<'USAGE'
Usage:
  shadow_verify.sh run --phase PHASE --iter N --workdir PATH [--gate LEVEL] [--state-file PATH]
  shadow_verify.sh loop --phase PHASE --iter N --workdir PATH [--gate LEVEL] [--state-file PATH]
USAGE
}

_shadow_verify_collect_deleted_files() {
  local workdir="${1:-.}"
  (
    cd "$workdir"
    {
      git diff --name-only --diff-filter=D HEAD~1 HEAD 2>/dev/null || true
      git diff --name-only --diff-filter=D 2>/dev/null || true
      git diff --cached --name-only --diff-filter=D 2>/dev/null || true
      git ls-files --deleted 2>/dev/null || true
    } | sed '/^[[:space:]]*$/d' | sort -u
  )
}

_shadow_verify_is_ci_entrypoint_deletion_path() {
  local path="${1:-}"
  case "$path" in
    .github/workflows/*.yml|.github/workflows/*.yaml|Makefile|Dockerfile|docker-compose*.yml|docker-compose*.yaml|.circleci/config.yml|.circleci/config.yaml|Jenkinsfile)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_shadow_verify_is_config_or_lock_deletion_path() {
  local path="${1:-}"
  case "$path" in
    *.lock|*.toml|.env|.env.*|*/.env|*/.env.*|tsconfig.json|*/tsconfig.json|package.json|*/package.json|package-lock.json|*/package-lock.json|pnpm-lock.yaml|*/pnpm-lock.yaml|yarn.lock|*/yarn.lock|Cargo.toml|*/Cargo.toml|go.mod|go.sum|*/go.mod|*/go.sum|requirements.txt|*/requirements.txt|pyproject.toml|*/pyproject.toml|Pipfile|Pipfile.lock|*/Pipfile|*/Pipfile.lock|Gemfile|Gemfile.lock|*/Gemfile|*/Gemfile.lock|composer.json|composer.lock|*/composer.json|*/composer.lock)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_shadow_verify_is_unsupported_parser_deletion_path() {
  local path="${1:-}"
  case "$path" in
    *.go|*.rs|*.java|*.kt|*.kts|*.c|*.cc|*.cpp|*.cxx|*.h|*.hpp|*.cs|*.swift|*.rb|*.php|*.scala|*.lua|*.r|*.pl|*.pm|*.dart|*.ex|*.exs|*.erl|*.hrl|*.clj|*.groovy)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

_shadow_verify_json_array_from_file() {
  local file_path="$1"
  if [[ -f "$file_path" && -s "$file_path" ]]; then
    jq -R . "$file_path" | jq -s 'map(select(length > 0))'
  else
    echo '[]'
  fi
}

_shadow_verify_analyze_non_code_deletions() {
  local workdir="${1:-.}"
  ensure_cmd jq

  local deleted_tmp=""
  deleted_tmp=$(create_temp_file "shadow_verify_deleted")
  _shadow_verify_collect_deleted_files "$workdir" > "$deleted_tmp"

  local deleted_paths_json='[]'
  deleted_paths_json=$(_shadow_verify_json_array_from_file "$deleted_tmp")

  local ci_tmp=""
  ci_tmp=$(create_temp_file "shadow_verify_deleted_ci")
  local config_tmp=""
  config_tmp=$(create_temp_file "shadow_verify_deleted_config")
  local unsupported_tmp=""
  unsupported_tmp=$(create_temp_file "shadow_verify_deleted_unsupported")

  : > "$ci_tmp"
  : > "$config_tmp"
  : > "$unsupported_tmp"

  local rel_path=""
  while IFS= read -r rel_path; do
    [[ -n "$rel_path" ]] || continue

    if _shadow_verify_is_ci_entrypoint_deletion_path "$rel_path"; then
      printf '%s\n' "$rel_path" >> "$ci_tmp"
    fi
    if _shadow_verify_is_config_or_lock_deletion_path "$rel_path"; then
      printf '%s\n' "$rel_path" >> "$config_tmp"
    fi
    if _shadow_verify_is_unsupported_parser_deletion_path "$rel_path"; then
      printf '%s\n' "$rel_path" >> "$unsupported_tmp"
    fi
  done < "$deleted_tmp"

  local ci_json='[]'
  ci_json=$(_shadow_verify_json_array_from_file "$ci_tmp")
  local config_json='[]'
  config_json=$(_shadow_verify_json_array_from_file "$config_tmp")
  local unsupported_json='[]'
  unsupported_json=$(_shadow_verify_json_array_from_file "$unsupported_tmp")

  local ci_count=0
  ci_count=$(jq 'length' <<< "$ci_json" 2>/dev/null || echo "0")
  local config_count=0
  config_count=$(jq 'length' <<< "$config_json" 2>/dev/null || echo "0")
  local unsupported_count=0
  unsupported_count=$(jq 'length' <<< "$unsupported_json" 2>/dev/null || echo "0")

  local has_ci="false"
  local has_config="false"
  local has_unsupported="false"
  if [[ "$ci_count" -gt 0 ]]; then
    has_ci="true"
  fi
  if [[ "$config_count" -gt 0 ]]; then
    has_config="true"
  fi
  if [[ "$unsupported_count" -gt 0 ]]; then
    has_unsupported="true"
  fi

  local verdict="PASS"
  local block="false"
  local shadow_verify_required="false"
  if [[ "$has_ci" == "true" ]]; then
    verdict="BLOCK"
    block="true"
    shadow_verify_required="true"
  elif [[ "$has_config" == "true" || "$has_unsupported" == "true" ]]; then
    verdict="WARN"
    shadow_verify_required="true"
  fi

  local warnings_json='[]'
  warnings_json=$(jq -n \
    --arg has_ci "$has_ci" \
    --arg has_config "$has_config" \
    --arg has_unsupported "$has_unsupported" \
    '
      [
        (if $has_ci == "true" then "ci_entrypoint_deletion_block" else empty end),
        (if $has_config == "true" then "config_lock_deletion" else empty end),
        (if $has_unsupported == "true" then "unsupported_parser_deletion" else empty end)
      ]
      | map(select(type == "string" and length > 0))
    ')

  jq -nc \
    --arg verdict "$verdict" \
    --argjson block "$block" \
    --argjson shadow_verify_required "$shadow_verify_required" \
    --argjson deleted_paths "$deleted_paths_json" \
    --argjson warnings "$warnings_json" \
    --argjson ci_entrypoint_deleted "$ci_json" \
    --argjson config_lock_deleted "$config_json" \
    --argjson unsupported_parser_deletions "$unsupported_json" \
    '{
      verdict: $verdict,
      block: $block,
      shadow_verify_required: $shadow_verify_required,
      deleted_paths: $deleted_paths,
      warnings: $warnings,
      ci_entrypoint_deleted: $ci_entrypoint_deleted,
      config_lock_deleted: $config_lock_deleted,
      unsupported_parser_deletions: $unsupported_parser_deletions
    }'

  /bin/rm -f "$deleted_tmp" "$ci_tmp" "$config_tmp" "$unsupported_tmp"
}

shadow_verify_main() {
  local subcommand="${1:-}"
  shift || true

  case "$subcommand" in
    run)
      shadow_verify_run "$@"
      ;;
    loop)
      shadow_verify_loop "$@"
      ;;
    -h|--help|help)
      shadow_verify_usage
      ;;
    "")
      shadow_verify_usage
      exit 1
      ;;
    *)
      log_error "shadow_verify_main: unknown subcommand: $subcommand"
      shadow_verify_usage >&2
      exit 1
      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  shadow_verify_main "$@"
fi
