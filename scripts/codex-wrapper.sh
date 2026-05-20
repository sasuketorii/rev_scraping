#!/usr/bin/env bash
#
# codex-wrapper.sh - Canonical Codex CLI wrapper
#
# 目的:
#   Codex の role -> effort/search 契約を 1 か所に集約し、model / sandbox /
#   approval / profile / search override を fail-closed で遮断する。
#
# 使用方法:
#   cat prompt.md | ./scripts/codex-wrapper.sh --role coder --stdin > output.md
#   cat prompt.md | ./scripts/codex-wrapper.sh --role high-coder --stdin > output.md
#   ./scripts/codex-wrapper.sh --role reviewer --stdin < review_prompt.md > review.md
#   ./scripts/codex-wrapper.sh --role coder --manual-session --resume <session_id> "続きの指示"
#
set -euo pipefail

readonly FIXED_SANDBOX_MODE="workspace-write"
readonly FIXED_APPROVAL_POLICY="never"
readonly DEFAULT_ROLE="standard"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Vendoring 防止 guard
# shellcheck source=scripts/_canonical-guard.sh
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root codex-wrapper
# shellcheck source=scripts/_outbound-deny.sh
source "${SCRIPT_DIR}/_outbound-deny.sh"
rev_harness_assert_no_cursor_parent "codex-wrapper"

readonly SOURCE_POLICY_REL=".agent/registry/model_policy.json"
readonly RUNTIME_POLICY_REL=".agent/generated/codex_model_policy.runtime.json"
readonly SOURCE_POLICY_PATH="${PROJECT_ROOT}/${SOURCE_POLICY_REL}"
readonly RUNTIME_POLICY_PATH="${PROJECT_ROOT}/${RUNTIME_POLICY_REL}"

LOG_PREFIX="${CODEX_WRAPPER_LOG_PREFIX:-codex-wrapper}"
WRAPPER_HELP=false
MANUAL_SESSION=false
DRY_RUN=false
CMD_TYPE="exec"
SESSION_ID=""
RESUME_PROMPT=""
RESOLVED_ROLE=""
ROLE_SOURCE=""
ROLE_REASONING_EFFORT=""
ROLE_WEB_SEARCH=""
FIXED_MODEL=""
MINIMUM_ALLOWED_MODEL=""
EXPLICIT_ROLE_PROVIDED=false
SPECIALTY_SLUG=""
SPECIALTY_FILE=""
SPECIALTY_CANONICAL_ROLE=""
SPECIALTY_MANIFEST_HASH=""
AGENT_CORE_BIN=""
METRICS_ACTIVE=false
METRICS_EMITTED=false
METRICS_STDERR_CAPTURE=""
METRICS_CHILD_PID=""
METRICS_EXITING_FROM_SIGNAL=false
METRICS_STARTED_MS=""
METRICS_TIMESTAMP=""
METRICS_DELEGATION_ID=""
SPECIALTY_STATUS="none"

REMAINING_ARGS=()
FILTERED_ARGS=()
HAS_STDIN_FLAG=false

log_info() {
  echo "[${LOG_PREFIX}] INFO: $*" >&2
}

log_warn() {
  echo "[${LOG_PREFIX}] WARN: $*" >&2
}

log_error() {
  echo "[${LOG_PREFIX}] ERROR: $*" >&2
}

log_fail() {
  echo "[${LOG_PREFIX}] FAIL: $*" >&2
}

die() {
  log_error "$*"
  exit 1
}

now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
  else
    printf '%s000\n' "$(date -u +%s)"
  fi
}

generate_delegation_id() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    printf '%s-%s\n' "$(date -u +%s)" "$$"
  fi
}

init_metrics_context() {
  [[ -n "${METRICS_STARTED_MS}" ]] && return 0
  METRICS_STARTED_MS="$(now_ms)"
  METRICS_TIMESTAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  METRICS_DELEGATION_ID="$(generate_delegation_id)"
}

json_number_or_null() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf 'null\n'
  fi
}

parse_token_metrics() {
  local stderr_file="$1"
  local tokens=()
  local token=""
  local tokens_in="null"
  local tokens_out="null"
  local total_tokens="null"

  if [[ -f "$stderr_file" ]]; then
    while IFS= read -r token; do
      [[ -n "$token" ]] || continue
      tokens+=("$token")
    done < <(
      awk '
        BEGIN { capture = 0; seen = 0; lines_after = 0 }
        {
          original = $0
          lower = tolower($0)
          if (lower ~ /tokens used/) {
            capture = 1
            lines_after = 0
          } else if (capture) {
            lines_after++
          }
          if (capture) {
            gsub(/,/, "", original)
            gsub(/[^0-9]+/, " ", original)
            split(original, parts, " ")
            for (i in parts) {
              if (parts[i] ~ /^[0-9]+$/) {
                print parts[i]
                seen++
                if (seen >= 3) {
                  exit
                }
              }
            }
            if (lines_after >= 5) {
              exit
            }
          }
        }
      ' "$stderr_file"
    )
  fi

  case "${#tokens[@]}" in
    0)
      ;;
    1)
      tokens_in="${tokens[0]}"
      tokens_out="0"
      total_tokens="${tokens[0]}"
      ;;
    2)
      tokens_in="${tokens[0]}"
      tokens_out="${tokens[1]}"
      total_tokens="$((tokens[0] + tokens[1]))"
      ;;
    *)
      tokens_in="${tokens[0]}"
      tokens_out="${tokens[1]}"
      total_tokens="${tokens[2]}"
      ;;
  esac

  printf '%s\t%s\t%s\n' \
    "$(json_number_or_null "$tokens_in")" \
    "$(json_number_or_null "$tokens_out")" \
    "$(json_number_or_null "$total_tokens")"
}

emit_delegation_metric() {
  local exit_code="$1"
  local stderr_file="${2:-}"
  local completed_ms=""
  local duration_ms=""
  local tokens_in="null"
  local tokens_out="null"
  local total_tokens="null"
  local parsed_tokens=""
  local specialty_json="null"
  local canonical_role_json="null"
  local manifest_hash_json="null"
  local specialty_status="$SPECIALTY_STATUS"

  [[ "${REV_HARNESS_METRICS_DISABLE:-}" == "1" ]] && return 0
  [[ "${METRICS_ACTIVE}" == "true" ]] || return 0
  [[ "${METRICS_EMITTED}" == "false" ]] || return 0
  METRICS_EMITTED=true

  init_metrics_context
  completed_ms="$(now_ms)"
  duration_ms=$((completed_ms - METRICS_STARTED_MS))
  [[ "$duration_ms" -gt 0 ]] || duration_ms=1

  if [[ -n "$stderr_file" && -f "$stderr_file" ]]; then
    parsed_tokens="$(parse_token_metrics "$stderr_file")"
    IFS=$'\t' read -r tokens_in tokens_out total_tokens <<< "$parsed_tokens"
  fi

  if [[ -n "${SPECIALTY_SLUG}" && "${specialty_status}" == "validated" ]]; then
    specialty_json="$(jq -cn --arg value "${SPECIALTY_SLUG}" '$value')"
  fi
  if [[ -n "${SPECIALTY_CANONICAL_ROLE}" && "${specialty_status}" == "validated" ]]; then
    canonical_role_json="$(jq -cn --arg value "${SPECIALTY_CANONICAL_ROLE}" '$value')"
  fi
  if [[ -n "${SPECIALTY_MANIFEST_HASH}" && "${specialty_status}" == "validated" ]]; then
    manifest_hash_json="$(jq -cn --arg value "${SPECIALTY_MANIFEST_HASH}" '$value')"
  fi

  jq -cn \
    --argjson schema_version 1 \
    --arg delegation_id "${METRICS_DELEGATION_ID}" \
    --arg timestamp "${METRICS_TIMESTAMP}" \
    --arg wrapper_role "${RESOLVED_ROLE:-}" \
    --argjson specialty "${specialty_json}" \
    --argjson canonical_role "${canonical_role_json}" \
    --argjson manifest_hash "${manifest_hash_json}" \
    --argjson exit_code "${exit_code}" \
    --argjson duration_ms "${duration_ms}" \
    --argjson tokens_in "${tokens_in}" \
    --argjson tokens_out "${tokens_out}" \
    --argjson total_tokens "${total_tokens}" \
    --argjson dry_run "${DRY_RUN}" \
    --arg specialty_status "${specialty_status}" \
    '{
      schema_version: $schema_version,
      delegation_id: $delegation_id,
      timestamp: $timestamp,
      wrapper_role: $wrapper_role,
      specialty: $specialty,
      canonical_role: $canonical_role,
      manifest_hash: $manifest_hash,
      exit_code: $exit_code,
      duration_ms: $duration_ms,
      tokens_in: $tokens_in,
      tokens_out: $tokens_out,
      total_tokens: $total_tokens,
      dry_run: $dry_run,
      specialty_status: $specialty_status
    }' | sed 's/^/REV_HARNESS_DELEGATION_METRIC /' >&2
}

cleanup_metrics_capture() {
  if [[ -n "${METRICS_STDERR_CAPTURE}" && -f "${METRICS_STDERR_CAPTURE}" ]]; then
    /bin/rm -f "${METRICS_STDERR_CAPTURE}"
  fi
}

on_wrapper_exit() {
  local exit_code="$?"
  if [[ "${METRICS_EXITING_FROM_SIGNAL}" != "true" ]]; then
    emit_delegation_metric "$exit_code" "${METRICS_STDERR_CAPTURE:-}"
  fi
  cleanup_metrics_capture
}

forward_signal() {
  local signal_name="$1"
  METRICS_EXITING_FROM_SIGNAL=true
  if [[ -n "${METRICS_CHILD_PID}" ]] && kill -0 "${METRICS_CHILD_PID}" 2>/dev/null; then
    kill "-${signal_name}" "${METRICS_CHILD_PID}" 2>/dev/null || true
    wait "${METRICS_CHILD_PID}" 2>/dev/null || true
  fi
  local exit_code=128
  case "$signal_name" in
    HUP) exit_code=129 ;;
    INT) exit_code=130 ;;
    QUIT) exit_code=131 ;;
    TERM) exit_code=143 ;;
  esac
  emit_delegation_metric "$exit_code" "${METRICS_STDERR_CAPTURE:-}"
  cleanup_metrics_capture
  trap - "$signal_name"
  kill "-${signal_name}" "$$" 2>/dev/null || exit "$exit_code"
}

trap on_wrapper_exit EXIT
trap 'forward_signal HUP' HUP
trap 'forward_signal INT' INT
trap 'forward_signal QUIT' QUIT
trap 'forward_signal TERM' TERM

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

model_rank() {
  local model="$1"
  if [[ "$model" =~ ^gpt-([0-9]+)\.([0-9]+)([-.][A-Za-z0-9_-]+)?$ ]]; then
    printf '%s\n' "$((10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]}))"
    return 0
  fi
  return 1
}

load_runtime_policy() {
  if ! command -v jq >/dev/null 2>&1; then
    die "jq is required to validate ${RUNTIME_POLICY_REL}"
  fi

  [[ -f "${SOURCE_POLICY_PATH}" ]] || die "missing source model policy: ${SOURCE_POLICY_REL}"
  [[ -f "${RUNTIME_POLICY_PATH}" ]] || die "missing generated model policy: ${RUNTIME_POLICY_REL}"
  jq empty "${SOURCE_POLICY_PATH}" >/dev/null || die "invalid source model policy JSON: ${SOURCE_POLICY_REL}"
  jq empty "${RUNTIME_POLICY_PATH}" >/dev/null || die "invalid generated model policy JSON: ${RUNTIME_POLICY_REL}"

  local source_hash
  local runtime_source_hash
  local runtime_source_path
  local source_current
  local source_stable
  local source_minimum
  local source_fallback
  local runtime_stable
  local runtime_fallback
  local current_rank
  local minimum_rank

  source_hash="$(sha256_file "${SOURCE_POLICY_PATH}")"
  runtime_source_hash="$(jq -r '.source_policy_sha256 // empty' "${RUNTIME_POLICY_PATH}")"
  runtime_source_path="$(jq -r '.source_policy_path // empty' "${RUNTIME_POLICY_PATH}")"

  [[ "$(jq -r '.schema_version // empty' "${RUNTIME_POLICY_PATH}")" == "codex-model-runtime-policy/v1" ]] \
    || die "unsupported generated model policy schema"
  [[ "${runtime_source_path}" == "${SOURCE_POLICY_REL}" ]] \
    || die "generated model policy points to unexpected source: ${runtime_source_path}"
  [[ "${runtime_source_hash}" == "${source_hash}" ]] \
    || die "generated model policy is stale or hash-mismatched"

  source_current="$(jq -r '.current_model // empty' "${SOURCE_POLICY_PATH}")"
  source_stable="$(jq -r '.stable_default_model // empty' "${SOURCE_POLICY_PATH}")"
  source_minimum="$(jq -r '.minimum_allowed_model // empty' "${SOURCE_POLICY_PATH}")"
  source_fallback="$(jq -r '.runtime_fallback_below_minimum // empty' "${SOURCE_POLICY_PATH}")"
  FIXED_MODEL="$(jq -r '.current_model // empty' "${RUNTIME_POLICY_PATH}")"
  runtime_stable="$(jq -r '.stable_default_model // empty' "${RUNTIME_POLICY_PATH}")"
  MINIMUM_ALLOWED_MODEL="$(jq -r '.minimum_allowed_model // empty' "${RUNTIME_POLICY_PATH}")"
  runtime_fallback="$(jq -r '.runtime_fallback_below_minimum // empty' "${RUNTIME_POLICY_PATH}")"

  [[ -n "${FIXED_MODEL}" && "${FIXED_MODEL}" == "${source_current}" ]] \
    || die "generated current_model does not match source policy"
  [[ "${runtime_stable}" == "${source_stable}" ]] \
    || die "generated stable_default_model does not match source policy"
  [[ "${MINIMUM_ALLOWED_MODEL}" == "${source_minimum}" ]] \
    || die "generated minimum_allowed_model does not match source policy"
  [[ "${runtime_fallback}" == "forbidden" && "${source_fallback}" == "forbidden" ]] \
    || die "runtime fallback below minimum must be forbidden"

  current_rank="$(model_rank "${FIXED_MODEL}")" || die "unsupported current model format: ${FIXED_MODEL}"
  minimum_rank="$(model_rank "${MINIMUM_ALLOWED_MODEL}")" || die "unsupported minimum model format: ${MINIMUM_ALLOWED_MODEL}"
  [[ "${current_rank}" -ge "${minimum_rank}" ]] \
    || die "current model ${FIXED_MODEL} is below minimum allowed model ${MINIMUM_ALLOWED_MODEL}"

  jq -e '
    (.roles | type == "object")
    and (.roles.standard.model_reasoning_effort == "medium")
    and (.roles.standard.web_search == "cached")
    and (.roles.research.model_reasoning_effort == "high")
    and (.roles.research.web_search == "live")
    and (.roles.coder.model_reasoning_effort == "medium")
    and (.roles.coder.web_search == "cached")
    and (.roles["high-coder"].model_reasoning_effort == "high")
    and (.roles["high-coder"].web_search == "cached")
    and (.roles.reviewer.model_reasoning_effort == "xhigh")
    and (.roles.reviewer.web_search == "cached")
    and (.routing_lanes.initial_execplan_design.model_reasoning_effort == "xhigh")
    and (.routing_lanes.initial_execplan_design.web_search == "cached")
    and (.blocked_overrides.config_keys | index("model"))
    and (.blocked_overrides.config_keys | index("model_reasoning_effort"))
    and (.blocked_overrides.config_keys | index("features.multi_agent_v2"))
    and (.blocked_overrides.config_keys | index("agents.max_threads"))
    and (.blocked_overrides.feature_flags | index("multi_agent_v2"))
    and (.blocked_overrides.feature_flags | index("multi_agent"))
  ' "${RUNTIME_POLICY_PATH}" >/dev/null || die "generated model policy role/guard invariants failed"
}

show_help() {
  cat <<EOF
Usage: $(basename "$0") [--role ROLE] [--stdin] [codex args...]
       $(basename "$0") [--role ROLE] --manual-session --resume [SESSION_ID [PROMPT]] [codex args...]

Canonical Codex wrapper for this repository.

Role map:
  standard  -> medium + cached
  research  -> high + live
  coder     -> medium + cached
  high-coder -> high + cached
  reviewer  -> xhigh + cached

Notes:
  - Default role is ${DEFAULT_ROLE}.
  - Role can be supplied by --role, CODEX_WRAPPER_ROLE, or AGENT_ROLE.
  - Caller overrides for profile, model, reasoning effort, sandbox, approval,
    web-search, and workspace-expansion controls are blocked.
  - Normal harness flow is non-interactive. Session continuation is manual-only
    and requires both --manual-session and a real TTY.
  - Legacy wrapper scripts are compatibility shims that exec this script.
  - Runtime stderr is caller-owned; harness callers must store it under a
    run-local stderr/ directory and keep only pointer metadata near outputs.
EOF
}

resolve_role() {
  local explicit_role="$1"
  local shim_role="${CODEX_WRAPPER_ROLE:-}"
  local agent_role="${AGENT_ROLE:-}"
  local candidate=""
  local source=""

  if [[ -n "${explicit_role}" ]]; then
    candidate="${explicit_role}"
    source="--role"
  elif [[ -n "${shim_role}" ]]; then
    candidate="${shim_role}"
    source="CODEX_WRAPPER_ROLE"
  elif [[ -n "${agent_role}" ]]; then
    candidate="${agent_role}"
    source="AGENT_ROLE"
  else
    candidate="${DEFAULT_ROLE}"
    source="default"
  fi

  ROLE_REASONING_EFFORT="$(jq -r --arg role "${candidate}" '.roles[$role].model_reasoning_effort // empty' "${RUNTIME_POLICY_PATH}")"
  ROLE_WEB_SEARCH="$(jq -r --arg role "${candidate}" '.roles[$role].web_search // empty' "${RUNTIME_POLICY_PATH}")"

  if [[ -z "${ROLE_REASONING_EFFORT}" || -z "${ROLE_WEB_SEARCH}" ]]; then
    die "Unsupported role '${candidate}' from ${source}. Allowed roles: standard|research|coder|high-coder|reviewer"
  fi

  RESOLVED_ROLE="${candidate}"
  ROLE_SOURCE="${source}"
}

parse_wrapper_args() {
  local explicit_role=""

  REMAINING_ARGS=()
  CMD_TYPE="exec"
  SESSION_ID=""
  RESUME_PROMPT=""
  WRAPPER_HELP=false
  MANUAL_SESSION=false
  DRY_RUN=false
  EXPLICIT_ROLE_PROVIDED=false
  SPECIALTY_SLUG=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        WRAPPER_HELP=true
        shift
        ;;
      --role)
        shift
        if [[ $# -eq 0 ]]; then
          die "--role requires one of: standard|research|coder|high-coder|reviewer"
        fi
        if [[ -n "${explicit_role}" ]]; then
          die "--role can only be specified once"
        fi
        explicit_role="$1"
        EXPLICIT_ROLE_PROVIDED=true
        shift
        ;;
      --role=*)
        if [[ -n "${explicit_role}" ]]; then
          die "--role can only be specified once"
        fi
        explicit_role="${1#--role=}"
        EXPLICIT_ROLE_PROVIDED=true
        shift
        ;;
      --specialty)
        shift
        if [[ $# -eq 0 ]]; then
          die "--specialty requires slug"
        fi
        if [[ -n "${SPECIALTY_SLUG}" ]]; then
          die "--specialty can only be specified once"
        fi
        SPECIALTY_SLUG="$1"
        shift
        ;;
      --specialty=*)
        if [[ -n "${SPECIALTY_SLUG}" ]]; then
          die "--specialty can only be specified once"
        fi
        SPECIALTY_SLUG="${1#--specialty=}"
        if [[ -z "${SPECIALTY_SLUG}" ]]; then
          die "--specialty requires slug"
        fi
        shift
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --dry-run=*)
        die "${1%%=*} does not accept an attached value. Use --dry-run as a standalone flag."
        shift
        ;;
      --resume)
        CMD_TYPE="resume"
        shift
        if [[ $# -gt 0 && "$1" != --* ]]; then
          SESSION_ID="$1"
          shift
        fi
        if [[ $# -gt 0 && "$1" != --* ]]; then
          RESUME_PROMPT="$1"
          shift
        fi
        ;;
      --resume=*)
        CMD_TYPE="resume"
        SESSION_ID="${1#--resume=}"
        if [[ -z "${SESSION_ID}" ]]; then
          die "--resume requires session_id"
        fi
        shift
        if [[ $# -gt 0 && "$1" != --* ]]; then
          RESUME_PROMPT="$1"
          shift
        fi
        ;;
      --manual-session)
        MANUAL_SESSION=true
        shift
        ;;
      --manual-session=*)
        die "${1%%=*} does not accept an attached value. Use --manual-session as a standalone flag from a real TTY."
        ;;
      --continue-session|--continue|--fork-session)
        die "$1 is not supported by codex-wrapper. Orchestrated/automatic flows must start a fresh session."
        ;;
      --continue-session=*|--continue=*|--fork-session=*)
        die "${1%%=*} is not supported by codex-wrapper. Orchestrated/automatic flows must start a fresh session."
        ;;
      *)
        REMAINING_ARGS+=("$1")
        shift
        ;;
    esac
  done

  resolve_role "${explicit_role}"
}

ensure_specialty_session_mode_supported() {
  if [[ -n "${SPECIALTY_SLUG}" && ( "${CMD_TYPE}" == "resume" || "${MANUAL_SESSION}" == "true" ) ]]; then
    log_fail "--specialty cannot be combined with --resume / --manual-session (combination not supported in this version; specialty preamble injection on resume path is unverified and risks ARG_MAX overflow on large specialty files)"
    exit 1
  fi
}

specialty_fail() {
  local reason="$1"
  SPECIALTY_STATUS="fail-closed"
  log_info "Specialty: ${SPECIALTY_SLUG}"
  log_info "Status: fail-closed: ${reason}"
  return 1
}

resolve_specialty_file() {
  local canonical_path="${PROJECT_ROOT}/docs/roles/${SPECIALTY_CANONICAL_ROLE}/specialties/${SPECIALTY_SLUG}.md"
  if [[ -f "${canonical_path}" ]]; then
    SPECIALTY_FILE="${canonical_path}"
    return 0
  fi

  local matches=()
  local role
  for role in coder reviewer orchestrator; do
    local path="${PROJECT_ROOT}/docs/roles/${role}/specialties/${SPECIALTY_SLUG}.md"
    if [[ -f "${path}" ]]; then
      matches+=("${path}")
    fi
  done

  if [[ "${#matches[@]}" -eq 0 ]]; then
    specialty_fail "specialty file not found"
    return 1
  fi
  if [[ "${#matches[@]}" -gt 1 ]]; then
    specialty_fail "specialty file not found"
    return 1
  fi

  SPECIALTY_FILE="${matches[0]}"
}

extract_specialty_manifest_json() {
  local path="$1"
  awk '
    /^```json[[:space:]]*$/ { in_json = 1; next }
    /^```[[:space:]]*$/ {
      if (in_json) {
        exit
      }
    }
    in_json { print }
  ' "${path}"
}

ensure_agent_core_bin() {
  if [[ -n "${AGENT_CORE_BIN}" && -x "${AGENT_CORE_BIN}" ]]; then
    return 0
  fi

  AGENT_CORE_BIN="${PROJECT_ROOT}/harness-rust/target/debug/agent-core"
  if [[ ! -x "${AGENT_CORE_BIN}" ]]; then
    (cd "${PROJECT_ROOT}/harness-rust" && cargo build -q -p agent-core) \
      || { specialty_fail "manifest invalid"; return 1; }
  fi
}

compute_specialty_manifest_hash() {
  ensure_agent_core_bin

  local lint_json
  lint_json="$("${AGENT_CORE_BIN}" specialty lint --output-json /dev/stdout "${SPECIALTY_FILE}" 2>/dev/null)" \
    || { specialty_fail "manifest invalid"; return 1; }

  SPECIALTY_MANIFEST_HASH="$(printf '%s\n' "${lint_json}" | jq -r '.manifest_hash // empty')" \
    || { specialty_fail "manifest invalid"; return 1; }
  if [[ -z "${SPECIALTY_MANIFEST_HASH}" || "${SPECIALTY_MANIFEST_HASH}" == "null" ]]; then
    specialty_fail "manifest invalid"
    return 1
  fi
}

validate_specialty() {
  if [[ -z "${SPECIALTY_SLUG}" ]]; then
    log_info "Specialty: none"
    SPECIALTY_STATUS="none"
    return 0
  fi

  if [[ "${EXPLICIT_ROLE_PROVIDED}" != "true" ]]; then
    specialty_fail "--specialty requires --role"
    return 1
  fi

  case "${RESOLVED_ROLE}" in
    coder|high-coder)
      SPECIALTY_CANONICAL_ROLE="coder"
      ;;
    reviewer)
      SPECIALTY_CANONICAL_ROLE="reviewer"
      ;;
    standard|research)
      specialty_fail "standard/research runtime cannot use --specialty"
      return 1
      ;;
    *)
      specialty_fail "standard/research runtime cannot use --specialty"
      return 1
      ;;
  esac

  if [[ ! "${SPECIALTY_SLUG}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    specialty_fail "slug pattern"
    return 1
  fi

  resolve_specialty_file || return 1

  local manifest_json
  manifest_json="$(extract_specialty_manifest_json "${SPECIALTY_FILE}")"
  if [[ -z "${manifest_json}" ]] || ! printf '%s\n' "${manifest_json}" | jq empty >/dev/null 2>&1; then
    specialty_fail "manifest invalid"
    return 1
  fi

  local manifest_canonical_role
  manifest_canonical_role="$(printf '%s\n' "${manifest_json}" | jq -r '.canonical_role // empty')" \
    || { specialty_fail "manifest invalid"; return 1; }

  if [[ "${manifest_canonical_role}" == "orchestrator" ]] \
    && printf '%s\n' "${manifest_json}" | jq -e '(.allowed_runtime_roles // null) == []' >/dev/null 2>&1; then
    specialty_fail "orchestrator specialty must be invoked by orchestrator reading file directly"
    return 1
  fi

  if [[ "${manifest_canonical_role}" != "${SPECIALTY_CANONICAL_ROLE}" ]]; then
    specialty_fail "canonical_role mismatch"
    return 1
  fi

  if ! printf '%s\n' "${manifest_json}" \
    | jq -e --arg role "${RESOLVED_ROLE}" '(.allowed_runtime_roles // []) | index($role) != null' >/dev/null 2>&1; then
    specialty_fail "allowed_runtime_roles mismatch"
    return 1
  fi

  compute_specialty_manifest_hash || return 1

  log_info "Specialty: ${SPECIALTY_SLUG}"
  log_info "Canonical: ${SPECIALTY_CANONICAL_ROLE}"
  log_info "Runtime: ${RESOLVED_ROLE}"
  log_info "Manifest hash: ${SPECIALTY_MANIFEST_HASH}"
  log_info "Status: validated"
  SPECIALTY_STATUS="validated"
}

ensure_manual_resume_allowed() {
  if [[ "${CMD_TYPE}" != "resume" ]]; then
    return 0
  fi

  if [[ "${MANUAL_SESSION}" != "true" ]]; then
    die "Interactive session continuation is manual-only. Use --manual-session from a real TTY, or start a fresh wrapper run for orchestrated/automatic flows."
  fi

  if [[ "${HAS_STDIN_FLAG}" == "true" ]]; then
    die "--resume cannot be combined with --stdin. Manual recovery must be invoked directly from a TTY."
  fi

  if [[ ! -t 0 || ! -t 1 || ! -t 2 ]]; then
    die "--resume requires a real TTY when --manual-session is used"
  fi
}

is_blocked_config_override() {
  case "$1" in
    model=*|model_provider=*|model_reasoning_effort=*|sandbox_mode=*|approval_policy=*|web_search=*|web_search_cached=*|features.web_search_cached=*|features.web_search_request=*|features.multi_agent_v2=*|agents.max_threads=*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_blocked_feature_override() {
  case "$1" in
    web_search_cached|web_search_request|multi_agent_v2|multi_agent)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

filter_args() {
  FILTERED_ARGS=()
  HAS_STDIN_FLAG=false

  local skip_next_config=false
  local skip_next_option=false
  local skip_next_feature=false
  local blocked_option=""
  local feature_option=""

  for arg in "$@"; do
    if [[ "$arg" =~ ^(2?\>\>?|2\>\&1)$ ]]; then
      log_warn "Redirect operator detected as argument: '$arg'"
      log_warn "This likely means the caller forgot to wrap the command with 'bash -c \"...\"'"
      log_warn "Skipping this argument to prevent codex misinterpretation"
      continue
    fi

    if [[ "${skip_next_config}" == "true" ]]; then
      if is_blocked_config_override "${arg}"; then
        die "Blocked override attempt: -c ${arg}"
      else
        FILTERED_ARGS+=("-c" "${arg}")
      fi
      skip_next_config=false
      continue
    fi

    if [[ "${skip_next_option}" == "true" ]]; then
      log_warn "Blocked override attempt: ${blocked_option} ${arg}"
      skip_next_option=false
      blocked_option=""
      continue
    fi

    if [[ "${skip_next_feature}" == "true" ]]; then
      if is_blocked_feature_override "${arg}"; then
        die "Blocked override attempt: ${feature_option} ${arg}"
      else
        FILTERED_ARGS+=("${feature_option}" "${arg}")
      fi
      skip_next_feature=false
      feature_option=""
      continue
    fi

    case "${arg}" in
      -c|--config)
        skip_next_config=true
        continue
        ;;
      --config=*)
        local value="${arg#--config=}"
        if is_blocked_config_override "${value}"; then
          die "Blocked override attempt: ${arg}"
        else
          FILTERED_ARGS+=("${arg}")
        fi
        continue
        ;;
      --model|--sandbox|--ask-for-approval|--profile|--local-provider|--cd|--add-dir|-m|-s|-a|-p)
        blocked_option="${arg}"
        skip_next_option=true
        continue
        ;;
      --model=*|--sandbox=*|--ask-for-approval=*|--profile=*|--local-provider=*|--cd=*|--add-dir=*)
        log_warn "Blocked override attempt: ${arg}"
        continue
        ;;
      --search)
        log_warn "Blocked override attempt: ${arg}"
        continue
        ;;
      --enable|--disable)
        feature_option="${arg}"
        skip_next_feature=true
        continue
        ;;
      --enable=*|--disable=*)
        local feature="${arg#*=}"
        if is_blocked_feature_override "${feature}"; then
          die "Blocked override attempt: ${arg}"
        else
          FILTERED_ARGS+=("${arg}")
        fi
        continue
        ;;
      --full-auto|--dangerously-bypass-approvals-and-sandbox|--oss)
        log_warn "Blocked unsafe option: ${arg}"
        continue
        ;;
      --stdin)
        FILTERED_ARGS+=("-")
        HAS_STDIN_FLAG=true
        continue
        ;;
    esac

    FILTERED_ARGS+=("${arg}")
  done

  if [[ "${skip_next_config}" == "true" ]]; then
    log_warn "Dangling -c/--config option ignored"
  fi

  if [[ "${skip_next_option}" == "true" ]]; then
    log_warn "Dangling ${blocked_option} option ignored"
  fi

  if [[ "${skip_next_feature}" == "true" ]]; then
    log_warn "Dangling ${feature_option} option ignored"
  fi
}

run_subscription_auth_guard() {
  bash "${PROJECT_ROOT}/scripts/subscription-auth-guard.sh" check --provider codex >&2
}

run_codex_command() {
  METRICS_STDERR_CAPTURE="$(mktemp "${TMPDIR:-/tmp}/rev-harness-codex-stderr.XXXXXX")"
  # NOTE: synchronous execution (no &/wait) — backgrounding the child caused
  # stdin to be closed before codex could read it, producing
  # "No prompt provided via stdin." regressions on --stdin invocations.
  # Stderr is captured directly to a temp file instead of process substitution
  # so sandboxed shells do not need descriptor-backed path access. The captured
  # stderr is forwarded to the wrapper's own stderr after codex exits; callers
  # still see diagnostics and parse_token_metrics still has a stable file to
  # read, but stderr is not interleaved in real time.
  set +e
  "$@" 2> "${METRICS_STDERR_CAPTURE}"
  local status=$?
  set -e
  if [[ -s "${METRICS_STDERR_CAPTURE}" ]]; then
    cat "${METRICS_STDERR_CAPTURE}" >&2
  fi
  return "$status"
}

run_codex_with_specialty_preamble() {
  local exec_args=("${FILTERED_ARGS[@]}")
  if [[ "${HAS_STDIN_FLAG}" != "true" ]]; then
    exec_args+=("-")
  fi

  run_codex_command codex exec \
    --sandbox "${FIXED_SANDBOX_MODE}" \
    -c "approval_policy=${FIXED_APPROVAL_POLICY}" \
    -c "model=${FIXED_MODEL}" \
    -c "model_reasoning_effort=${ROLE_REASONING_EFFORT}" \
    -c "web_search=${ROLE_WEB_SEARCH}" \
    "${exec_args[@]}" < <(
    cat "${SPECIALTY_FILE}"
    printf '\n\n'
    cat
  )
}

main() {
  load_runtime_policy
  parse_wrapper_args "$@"

  if [[ "${WRAPPER_HELP}" == "true" ]]; then
    show_help
    exit 0
  fi

  filter_args "${REMAINING_ARGS[@]}"
  ensure_specialty_session_mode_supported
  ensure_manual_resume_allowed

  log_info "Role: ${RESOLVED_ROLE} (${ROLE_SOURCE})"
  log_info "Model: ${FIXED_MODEL}"
  log_info "Reasoning Effort: ${ROLE_REASONING_EFFORT}"
  log_info "Web Search: ${ROLE_WEB_SEARCH}"
  log_info "Sandbox Mode: ${FIXED_SANDBOX_MODE}"
  log_info "Approval Policy: ${FIXED_APPROVAL_POLICY}"
  METRICS_ACTIVE=true
  init_metrics_context
  validate_specialty || exit 1

  if [[ "${DRY_RUN}" == "true" ]]; then
    log_info "Dry Run: true"
    log_info "Command: ${CMD_TYPE}"
    exit 0
  fi

  run_subscription_auth_guard

  if ! command -v codex >/dev/null 2>&1; then
    die "codex CLI not found in PATH"
  fi

  if [[ "${CMD_TYPE}" == "resume" ]]; then
    if [[ -z "${SESSION_ID}" ]]; then
      die "--resume requires session_id"
    fi

    local resume_args=()
    for arg in "${FILTERED_ARGS[@]}"; do
      if [[ "${arg}" != "-" ]]; then
        resume_args+=("${arg}")
      fi
    done

    log_info "Command: resume (session: ${SESSION_ID})"
    local prompt_arg="${RESUME_PROMPT}"

    run_codex_command codex resume "${SESSION_ID}" "${prompt_arg}" \
      --sandbox "${FIXED_SANDBOX_MODE}" \
      --ask-for-approval "${FIXED_APPROVAL_POLICY}" \
      -c "model=${FIXED_MODEL}" \
      -c "model_reasoning_effort=${ROLE_REASONING_EFFORT}" \
      -c "web_search=${ROLE_WEB_SEARCH}" \
      "${resume_args[@]}"
    exit $?
  fi

  log_info "Command: exec"
  if [[ -n "${SPECIALTY_SLUG}" ]]; then
    run_codex_with_specialty_preamble
    exit $?
  fi

  run_codex_command codex exec \
    --sandbox "${FIXED_SANDBOX_MODE}" \
    -c "approval_policy=${FIXED_APPROVAL_POLICY}" \
    -c "model=${FIXED_MODEL}" \
    -c "model_reasoning_effort=${ROLE_REASONING_EFFORT}" \
    -c "web_search=${ROLE_WEB_SEARCH}" \
    "${FILTERED_ARGS[@]}"
  exit $?
}

main "$@"
