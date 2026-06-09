#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
POLICY_REL=".agent/registry/model_policy.json"
RUNTIME_REL=".agent/generated/codex_model_policy.runtime.json"
POLICY_PATH="$PROJECT_ROOT/$POLICY_REL"
RUNTIME_PATH="$PROJECT_ROOT/$RUNTIME_REL"
COMMON_REMAINING=()

die() {
  printf 'model-policy: ERROR: %s\n' "$*" >&2
  exit 1
}

info() {
  printf 'model-policy: %s\n' "$*"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

policy_jq() {
  jq "$@" "$POLICY_PATH"
}

set_policy_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    POLICY_PATH="$path"
    POLICY_REL="$path"
  else
    POLICY_PATH="$PROJECT_ROOT/$path"
    POLICY_REL="$path"
  fi
}

set_runtime_path() {
  local path="$1"
  if [[ "$path" = /* ]]; then
    RUNTIME_PATH="$path"
    RUNTIME_REL="$path"
  else
    RUNTIME_PATH="$PROJECT_ROOT/$path"
    RUNTIME_REL="$path"
  fi
}

parse_path_flags() {
  COMMON_REMAINING=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --policy-path)
        shift
        [[ $# -gt 0 ]] || die "missing --policy-path value"
        set_policy_path "$1"
        shift
        ;;
      --generated-path)
        shift
        [[ $# -gt 0 ]] || die "missing --generated-path value"
        set_runtime_path "$1"
        shift
        ;;
      *)
        COMMON_REMAINING+=("$1")
        shift
        ;;
    esac
  done
}

model_rank() {
  local model="$1"
  if [[ "$model" =~ ^gpt-([0-9]+)\.([0-9]+)([-.][A-Za-z0-9_-]+)?$ ]]; then
    printf '%s\n' "$((10#${BASH_REMATCH[1]} * 1000 + 10#${BASH_REMATCH[2]}))"
    return 0
  fi
  return 1
}

require_model_string() {
  local model="$1"
  local label="$2"
  [[ "$model" =~ ^gpt-[0-9]+\.[0-9]+([-.][A-Za-z0-9_-]+)?$ ]] || die "$label must be a gpt-X.Y model id: $model"
}

using_default_policy_paths() {
  [[ "$POLICY_PATH" == "$PROJECT_ROOT/.agent/registry/model_policy.json" && "$RUNTIME_PATH" == "$PROJECT_ROOT/.agent/generated/codex_model_policy.runtime.json" ]]
}

require_policy() {
  [[ -f "$POLICY_PATH" ]] || die "missing policy registry: $POLICY_REL"
  jq empty "$POLICY_PATH" >/dev/null || die "invalid JSON: $POLICY_REL"
}

validate_registry_schema() {
  require_policy

  jq -e \
    --arg current_model "$(jq -r '.current_model // empty' "$POLICY_PATH")" \
    --arg stable_model "$(jq -r '.stable_default_model // empty' "$POLICY_PATH")" \
    --arg minimum_model "$(jq -r '.minimum_allowed_model // empty' "$POLICY_PATH")" \
    --arg previous_model "$(jq -r '.previous_model // empty' "$POLICY_PATH")" \
    --arg candidate_model "$(jq -r '.candidate_model // empty' "$POLICY_PATH")" '
    .schema_version == "codex-model-policy/v1"
    and (.current_model | type == "string" and test("^gpt-[0-9]+\\.[0-9]+([-.][A-Za-z0-9_-]+)?$"))
    and (.stable_default_model | type == "string" and test("^gpt-[0-9]+\\.[0-9]+([-.][A-Za-z0-9_-]+)?$"))
    and (.minimum_allowed_model | type == "string" and test("^gpt-[0-9]+\\.[0-9]+([-.][A-Za-z0-9_-]+)?$"))
    and (.previous_model | type == "string" and test("^gpt-[0-9]+\\.[0-9]+([-.][A-Za-z0-9_-]+)?$"))
    and (.candidate_model == null or (.candidate_model | type == "string" and test("^gpt-[0-9]+\\.[0-9]+([-.][A-Za-z0-9_-]+)?$")))
    and .runtime_fallback_below_minimum == "forbidden"
    and (.model_order | type == "array" and length >= 2 and all(.[]; type == "string" and test("^gpt-[0-9]+\\.[0-9]+([-.][A-Za-z0-9_-]+)?$")))
    and ((.model_order | unique | length) == (.model_order | length))
    and (.model_order | index($current_model))
    and (.model_order | index($stable_model))
    and (.model_order | index($minimum_model))
    and (.model_order | index($previous_model))
    and (.candidate_model == null or (.model_order | index($candidate_model)))
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
    and (.native_agent_presets.model == .current_model or .native_agent_presets.model == .stable_default_model)
    and (.native_agent_presets.allowed_efforts | type == "array" and index("medium") and index("high") and index("xhigh") and all(.[]; . == "medium" or . == "high" or . == "xhigh"))
    and (.native_agent_presets.medium_effort_agents | type == "array")
    and (.native_agent_presets.high_effort_agents | type == "array")
    and (.native_agent_presets.xhigh_effort_agents | type == "array")
    and (.native_agent_presets.medium_effort_agents | index("coder"))
    and (.native_agent_presets.medium_effort_agents | index("consistency_reviewer"))
    and (.native_agent_presets.medium_effort_agents | index("performance_reviewer"))
    and (.native_agent_presets.medium_effort_agents | index("alternative_reviewer"))
    and (.native_agent_presets.high_effort_agents | index("stack_upgrade_researcher"))
    and (.native_agent_presets.xhigh_effort_agents | index("security_reviewer"))
    and (.native_agent_presets.xhigh_effort_agents | index("plan_reviewer"))
    and (.native_agent_presets.xhigh_effort_agents | index("system_planner"))
    and (.native_agent_presets.xhigh_effort_agents | index("stack_upgrade_reviewer"))
    and ([.native_agent_presets.medium_effort_agents[], .native_agent_presets.high_effort_agents[], .native_agent_presets.xhigh_effort_agents[]] as $agents | ($agents | unique | length) == ($agents | length))
    and (.native_agent_presets.lane_requirements.performance_reviewer.deterministic_benchmark_or_check_required == true)
    and (.native_agent_presets.lane_requirements.initial_execplan_design.model_reasoning_effort == "xhigh")
    and (.native_agent_presets.lane_requirements.initial_execplan_design.web_search == "cached")
    and (.native_agent_presets.lane_requirements.initial_execplan_design.native_agent_presets | index("system_planner"))
    and (.native_agent_presets.lane_requirements.initial_execplan_design.native_agent_presets | index("plan_reviewer"))
    and (.routing_lanes.default_standard_light_coder.model_reasoning_effort == "medium")
    and (.routing_lanes.normal_coder.model_reasoning_effort == "medium")
    and (.routing_lanes.complex_coder.model_reasoning_effort == "high")
    and (.routing_lanes.complex_coder.web_search == "cached")
    and (.routing_lanes.complex_coder.entrypoint == "scripts/codex-wrapper.sh --role high-coder")
    and (.routing_lanes.consistency_reviewer_normal.model_reasoning_effort == "medium")
    and (.routing_lanes.performance_reviewer_normal.model_reasoning_effort == "medium")
    and (.routing_lanes.performance_reviewer_normal.deterministic_benchmark_or_check_required == true)
    and (.routing_lanes.alternative_reviewer_normal.model_reasoning_effort == "medium")
    and (.routing_lanes.alternative_reviewer_comparative_high_risk.model_reasoning_effort == "high")
    and (.routing_lanes.security_reviewer.model_reasoning_effort == "xhigh")
    and (.routing_lanes.final_release_truth_wrapper_model_policy_reviewer.model_reasoning_effort == "xhigh")
    and (.routing_lanes.initial_execplan_design.model_reasoning_effort == "xhigh")
    and (.routing_lanes.initial_execplan_design.web_search == "cached")
    and (.routing_lanes.research.model_reasoning_effort == "high")
    and (.routing_lanes.research.web_search == "live")
    and (.official_sources | type == "array" and length > 0)
    and all(.official_sources[]; (.url | startswith("https://developers.openai.com/codex/") or startswith("https://platform.openai.com/") or startswith("https://openai.com/")))
    and any(.official_sources[]; (.verified_model_ids // []) | index($current_model))
    and (.official_source_rules.fixture_evidence == "forbidden")
    and (.generated_artifact.path | type == "string" and length > 0)
    and (.blocked_overrides.config_keys | index("features.multi_agent_v2"))
    and (.blocked_overrides.config_keys | index("agents.max_threads"))
    and (.blocked_overrides.feature_flags | index("multi_agent_v2"))
    and (.blocked_overrides.feature_flags | index("multi_agent"))
    and (.native_config_guards.required_features_multi_agent == true)
    and (.native_config_guards.forbidden_features | index("multi_agent_v2"))
    and (.native_config_guards.forbidden_config_keys | index("agents.max_threads"))
  ' "$POLICY_PATH" >/dev/null || die "policy registry schema or invariant check failed"

  local current stable minimum previous candidate current_rank stable_rank minimum_rank previous_rank candidate_rank
  current="$(jq -r '.current_model' "$POLICY_PATH")"
  stable="$(jq -r '.stable_default_model' "$POLICY_PATH")"
  minimum="$(jq -r '.minimum_allowed_model' "$POLICY_PATH")"
  previous="$(jq -r '.previous_model' "$POLICY_PATH")"
  candidate="$(jq -r '.candidate_model // empty' "$POLICY_PATH")"
  require_model_string "$current" current_model
  require_model_string "$stable" stable_default_model
  require_model_string "$minimum" minimum_allowed_model
  require_model_string "$previous" previous_model
  current_rank="$(model_rank "$current")" || die "unsupported current_model: $current"
  stable_rank="$(model_rank "$stable")" || die "unsupported stable_default_model: $stable"
  minimum_rank="$(model_rank "$minimum")" || die "unsupported minimum_allowed_model: $minimum"
  previous_rank="$(model_rank "$previous")" || die "unsupported previous_model: $previous"
  [[ "$current_rank" -ge "$minimum_rank" ]] || die "current_model must not be below minimum_allowed_model"
  [[ "$stable_rank" -ge "$minimum_rank" ]] || die "stable_default_model must not be below minimum_allowed_model"
  if [[ -n "$candidate" ]]; then
    require_model_string "$candidate" candidate_model
    candidate_rank="$(model_rank "$candidate")" || die "unsupported candidate_model: $candidate"
    [[ "$candidate_rank" -ge "$current_rank" ]] || die "candidate_model must not sort below current_model"
  fi
  jq -e '
    def rank: capture("^gpt-(?<major>[0-9]+)\\.(?<minor>[0-9]+)") | (.major | tonumber) * 1000 + (.minor | tonumber);
    .model_order as $order
    | all(range(1; $order|length); (($order[.] | rank) >= ($order[.-1] | rank)))
  ' "$POLICY_PATH" >/dev/null || die "model_order must be sorted in non-decreasing model order"
}

validate_runtime_artifact_if_present() {
  [[ -f "$RUNTIME_PATH" ]] || return 0
  jq empty "$RUNTIME_PATH" >/dev/null || die "invalid JSON: $RUNTIME_REL"

  local source_hash current stable minimum fallback
  source_hash="$(sha256_file "$POLICY_PATH")"
  current="$(jq -r '.current_model' "$POLICY_PATH")"
  stable="$(jq -r '.stable_default_model' "$POLICY_PATH")"
  minimum="$(jq -r '.minimum_allowed_model' "$POLICY_PATH")"
  fallback="$(jq -r '.runtime_fallback_below_minimum' "$POLICY_PATH")"
  jq -e \
    --arg hash "$source_hash" \
    --arg source "$POLICY_REL" \
    --arg current "$current" \
    --arg stable "$stable" \
    --arg minimum "$minimum" \
    --arg fallback "$fallback" \
    --argjson policy_roles "$(jq -c '.roles' "$POLICY_PATH")" \
    --argjson policy_native_config_guards "$(jq -c '.native_config_guards' "$POLICY_PATH")" '
    .schema_version == "codex-model-runtime-policy/v1"
    and .source_policy_path == $source
    and .source_policy_sha256 == $hash
    and .current_model == $current
    and .stable_default_model == $stable
    and .minimum_allowed_model == $minimum
    and .runtime_fallback_below_minimum == $fallback
    and .runtime_fallback_below_minimum == "forbidden"
    and (.roles.standard.model_reasoning_effort == "medium")
    and (.roles.research.web_search == "live")
    and (.roles.coder.model_reasoning_effort == "medium")
    and (.roles["high-coder"].model_reasoning_effort == "high")
    and (.roles["high-coder"].web_search == "cached")
    and (.roles.reviewer.model_reasoning_effort == "xhigh")
    and (.roles == $policy_roles)
    and (.routing_lanes.initial_execplan_design.model_reasoning_effort == "xhigh")
    and (.routing_lanes.initial_execplan_design.web_search == "cached")
    and (.native_config_guards == $policy_native_config_guards)
    and (.blocked_overrides.config_keys | index("model"))
    and (.blocked_overrides.config_keys | index("features.multi_agent_v2"))
    and (.blocked_overrides.config_keys | index("agents.max_threads"))
    and (.native_config_guards.forbidden_features | index("multi_agent_v2"))
  ' "$RUNTIME_PATH" >/dev/null || die "runtime artifact invariant check failed"
}

grep_value() {
  local pattern="$1"
  local file="$2"
  sed -n "s/^[[:space:]]*${pattern}[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

validate_codex_config() {
  local config="$PROJECT_ROOT/.codex/config.toml"
  local current stable native_model config_effort config_search medium_agents high_agents xhigh_agents agent
  [[ -f "$config" ]] || die "missing .codex/config.toml"

  current="$(jq -r '.current_model' "$POLICY_PATH")"
  stable="$(jq -r '.stable_default_model' "$POLICY_PATH")"
  native_model="$(jq -r '.native_agent_presets.model' "$POLICY_PATH")"
  config_effort="$(jq -r '.roles.coder.model_reasoning_effort' "$POLICY_PATH")"
  config_search="$(jq -r '.roles.coder.web_search' "$POLICY_PATH")"
  medium_agents="$(jq -r '.native_agent_presets.medium_effort_agents[]?' "$POLICY_PATH")"
  high_agents="$(jq -r '.native_agent_presets.high_effort_agents[]?' "$POLICY_PATH")"
  xhigh_agents="$(jq -r '.native_agent_presets.xhigh_effort_agents[]?' "$POLICY_PATH")"

  [[ "$current" == "$stable" ]] || die "live .codex validation requires current_model and stable_default_model to match"
  [[ "$(grep_value model "$config")" == "$stable" ]] || die ".codex/config.toml model must be $stable"
  [[ "$(grep_value model_reasoning_effort "$config")" == "$config_effort" ]] || die ".codex/config.toml model_reasoning_effort must be $config_effort"
  [[ "$(grep_value web_search "$config")" == "$config_search" ]] || die ".codex/config.toml web_search must be $config_search"
  grep -Eq '^[[:space:]]*multi_agent[[:space:]]*=[[:space:]]*true[[:space:]]*$' "$config" || die ".codex/config.toml must set features.multi_agent = true"
  ! grep -Eq '^[[:space:]]*multi_agent_v2[[:space:]]*=' "$config" || die ".codex/config.toml must not set features.multi_agent_v2"
  ! grep -Eq '(^|\.)max_threads[[:space:]]*=' "$config" || die ".codex/config.toml must not set agents.max_threads"

  local file name expected_effort
  for file in "$PROJECT_ROOT"/.codex/agents/*.toml; do
    [[ -f "$file" ]] || continue
    name="$(basename "$file" .toml)"
    if printf '%s\n' "$medium_agents" | grep -Fxq "$name"; then
      expected_effort="medium"
    elif printf '%s\n' "$high_agents" | grep -Fxq "$name"; then
      expected_effort="high"
    elif printf '%s\n' "$xhigh_agents" | grep -Fxq "$name"; then
      expected_effort="xhigh"
    else
      die ".codex/agents/$name.toml is not listed in native_agent_presets"
    fi
    [[ "$(grep_value model "$file")" == "$native_model" ]] || die ".codex/agents/$name.toml model must be $native_model"
    [[ "$(grep_value model_reasoning_effort "$file")" == "$expected_effort" ]] || die ".codex/agents/$name.toml model_reasoning_effort must be $expected_effort"
  done

  for agent in $medium_agents $high_agents $xhigh_agents; do
    grep -Eq "^\\[agents\\.${agent}\\]$" "$config" || die ".codex/config.toml missing agents.${agent} registration"
    [[ -f "$PROJECT_ROOT/.codex/agents/${agent}.toml" ]] || die "missing .codex/agents/${agent}.toml"
  done
}

validate_mirror_surfaces() {
  local current stable minimum
  current="$(jq -r '.current_model' "$POLICY_PATH")"
  stable="$(jq -r '.stable_default_model' "$POLICY_PATH")"
  minimum="$(jq -r '.minimum_allowed_model' "$POLICY_PATH")"

  grep -Fq "Current model: \`$current\`" "$PROJECT_ROOT/docs/generated/codex-model-policy.md" \
    || die "docs/generated/codex-model-policy.md current model mirror drift"
  grep -Fq "Stable default model: \`$stable\`" "$PROJECT_ROOT/docs/generated/codex-model-policy.md" \
    || die "docs/generated/codex-model-policy.md stable model mirror drift"
  grep -Fq "Minimum allowed model: \`$minimum\`" "$PROJECT_ROOT/docs/generated/codex-model-policy.md" \
    || die "docs/generated/codex-model-policy.md minimum model mirror drift"
  grep -Fq "model = \"$stable\"" "$PROJECT_ROOT/AGENTS.md" \
    || die "AGENTS.md config example model mirror drift"
  grep -Fq "$current" "$PROJECT_ROOT/.agent_rules/RULES.md" \
    || die ".agent_rules/RULES.md wrapper model mirror drift"
  grep -Fq ".agent/registry/model_policy.json" "$PROJECT_ROOT/docs/roles/reviewer.md" \
    || die "docs/roles/reviewer.md must reference model policy registry"
  grep -Fq 'high.sh -> high-coder' "$PROJECT_ROOT/CLAUDE.md" \
    || die "CLAUDE.md high.sh shim mapping mirror drift"
  ! grep -Fq 'high.sh -> coder' "$PROJECT_ROOT/CLAUDE.md" \
    || die "CLAUDE.md stale high.sh shim mapping"
  grep -Fq "contains_text \"model=$current\"" "$PROJECT_ROOT/test/integration/cross_agent_wrapper_matrix_test.sh" \
    || die "cross_agent_wrapper_matrix_test.sh model expectation mirror drift"
  ! grep -Eq 'readonly FIXED_MODEL="gpt-[0-9]+\.[0-9]+' "$PROJECT_ROOT/scripts/codex-wrapper.sh" \
    || die "scripts/codex-wrapper.sh must not own a hardcoded model"
}

generate_runtime_to_stdout() {
  require_policy
  local source_hash
  source_hash="$(sha256_file "$POLICY_PATH")"

  jq --sort-keys \
    --arg source_policy_path "$POLICY_REL" \
    --arg source_policy_sha256 "$source_hash" \
    '{
      blocked_overrides: .blocked_overrides,
      current_model: .current_model,
      generated_at: .generated_artifact.generated_at,
      generated_by: "scripts/model-policy.sh generate",
      minimum_allowed_model: .minimum_allowed_model,
      native_config_guards: .native_config_guards,
      roles: .roles,
      routing_lanes: .routing_lanes,
      runtime_fallback_below_minimum: .runtime_fallback_below_minimum,
      schema_version: "codex-model-runtime-policy/v1",
      source_policy_path: $source_policy_path,
      source_policy_sha256: $source_policy_sha256,
      stable_default_model: .stable_default_model
    }' "$POLICY_PATH"
}

cmd_generate() {
  parse_path_flags "$@"
  set -- "${COMMON_REMAINING[@]}"
  local check=false
  if [[ "${1:-}" == "--check" ]]; then
    check=true
    shift
  fi
  [[ $# -eq 0 ]] || die "usage: model-policy.sh generate [--check]"
  validate_registry_schema
  if using_default_policy_paths; then
    validate_codex_config
    validate_mirror_surfaces
  fi

  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/codex-model-policy.XXXXXX")"
  generate_runtime_to_stdout > "$tmp"

  if [[ "$check" == "true" ]]; then
    [[ -f "$RUNTIME_PATH" ]] || die "missing generated runtime artifact: $RUNTIME_REL"
    if ! diff -u "$RUNTIME_PATH" "$tmp"; then
      /bin/rm -f "$tmp"
      die "generated runtime artifact is stale; run scripts/model-policy.sh generate"
    fi
    /bin/rm -f "$tmp"
    info "PASS: generate --check"
    return 0
  fi

  mkdir -p "$(dirname "$RUNTIME_PATH")"
  mv "$tmp" "$RUNTIME_PATH"
  info "wrote $RUNTIME_REL"
}

cmd_validate() {
  parse_path_flags "$@"
  set -- "${COMMON_REMAINING[@]}"
  [[ $# -eq 0 ]] || die "usage: model-policy.sh validate [--policy-path PATH] [--generated-path PATH]"
  validate_registry_schema
  validate_runtime_artifact_if_present
  if using_default_policy_paths; then
    validate_codex_config
    validate_mirror_surfaces
  fi
  info "PASS: validate"
}

is_official_url() {
  case "$1" in
    https://developers.openai.com/codex/*|https://platform.openai.com/docs/*|https://openai.com/codex*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

official_content_has_candidate_context() {
  local model="$1"
  local content="$2"
  MODEL_POLICY_CANDIDATE_MODEL="$model" python3 -c '
import os
import re
import sys

model = os.environ["MODEL_POLICY_CANDIDATE_MODEL"]
escaped_model = re.escape(model)
text = re.sub(r"\s+", " ", sys.stdin.read())
positive_runtime = re.compile(r"Codex|API|CLI|SDK|app|IDE|model picker", re.I)
positive_availability = re.compile(
    r"\bavailable\b|availability|\bcompatible\b|compatibility|\bsupports\b|\bsupport\b|works with|"
    r"\bfrontier\s+model\b|\bmodel\s+for\b|"
    r"CLI\s*(?:&amp;|&)\s*SDK|app\s*(?:&amp;|&)\s*IDE",
    re.I,
)
negative_terms = (
    r"\bnot\s+available\b|\bisn.?t\s+available\b|\bnot\s+yet\b|"
    r"\bunavailable\b|\bnot\s+supported\b|\bdoes\s+not\s+support\b|"
    r"\bunsupported\b|\bno\s+access\b|\bnot\s+(?:a\s+)?model\s+for\b"
)
negative_near_candidate = re.compile(
    rf"(?:{escaped_model}.{{0,160}}(?:{negative_terms}))|(?:(?:{negative_terms}).{{0,160}}{escaped_model})",
    re.I,
)

start = 0
while True:
    idx = text.find(model, start)
    if idx < 0:
        sys.exit(1)
    window = text[max(0, idx - 500):idx + len(model) + 700]
    if positive_runtime.search(window) and positive_availability.search(window) and not negative_near_candidate.search(window):
        sys.exit(0)
    start = idx + len(model)
' <<< "$content"
}

fetch_official_content() {
  local url="$1"
  command -v curl >/dev/null 2>&1 || die "curl is required for official evidence verification"
  curl -fsSL --max-time 20 "$url"
}

write_policy_json() {
  local tmp
  tmp="$(mktemp "${TMPDIR:-/tmp}/codex-model-policy-write.XXXXXX")"
  cat > "$tmp"
  mv "$tmp" "$POLICY_PATH"
}

write_runtime_json() {
  mkdir -p "$(dirname "$RUNTIME_PATH")"
  generate_runtime_to_stdout > "$RUNTIME_PATH"
}

cmd_migrate() {
  parse_path_flags "$@"
  set -- "${COMMON_REMAINING[@]}"
  local dry_run=false
  local write=false
  local action=""
  local model=""
  local evidence_url=""
  local checked_at=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        dry_run=true
        shift
        ;;
      --write)
        write=true
        shift
        ;;
      candidate)
        action="candidate"
        shift
        ;;
      promote|promote-candidate)
        action="promote"
        shift
        ;;
      raise-minimum)
        action="raise-minimum"
        shift
        [[ $# -gt 0 && "$1" != --* ]] || die "raise-minimum requires model"
        model="$1"
        shift
        ;;
      rollback|rollback-to-previous)
        action="rollback"
        shift
        ;;
      --candidate|--model)
        if [[ "$1" == "--candidate" ]]; then
          action="candidate"
        fi
        shift
        [[ $# -gt 0 ]] || die "missing model value"
        model="$1"
        shift
        ;;
      --promote|--promote-candidate)
        action="promote"
        shift
        ;;
      --raise-minimum)
        action="raise-minimum"
        shift
        [[ $# -gt 0 && "$1" != --* ]] || die "--raise-minimum requires model"
        model="$1"
        shift
        ;;
      --rollback-to|--rollback-to-previous)
        action="rollback"
        shift
        if [[ "${1:-}" != "" && "${1:-}" != --* ]]; then
          model="$1"
          shift
        fi
        ;;
      --official-url|--official-evidence-url)
        shift
        [[ $# -gt 0 ]] || die "missing official evidence URL"
        evidence_url="$1"
        shift
        ;;
      --checked-at)
        shift
        [[ $# -gt 0 ]] || die "missing checked-at date"
        checked_at="$1"
        shift
        ;;
      --official-evidence-file)
        die "local official evidence files are forbidden; use --official-url"
        ;;
      *)
        die "unknown migrate argument: $1"
        ;;
    esac
  done

  [[ "$write" != "true" || "$dry_run" != "true" ]] || die "--write and --dry-run are mutually exclusive"
  if [[ "$write" != "true" ]]; then
    dry_run=true
  fi
  [[ -n "$action" ]] || die "migrate requires action: candidate|promote|raise-minimum|rollback"
  validate_registry_schema

  case "$action" in
    candidate)
      [[ -n "$model" ]] || die "candidate migration requires --candidate MODEL"
      [[ -n "$evidence_url" ]] || die "candidate migration requires --official-url"
      [[ "$checked_at" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "candidate migration requires --checked-at YYYY-MM-DD"
      is_official_url "$evidence_url" || die "candidate evidence URL is not an accepted OpenAI/Codex official docs URL: $evidence_url"
      local content
      content="$(fetch_official_content "$evidence_url")" || die "failed to fetch official evidence URL: $evidence_url"
      official_content_has_candidate_context "$model" "$content" || die "official evidence lacks exact candidate id plus availability/compatibility context: $model"
      local current_rank candidate_rank
      current_rank="$(model_rank "$(jq -r '.current_model' "$POLICY_PATH")")" || die "unsupported current model"
      candidate_rank="$(model_rank "$model")" || die "unsupported candidate model: $model"
      [[ "$candidate_rank" -ge "$current_rank" ]] || die "candidate_model must not sort below current_model"
      if [[ "$write" == "true" ]]; then
        jq \
          --arg model "$model" \
          --arg url "$evidence_url" \
          --arg checked_at "$checked_at" \
          '.candidate_model = $model
           | if (.model_order | index($model)) then . else .model_order += [$model] end
           | .official_sources += [{
               url: $url,
               checked_at: $checked_at,
               accepted_fact: ("Official evidence contains exact candidate model id " + $model + " with Codex/API availability or compatibility context."),
               verified_model_ids: [$model]
             }]' "$POLICY_PATH" | write_policy_json
        validate_registry_schema
        write_runtime_json
        info "wrote candidate migration for $model"
      else
        info "DRY-RUN: candidate $model would be registered from $evidence_url"
      fi
      ;;
    promote)
      model="$(jq -r '.candidate_model // empty' "$POLICY_PATH")"
      [[ -n "$model" ]] || die "promote-candidate requires candidate_model"
      if [[ "$write" == "true" ]]; then
        jq --arg model "$model" '
          .previous_model = .current_model
          | .current_model = $model
          | .stable_default_model = $model
          | .candidate_model = null
          | .native_agent_presets.model = $model
        ' "$POLICY_PATH" | write_policy_json
        validate_registry_schema
        write_runtime_json
        info "wrote promote-candidate migration for $model"
      else
        info "DRY-RUN: promote-candidate would promote $model"
      fi
      ;;
    raise-minimum)
      [[ -n "$model" ]] || die "raise-minimum requires model"
      jq -e --arg model "$model" '.model_order | index($model)' "$POLICY_PATH" >/dev/null || die "raise-minimum target is not in model_order: $model"
      local current_rank minimum_rank
      current_rank="$(model_rank "$(jq -r '.current_model' "$POLICY_PATH")")" || die "unsupported current model"
      minimum_rank="$(model_rank "$model")" || die "unsupported minimum model: $model"
      [[ "$current_rank" -ge "$minimum_rank" ]] || die "raise-minimum target is above current_model: $model"
      if [[ "$write" == "true" ]]; then
        jq --arg model "$model" '.minimum_allowed_model = $model' "$POLICY_PATH" | write_policy_json
        validate_registry_schema
        write_runtime_json
        info "wrote raise-minimum migration for $model"
      else
        info "DRY-RUN: raise-minimum would set $model"
      fi
      ;;
    rollback)
      if [[ -z "$model" ]]; then
        model="$(jq -r '.previous_model' "$POLICY_PATH")"
      fi
      jq -e --arg model "$model" '.model_order | index($model)' "$POLICY_PATH" >/dev/null || die "rollback target is not in model_order: $model"
      local target_rank min_rank
      target_rank="$(model_rank "$model")" || die "unsupported rollback model: $model"
      min_rank="$(model_rank "$(jq -r '.minimum_allowed_model' "$POLICY_PATH")")" || die "unsupported minimum model"
      [[ "$target_rank" -ge "$min_rank" ]] || die "rollback target is below minimum_allowed_model: $model"
      if [[ "$write" == "true" ]]; then
        jq --arg model "$model" '
          .previous_model = .current_model
          | .current_model = $model
          | .stable_default_model = $model
          | .candidate_model = null
          | .native_agent_presets.model = $model
        ' "$POLICY_PATH" | write_policy_json
        validate_registry_schema
        write_runtime_json
        info "wrote rollback migration to $model"
      else
        info "DRY-RUN: rollback would target $model"
      fi
      ;;
  esac
}

is_historical_path() {
  case "$1" in
    .agent/archive/*|.agent/active/prompts/*|.claude/tmp/*|*.log|log.txt)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_strict_path() {
  case "$1" in
    scripts/codex-wrapper.sh|.agent/generated/codex_model_policy.runtime.json|.codex/config.toml|.codex/agents/*.toml|setup/bootstrap.sh|test/integration/*.sh|AGENTS.md|.agent_rules/RULES.md|docs/roles/*.md|docs/manual/*.md|docs/generated/*.md)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

is_negative_or_policy_context() {
  printf '%s\n' "$1" | grep -Eiq 'example_forbidden_model|forbidden|blocked override|negative|expected FAIL|expected failure|fails|fail|previous_model|model_order|historical|fallback|not present|absent|official|minimum_allowed|runtime_fallback|candidate|dry-run|stale-ref|old model references|allow|WARN|BLOCK|ALLOW'
}

is_explicit_negative_example() {
  printf '%s\n' "$1" | grep -Eiq 'example_forbidden_model|ALLOW-NEGATIVE-EXAMPLE'
}

is_active_policy_example_context() {
  printf '%s\n' "$1" | grep -Eiq 'example_forbidden_model|expected FAIL|expected failure|Future-only|ALLOW-NEGATIVE-EXAMPLE'
}

is_active_imperative_line() {
  local text="$1"
  local scan_text="${text//dry-run/}"
  line_has_stale_model "$text" || return 1
  printf '%s\n' "$scan_text" | grep -Eiq 'codex[[:space:]]+-m[[:space:]]+gpt-5\.[0-6]([.-][A-Za-z0-9_-]+)?|(^|[^[:alnum:]_])model[[:space:]]*=[[:space:]]*"?gpt-5\.[0-6]([.-][A-Za-z0-9_-]+)?|(^|[^[:alnum:]_])(use|using|run|invoke|start|spawn)([^[:alnum:]_][^[:cntrl:]]{0,80})?gpt-5\.[0-6]([.-][A-Za-z0-9_-]+)?|(^|[^[:alnum:]_])(固定|使用|実行)([^[:alnum:]_][^[:cntrl:]]{0,80})?gpt-5\.[0-6]([.-][A-Za-z0-9_-]+)?'
}

line_has_stale_model() {
  local text="$1"
  local current
  local token
  current="$(jq -r '.current_model' "$POLICY_PATH")"
  while IFS= read -r token; do
    [[ -n "$token" ]] || continue
    [[ "$token" == "$current" ]] && continue
    return 0
  done < <(printf '%s\n' "$text" | grep -Eo 'gpt-5\.[0-6]([.-][A-Za-z0-9_-]+)?' || true)
  return 1
}

classify_ref() {
  local path="$1"
  local line="$2"
  local text="$3"

  if is_historical_path "$path"; then
    printf 'ALLOW-HISTORICAL\t%s\t%s\t%s\n' "$path" "$line" "$text"
    return 0
  fi

  if [[ "$path" == .agent/active/* ]]; then
    if is_active_policy_example_context "$text"; then
      printf 'ALLOW-NEGATIVE-EXAMPLE\t%s\t%s\t%s\n' "$path" "$line" "$text"
      return 0
    fi
    if is_active_imperative_line "$text"; then
      printf 'BLOCK\t%s\t%s\t%s\n' "$path" "$line" "$text"
      return 0
    fi
    printf 'WARN\t%s\t%s\t%s\n' "$path" "$line" "$text"
    return 0
  fi

  if is_strict_path "$path"; then
    if is_explicit_negative_example "$text"; then
      printf 'ALLOW-NEGATIVE-EXAMPLE\t%s\t%s\t%s\n' "$path" "$line" "$text"
      return 0
    fi
    printf 'BLOCK\t%s\t%s\t%s\n' "$path" "$line" "$text"
    return 0
  fi

  if is_negative_or_policy_context "$text"; then
    printf 'ALLOW-NEGATIVE-EXAMPLE\t%s\t%s\t%s\n' "$path" "$line" "$text"
    return 0
  fi

  printf 'WARN\t%s\t%s\t%s\n' "$path" "$line" "$text"
}

cmd_stale_refs() {
  parse_path_flags "$@"
  set -- "${COMMON_REMAINING[@]}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --strict|--forbid-imperative-model)
        shift
        if [[ "${1:-}" =~ ^gpt- ]]; then
          shift
        fi
        ;;
      *)
        die "unknown stale-refs argument: $1"
        ;;
    esac
  done
  local scan_root="${MODEL_POLICY_SCAN_ROOT:-$PROJECT_ROOT}"
  local output=""
  local block_count=0
  local rel file
  local files=()

  require_policy

  if [[ "$scan_root" == "$PROJECT_ROOT" ]] && git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    while IFS= read -r rel; do
      [[ -n "$rel" ]] || continue
      files+=("$PROJECT_ROOT/$rel")
    done < <(
      {
        git -C "$PROJECT_ROOT" ls-files
        git -C "$PROJECT_ROOT" ls-files --others --exclude-standard
      } | sort -u
    )
  else
    while IFS= read -r -d '' file; do
      files+=("$file")
    done < <(find "$scan_root" -type f -not -path '*/.git/*' -print0)
  fi

  for file in "${files[@]}"; do
    [[ -f "$file" ]] || continue
    rel="${file#"$scan_root"/}"
    case "$rel" in
      .git/*|.claude/tmp/harness-release-gate/*)
        continue
        ;;
    esac
    while IFS=: read -r line text; do
      [[ -n "${line:-}" ]] || continue
      if line_has_stale_model "$text"; then
        output+="$(classify_ref "$rel" "$line" "$text")"$'\n'
      fi
    done < <(grep -nE 'gpt-5\.[0-6]([.-][A-Za-z0-9_-]+)?' "$file" 2>/dev/null || true)
  done

  if [[ -n "$output" ]]; then
    printf '%s' "$output"
    block_count="$(printf '%s' "$output" | awk -F '\t' '$1 == "BLOCK" { count++ } END { print count + 0 }')"
  fi

  if [[ "$block_count" -gt 0 ]]; then
    die "stale refs found BLOCK classifications: $block_count"
  fi

  info "PASS: stale-refs"
}

usage() {
  cat <<'EOF'
Usage: scripts/model-policy.sh <command>

Commands:
  validate [--policy-path PATH] [--generated-path PATH]
  generate [--check] [--policy-path PATH] [--generated-path PATH]
  stale-refs [--strict] [--forbid-imperative-model MODEL] [--policy-path PATH]
  migrate --dry-run --candidate MODEL --official-url URL --checked-at YYYY-MM-DD [--policy-path PATH] [--generated-path PATH]
  migrate --write --candidate MODEL --official-url URL --checked-at YYYY-MM-DD [--policy-path PATH] [--generated-path PATH]
  migrate [--dry-run|--write] --promote-candidate [--policy-path PATH] [--generated-path PATH]
  migrate [--dry-run|--write] --raise-minimum MODEL [--policy-path PATH] [--generated-path PATH]
  migrate [--dry-run|--write] --rollback-to-previous [MODEL] [--policy-path PATH] [--generated-path PATH]

Notes:
  - Migration defaults to dry-run unless --write is supplied.
  - Candidate evidence must be fetched from an accepted OpenAI/Codex official docs URL.
  - Local evidence files and ambiguous URLs are rejected.
EOF
}

main() {
  require_cmd jq
  local cmd="${1:-}"
  [[ -n "$cmd" ]] || { usage; exit 2; }
  shift

  case "$cmd" in
    validate) cmd_validate "$@" ;;
    generate) cmd_generate "$@" ;;
    migrate) cmd_migrate "$@" ;;
    stale-refs) cmd_stale_refs "$@" ;;
    -h|--help|help) usage ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
