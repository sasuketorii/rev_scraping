#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASH_BIN="${HARNESS_RELEASE_GATE_BASH:-/bin/bash}"
CANONICAL_OUT_ROOT="$PROJECT_ROOT/.claude/tmp/harness-release-gate"
OUT_ROOT="${HARNESS_RELEASE_GATE_OUT_ROOT:-$PROJECT_ROOT/.claude/tmp/harness-release-gate}"
RELEASE_GATE_TIER="full"
RELEASE_GATE_DRY_RUN="NO"
RELEASE_GATE_METRICS_SMOKE_ONLY="NO"
QUEUE_RUNTIME_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_QUEUE_RUNTIME_TIMEOUT_SECS:-240}"
COMMON_TASK_CONTRACT_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_COMMON_TASK_CONTRACT_TIMEOUT_SECS:-180}"
PROJECT_ID_CONTRACT_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_PROJECT_ID_CONTRACT_TIMEOUT_SECS:-300}"
ORCHESTRATION_PACKET_VALIDATOR_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_ORCHESTRATION_PACKET_VALIDATOR_TIMEOUT_SECS:-180}"
AUTO_ORCHESTRATE_PACKET_PREFLIGHT_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_AUTO_ORCHESTRATE_PACKET_PREFLIGHT_TIMEOUT_SECS:-180}"
CROSS_FAMILY_ARTIFACT_SMOKE_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_CROSS_FAMILY_ARTIFACT_SMOKE_TIMEOUT_SECS:-180}"
CROSS_FAMILY_LIVE_SMOKE_PREFLIGHT_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_CROSS_FAMILY_LIVE_SMOKE_PREFLIGHT_TIMEOUT_SECS:-180}"
CROSS_FAMILY_LIVE_ARTIFACT_SMOKE_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_CROSS_FAMILY_LIVE_ARTIFACT_SMOKE_TIMEOUT_SECS:-180}"
REV_HARNESS_JANITOR_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_JANITOR_TIMEOUT_SECS:-180}"
STEP_TIMEOUT_SECS="${HARNESS_RELEASE_GATE_STEP_TIMEOUT_SECS:-300}"

release_gate_die() {
  printf 'harness_release_gate: %s\n' "$*" >&2
  exit 1
}

usage() {
  printf '%s\n' \
    'Usage: bash test/integration/harness_release_gate.sh [--tier quick|local|full] [--dry-run]' \
    '' \
    'Tiers:' \
    '  quick  Delegate to scripts/harness-doctor.sh --quick before release-gate artifact initialization.' \
    '  local  Run the focused local release-gate subset.' \
    '  full   Run the full release gate. This is the default and preserves no-argument behavior.' \
    '' \
    'Options:' \
    '  --dry-run  Print the command or step plan without creating release-gate artifacts.'
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --tier)
        [[ "$#" -ge 2 ]] || release_gate_die "--tier requires quick, local, or full"
        RELEASE_GATE_TIER="$2"
        shift 2
        ;;
      --tier=*)
        RELEASE_GATE_TIER="${1#--tier=}"
        shift
        ;;
      --dry-run)
        RELEASE_GATE_DRY_RUN="YES"
        shift
        ;;
      --metrics-smoke)
        RELEASE_GATE_METRICS_SMOKE_ONLY="YES"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        release_gate_die "unknown argument: $1"
        ;;
    esac
  done

  case "$RELEASE_GATE_TIER" in
    quick|local|full) ;;
    *) release_gate_die "invalid --tier: $RELEASE_GATE_TIER" ;;
  esac
}

dispatch_quick_tier() {
  local doctor_path="${HARNESS_RELEASE_GATE_DOCTOR:-$PROJECT_ROOT/scripts/harness-doctor.sh}"
  local doctor_rel=""

  case "$doctor_path" in
    "$PROJECT_ROOT"/*) doctor_rel="${doctor_path#"$PROJECT_ROOT"/}" ;;
    *) doctor_rel="$doctor_path" ;;
  esac

  if [[ "$RELEASE_GATE_DRY_RUN" == "YES" ]]; then
    printf 'DRY-RUN: tier=quick\n'
    printf 'DRY-RUN: would run delegation_metrics_smoke\n'
    printf 'DRY-RUN: would exec %s --quick\n' "$doctor_rel"
    if [[ -x "$doctor_path" && ! -d "$doctor_path" ]]; then
      printf 'DRY-RUN: doctor_status=executable\n'
    else
      printf 'DRY-RUN: doctor_status=missing-or-not-executable\n'
    fi
    return 0
  fi

  [[ -x "$doctor_path" && ! -d "$doctor_path" ]] \
    || release_gate_die "quick tier doctor is missing or not executable: $doctor_rel"

  run_delegation_metrics_smoke
  exec "$BASH_BIN" "$doctor_path" --quick
}

FULL_STEPS=(
  "harness_doctor_quick|\"$BASH_BIN\" test/integration/harness_doctor_quick_test.sh"
  "harness_release_gate_tiering|HARNESS_RELEASE_GATE_TIERING_NESTED=1 \"$BASH_BIN\" test/integration/harness_release_gate_tiering_test.sh"
  "delegation_metrics_smoke|\"$BASH_BIN\" test/integration/harness_release_gate.sh --metrics-smoke"
  "secret_guard|bash test/unit/test-secret-guard.sh"
  "rev_harness_task_classifier|bash test/integration/rev_harness_task_classifier_test.sh"
  "rev_harness_skill_routing|bash test/integration/rev_harness_skill_routing_test.sh"
  "rev_harness_dual_native|bash test/integration/rev_harness_dual_native_check_test.sh"
  "self_growth_proposal_cycle|bash test/integration/self_growth_proposal_cycle_test.sh"
  "rev_harness_static_asset_check|bash test/integration/rev_harness_static_asset_check_test.sh"
  "semantic_build|bash scripts/run-semantic-node-tool.sh npm --prefix scripts/semantic-mcp-server ci && bash scripts/run-semantic-node-tool.sh npm --prefix scripts/semantic-mcp-server run build"
  "semantic_test|bash scripts/run-semantic-node-tool.sh npm --prefix scripts/semantic-mcp-server test"
  "semantic_cli_contract_parity|bash test/integration/semantic_cli_contract_parity_test.sh"
  "semantic_backend_contract_parity|bash test/integration/semantic_backend_contract_parity_test.sh"
  "native_reviewer_surface_smoke|\"$BASH_BIN\" test/integration/native_reviewer_surface_smoke.sh"
  "codex_mcp_zombie_cleanup_contract|bash test/integration/codex_mcp_zombie_cleanup_contract_test.sh"
  "codex_mcp_zombie_cleanup_live|bash test/integration/codex_mcp_zombie_cleanup_live_test.sh"
  "hook_ingress_smoke|bash test/integration/hook_ingress_smoke.sh"
  "model_policy_validate|bash scripts/model-policy.sh validate"
  "model_policy_generate_check|bash scripts/model-policy.sh generate --check"
  "model_policy_stale_refs|bash scripts/model-policy.sh stale-refs"
  "model_policy_consistency|bash test/integration/model_policy_consistency_test.sh"
  "subscription_auth_guard|bash test/integration/subscription_auth_guard_test.sh"
  "rev_harness_lease_guard|bash test/integration/rev_harness_lease_guard_test.sh"
  "rev_harness_lease_lifecycle|bash test/integration/rev_harness_lease_lifecycle_test.sh"
  "cross_agent_wrapper_matrix|bash test/integration/cross_agent_wrapper_matrix_test.sh"
  "cross_family_artifact_smoke|bash test/integration/cross_family_artifact_smoke_test.sh"
  "cross_family_live_smoke_preflight|bash test/integration/cross_family_live_smoke_preflight_test.sh"
  "cross_family_live_artifact_smoke|bash test/integration/cross_family_live_artifact_smoke_test.sh"
  "cursor_rules_root|bash test/integration/root_instructions_test.sh"
  "cursor_rules_frontmatter|bash test/unit/test-cursor-rules-frontmatter.sh"
  "cursor_outbound_deny|bash test/unit/test-outbound-deny.sh"
  "cursor_skills_compliance|bash test/unit/test-cursor-skills-compliance.sh"
  "cursor_wrapper|bash test/unit/test-cursor-wrapper.sh"
  "rev_harness_janitor_inspect|bash scripts/rev-harness-janitor.sh inspect --json | jq -e '.schema_version == \"rev-harness-janitor/v1\" and .janitor_command == \"inspect\" and .delete_enabled == false and .archive_enabled == false and .apply_enabled == false' >/dev/null"
  "semantic_coordination|bash test/integration/semantic_coordination_test.sh"
  "semantic_registry_export_contract|bash test/integration/semantic_registry_export_contract_test.sh"
  "semantic_review_queue_runtime|bash test/integration/semantic_review_queue_runtime_test.sh"
  "context_capsule_help|bash .claude/commands/lib/context_capsule.sh --help"
  "shadow_verify_help|bash .claude/commands/lib/shadow_verify.sh --help"
  "benchmark_surface_contract|bash test/integration/harness_benchmark_contract_test.sh"
  "runtime_baseline_contract|bash test/integration/harness_runtime_baseline_test.sh"
  "common_task_contract_smoke|bash test/integration/common_task_contract_smoke.sh"
  "semantic_sync_freshness_contract|bash test/integration/semantic_sync_freshness_contract_test.sh"
  "semantic_project_id_contract|bash test/integration/semantic_project_id_contract_test.sh"
  "coder_engine_truth_test|bash test/integration/coder_engine_truth_test.sh"
  "policy_source_consistency|bash test/integration/policy_source_consistency_test.sh"
  "orchestration_packet_validator|bash test/integration/orchestration_packet_validator_test.sh"
  "auto_orchestrate_packet_preflight|bash test/integration/auto_orchestrate_packet_preflight_test.sh"
)

LOCAL_STEPS=(
  "harness_doctor_quick|\"$BASH_BIN\" test/integration/harness_doctor_quick_test.sh"
  "harness_release_gate_tiering|HARNESS_RELEASE_GATE_TIERING_NESTED=1 \"$BASH_BIN\" test/integration/harness_release_gate_tiering_test.sh"
  "delegation_metrics_smoke|\"$BASH_BIN\" test/integration/harness_release_gate.sh --metrics-smoke"
  "secret_guard|bash test/unit/test-secret-guard.sh"
  "rev_harness_task_classifier|bash test/integration/rev_harness_task_classifier_test.sh"
  "rev_harness_skill_routing|bash test/integration/rev_harness_skill_routing_test.sh"
  "rev_harness_dual_native|bash test/integration/rev_harness_dual_native_check_test.sh"
  "self_growth_proposal_cycle|bash test/integration/self_growth_proposal_cycle_test.sh"
  "rev_harness_static_asset_check|bash test/integration/rev_harness_static_asset_check_test.sh"
  "model_policy_validate|bash scripts/model-policy.sh validate"
  "model_policy_generate_check|bash scripts/model-policy.sh generate --check"
  "model_policy_consistency|bash test/integration/model_policy_consistency_test.sh"
  "subscription_auth_guard|bash test/integration/subscription_auth_guard_test.sh"
  "rev_harness_lease_guard|bash test/integration/rev_harness_lease_guard_test.sh"
  "rev_harness_lease_lifecycle|bash test/integration/rev_harness_lease_lifecycle_test.sh"
  "runtime_baseline_contract|bash test/integration/harness_runtime_baseline_test.sh"
  "cross_agent_wrapper_matrix|bash test/integration/cross_agent_wrapper_matrix_test.sh"
  "cross_family_artifact_smoke|bash test/integration/cross_family_artifact_smoke_test.sh"
  "cross_family_live_smoke_preflight|bash test/integration/cross_family_live_smoke_preflight_test.sh"
  "cross_family_live_artifact_smoke|bash test/integration/cross_family_live_artifact_smoke_test.sh"
  "cursor_rules_root|bash test/integration/root_instructions_test.sh"
  "cursor_rules_frontmatter|bash test/unit/test-cursor-rules-frontmatter.sh"
  "cursor_outbound_deny|bash test/unit/test-outbound-deny.sh"
  "cursor_skills_compliance|bash test/unit/test-cursor-skills-compliance.sh"
  "cursor_wrapper|bash test/unit/test-cursor-wrapper.sh"
  "rev_harness_janitor_inspect|bash scripts/rev-harness-janitor.sh inspect --json | jq -e '.schema_version == \"rev-harness-janitor/v1\" and .janitor_command == \"inspect\" and .delete_enabled == false and .archive_enabled == false and .apply_enabled == false' >/dev/null"
  "coder_engine_truth_test|bash test/integration/coder_engine_truth_test.sh"
  "policy_source_consistency|bash test/integration/policy_source_consistency_test.sh"
)

physical_out_root_path() {
  local path="$1"
  local parent=""
  local base=""
  local parent_real=""

  case "$path" in
    /*) ;;
    *) path="$PROJECT_ROOT/$path" ;;
  esac

  if [[ -d "$path" ]]; then
    (cd "$path" && pwd -P) || return 1
    return 0
  fi

  parent="$(dirname "$path")"
  base="$(basename "$path")"
  parent_real="$(cd "$parent" && pwd -P 2>/dev/null)" || return 1
  printf '%s/%s\n' "$parent_real" "$base"
}

is_canonical_out_root() {
  [[ "$(physical_out_root_path "$OUT_ROOT")" == "$(physical_out_root_path "$CANONICAL_OUT_ROOT")" ]]
}

apply_test_steps_override() {
  case "${HARNESS_RELEASE_GATE_TEST_STEPS:-}" in
    "")
      return 0
      ;;
    minimal)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=minimal requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("minimal_probe|:")
      LOCAL_STEPS=("minimal_probe|:")
      ;;
    semantic_project_id_contract)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=semantic_project_id_contract requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("semantic_project_id_contract|bash test/integration/semantic_project_id_contract_test.sh")
      LOCAL_STEPS=("semantic_project_id_contract|bash test/integration/semantic_project_id_contract_test.sh")
      ;;
    orchestration_packet_validator)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=orchestration_packet_validator requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("orchestration_packet_validator|bash test/integration/orchestration_packet_validator_test.sh")
      LOCAL_STEPS=("orchestration_packet_validator|bash test/integration/orchestration_packet_validator_test.sh")
      ;;
    orchestration_packet_validator_plus_preflight)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=orchestration_packet_validator_plus_preflight requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=(
        "orchestration_packet_validator|bash test/integration/orchestration_packet_validator_test.sh"
        "auto_orchestrate_packet_preflight|bash test/integration/auto_orchestrate_packet_preflight_test.sh"
      )
      LOCAL_STEPS=("${FULL_STEPS[@]}")
      ;;
    stall_probe)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=stall_probe requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("stall_probe|sleep 30")
      LOCAL_STEPS=("stall_probe|sleep 30")
      ;;
    auto_orchestrate_packet_preflight|post_orchestration_surface_a)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=${HARNESS_RELEASE_GATE_TEST_STEPS:-} requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("auto_orchestrate_packet_preflight|bash test/integration/auto_orchestrate_packet_preflight_test.sh")
      LOCAL_STEPS=("auto_orchestrate_packet_preflight|bash test/integration/auto_orchestrate_packet_preflight_test.sh")
      ;;
    cross_family_artifact_smoke)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=cross_family_artifact_smoke requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("cross_family_artifact_smoke|bash test/integration/cross_family_artifact_smoke_test.sh")
      LOCAL_STEPS=("cross_family_artifact_smoke|bash test/integration/cross_family_artifact_smoke_test.sh")
      ;;
    cross_family_live_smoke_preflight)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=cross_family_live_smoke_preflight requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("cross_family_live_smoke_preflight|bash test/integration/cross_family_live_smoke_preflight_test.sh")
      LOCAL_STEPS=("cross_family_live_smoke_preflight|bash test/integration/cross_family_live_smoke_preflight_test.sh")
      ;;
    cross_family_live_artifact_smoke)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=cross_family_live_artifact_smoke requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("cross_family_live_artifact_smoke|bash test/integration/cross_family_live_artifact_smoke_test.sh")
      LOCAL_STEPS=("cross_family_live_artifact_smoke|bash test/integration/cross_family_live_artifact_smoke_test.sh")
      ;;
    rev_harness_janitor_inspect)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=rev_harness_janitor_inspect requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("rev_harness_janitor_inspect|bash scripts/rev-harness-janitor.sh inspect --json | jq -e '.schema_version == \"rev-harness-janitor/v1\" and .janitor_command == \"inspect\" and .delete_enabled == false and .archive_enabled == false and .apply_enabled == false' >/dev/null")
      LOCAL_STEPS=("rev_harness_janitor_inspect|bash scripts/rev-harness-janitor.sh inspect --json | jq -e '.schema_version == \"rev-harness-janitor/v1\" and .janitor_command == \"inspect\" and .delete_enabled == false and .archive_enabled == false and .apply_enabled == false' >/dev/null")
      ;;
    rev_harness_task_classifier)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=rev_harness_task_classifier requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("rev_harness_task_classifier|bash test/integration/rev_harness_task_classifier_test.sh")
      LOCAL_STEPS=("rev_harness_task_classifier|bash test/integration/rev_harness_task_classifier_test.sh")
      ;;
    rev_harness_skill_routing)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=rev_harness_skill_routing requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("rev_harness_skill_routing|bash test/integration/rev_harness_skill_routing_test.sh")
      LOCAL_STEPS=("rev_harness_skill_routing|bash test/integration/rev_harness_skill_routing_test.sh")
      ;;
    rev_harness_static_asset_check)
      if is_canonical_out_root; then
        release_gate_die "HARNESS_RELEASE_GATE_TEST_STEPS=rev_harness_static_asset_check requires isolated non-canonical HARNESS_RELEASE_GATE_OUT_ROOT"
      fi
      FULL_STEPS=("rev_harness_static_asset_check|bash test/integration/rev_harness_static_asset_check_test.sh")
      LOCAL_STEPS=("rev_harness_static_asset_check|bash test/integration/rev_harness_static_asset_check_test.sh")
      ;;
    *)
      release_gate_die "invalid HARNESS_RELEASE_GATE_TEST_STEPS: ${HARNESS_RELEASE_GATE_TEST_STEPS:-}"
      ;;
  esac
}

selected_steps() {
  local step=""
  case "$RELEASE_GATE_TIER" in
    local)
      for step in "${LOCAL_STEPS[@]}"; do
        printf '%s\n' "$step"
      done
      ;;
    full)
      for step in "${FULL_STEPS[@]}"; do
        printf '%s\n' "$step"
      done
      ;;
    *)
      release_gate_die "no release-gate step list for tier: $RELEASE_GATE_TIER"
      ;;
  esac
}

dispatch_dry_run() {
  local slug=""
  local command=""

  printf 'DRY-RUN: tier=%s\n' "$RELEASE_GATE_TIER"
  while IFS='|' read -r slug command; do
    [[ -n "$slug" ]] || continue
    printf 'DRY-RUN: step=%s command=%s\n' "$slug" "$command"
  done < <(selected_steps)
}

run_delegation_metrics_smoke() {
  (
    set -euo pipefail

    local tmp_root=""
    local metrics_json=""
    local delta_json=""
    tmp_root="$(mktemp -d "${TMPDIR:-/tmp}/rev-harness-delegation-metrics-smoke.XXXXXX")"
    trap '/bin/rm -rf "$tmp_root"' EXIT

    unset OPENAI_API_KEY CODEX_API_KEY

    printf 'probe\n' \
      | PATH="$PROJECT_ROOT/test/fixtures/fake-codex:$PATH" \
        "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --stdin \
        >"$tmp_root/no-specialty.stdout" \
        2>"$tmp_root/no-specialty.stderr"

    printf 'probe\n' \
      | PATH="$PROJECT_ROOT/test/fixtures/fake-codex:$PATH" \
        "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --specialty refactor-safety-analyst --stdin \
        >"$tmp_root/specialty.stdout" \
        2>"$tmp_root/specialty.stderr"

    PATH="$PROJECT_ROOT/test/fixtures/fake-codex:$PATH" \
      "$PROJECT_ROOT/scripts/codex-wrapper.sh" --role coder --dry-run \
      >"$tmp_root/dry-run.stdout" \
      2>"$tmp_root/dry-run.stderr"

    metrics_json="$tmp_root/metrics.json"
    "$PROJECT_ROOT/scripts/collect-delegation-metrics.sh" \
      --session-id release-gate-smoke \
      --inputs "$tmp_root/no-specialty.stderr" "$tmp_root/specialty.stderr" "$tmp_root/dry-run.stderr" \
      --output "$metrics_json"

    jq -e '
      .schema_version == 1
      and .sample_count == 3
      and (.aggregates.median | type == "object")
      and (.aggregates.p75 | type == "object")
      and (.aggregates.total | type == "object")
    ' "$metrics_json" >/dev/null

    delta_json="$tmp_root/delta.json"
    "$PROJECT_ROOT/scripts/compute-completion-delta.sh" \
      --baseline "$metrics_json" \
      --post "$metrics_json" \
      --output "$delta_json"

    jq -e '.schema_version == 1 and .deltas.tokens_in_median_ratio == 1' "$delta_json" >/dev/null
  )
}

parse_args "$@"
[[ -x "$BASH_BIN" && ! -d "$BASH_BIN" ]] || release_gate_die "release-gate bash runtime not executable: $BASH_BIN"
apply_test_steps_override

if [[ "$RELEASE_GATE_METRICS_SMOKE_ONLY" == "YES" ]]; then
  run_delegation_metrics_smoke
  exit 0
fi

if [[ "$RELEASE_GATE_TIER" == "quick" ]]; then
  dispatch_quick_tier
  exit $?
fi

if [[ "$RELEASE_GATE_DRY_RUN" == "YES" ]]; then
  dispatch_dry_run
  exit 0
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)_$$"
RUN_DIR="$OUT_ROOT/runs/$RUN_ID"
CREATED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
STEP_TIMING_FILE="$RUN_DIR/step-timing.tsv"
STEP_EVENTS_FILE="$RUN_DIR/step-events.tsv"
TOTAL_STARTED_MS=""
TOTAL_ELAPSED_MS="0"

mkdir -p "$RUN_DIR/stderr" "$RUN_DIR/summary" "$OUT_ROOT/archive"
: > "$STEP_TIMING_FILE"
: > "$STEP_EVENTS_FILE"

PASS_COUNT=0
FAIL_COUNT=0

prefer_allowlisted_node_runtime() {
  local candidate=""
  for candidate in \
    "$HOME"/.local/share/mise/installs/node/*/bin \
    "$HOME"/.mise/installs/node/*/bin; do
    [[ -x "$candidate/node" && ! -L "$candidate/node" ]] || continue
    PATH="$candidate:$PATH"
    export PATH
    return 0
  done
  return 0
}

prefer_allowlisted_node_runtime

now_ms() {
  if command -v perl >/dev/null 2>&1; then
    perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
  else
    printf '%s000\n' "$(date -u +%s)"
  fi
}

TOTAL_STARTED_MS="$(now_ms)"

run_step() {
  local slug="$1"
  local command="$2"
  local timeout_secs="${3:-0}"
  local step_dir="$RUN_DIR/$slug"
  local status=0
  local started_ms=""
  local completed_ms=""
  local elapsed_ms=0
  local pid=""
  local pgid=""
  local command_runner=()

  mkdir -p "$step_dir"
  printf '%s\n' "$command" > "$step_dir/command.txt"
  printf '%s\n' "captured" > "$step_dir/output_mode.txt"
  : > "$step_dir/stdout.txt"
  : > "$step_dir/stderr.txt"

  if [[ "$timeout_secs" != "0" && ! "$timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
    release_gate_die "invalid timeout for $slug: $timeout_secs"
  fi

  started_ms="$(now_ms)"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$step_dir/started_at_utc.txt"
  printf '%s\n' "$started_ms" > "$step_dir/started_ms.txt"
  printf '%s\n' "RUNNING" > "$step_dir/status.txt"
  printf '%s\t%s\t%s\t%s\n' "$slug" "START" "$started_ms" "$timeout_secs" >> "$STEP_EVENTS_FILE"
  if [[ "$timeout_secs" == "0" ]]; then
    if (
      cd "$PROJECT_ROOT"
      eval "$command"
    ) >"$step_dir/stdout.txt" 2>"$step_dir/stderr.txt"; then
      PASS_COUNT=$((PASS_COUNT + 1))
      printf 'PASS: %s\n' "$slug"
    else
      status=$?
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf 'FAIL: %s (rc=%s)\n' "$slug" "$status"
    fi
  else
    command_runner=(
      "$BASH_BIN"
      -c
      'cd "$1" && eval "$2"'
      "$slug"
      "$PROJECT_ROOT"
      "$command"
    )
    if command -v perl >/dev/null 2>&1; then
      perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
        -- "${command_runner[@]}" >"$step_dir/stdout.txt" 2>"$step_dir/stderr.txt" &
    else
      "${command_runner[@]}" >"$step_dir/stdout.txt" 2>"$step_dir/stderr.txt" &
    fi
    pid=$!
    pgid=$pid
    printf '%s\n' "$pid" > "$step_dir/pid.txt"
    printf '%s\n' "$pgid" > "$step_dir/pgid.txt"

    local elapsed_secs=0
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$elapsed_secs" -ge "$timeout_secs" ]]; then
        status=124
        {
          printf 'timed_out_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf 'timeout_secs=%s\n' "$timeout_secs"
          printf 'pid=%s\n' "$pid"
          printf 'pgid=%s\n' "$pgid"
          printf 'command=%s\n' "$command"
        } > "$step_dir/timeout.txt"
        ps -ax -o pid,ppid,pgid,etime,stat,command > "$step_dir/process-snapshot-before-timeout-kill.log" 2>/dev/null || true
        kill -TERM -- -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL -- -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        break
      fi
      sleep 1
      elapsed_secs=$((elapsed_secs + 1))
    done

    if [[ "$status" -eq 0 ]]; then
      if wait "$pid"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS: %s\n' "$slug"
      else
        status=$?
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL: %s (rc=%s)\n' "$slug" "$status"
      fi
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf 'FAIL: %s (rc=%s timeout=%ss)\n' "$slug" "$status" "$timeout_secs"
    fi
  fi
  completed_ms="$(now_ms)"
  elapsed_ms=$((completed_ms - started_ms))
  [[ "$elapsed_ms" -ge 0 ]] || elapsed_ms=0

  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$step_dir/completed_at_utc.txt"
  printf '%s\n' "$completed_ms" > "$step_dir/completed_ms.txt"
  printf '%s\n' "$status" > "$step_dir/status.txt"
  printf '%s\n' "$elapsed_ms" > "$step_dir/elapsed_ms.txt"
  printf '%s\t%s\t%s\n' "$slug" "$status" "$elapsed_ms" >> "$STEP_TIMING_FILE"
  printf '%s\t%s\t%s\t%s\n' "$slug" "COMPLETE" "$status" "$elapsed_ms" >> "$STEP_EVENTS_FILE"
}

run_step_inherited_output() {
  local slug="$1"
  local command="$2"
  local timeout_secs="${3:-0}"
  local step_dir="$RUN_DIR/$slug"
  local status=0
  local started_ms=""
  local completed_ms=""
  local elapsed_ms=0
  local pid=""
  local pgid=""
  local command_runner=()

  mkdir -p "$step_dir"
  printf '%s\n' "$command" > "$step_dir/command.txt"
  printf '%s\n' "inherited" > "$step_dir/output_mode.txt"
  : > "$step_dir/stdout.txt"
  : > "$step_dir/stderr.txt"

  if [[ "$timeout_secs" != "0" && ! "$timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
    release_gate_die "invalid timeout for $slug: $timeout_secs"
  fi

  started_ms="$(now_ms)"
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$step_dir/started_at_utc.txt"
  printf '%s\n' "$started_ms" > "$step_dir/started_ms.txt"
  printf '%s\n' "RUNNING" > "$step_dir/status.txt"
  printf '%s\t%s\t%s\t%s\n' "$slug" "START" "$started_ms" "$timeout_secs" >> "$STEP_EVENTS_FILE"
  if [[ "$timeout_secs" == "0" ]]; then
    if (
      cd "$PROJECT_ROOT"
      eval "$command"
    ); then
      PASS_COUNT=$((PASS_COUNT + 1))
      printf 'PASS: %s\n' "$slug"
    else
      status=$?
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf 'FAIL: %s (rc=%s)\n' "$slug" "$status"
    fi
  else
    command_runner=(
      "$BASH_BIN"
      -c
      'cd "$1" && eval "$2"'
      "$slug"
      "$PROJECT_ROOT"
      "$command"
    )
    if command -v perl >/dev/null 2>&1; then
      perl -e 'use POSIX qw(setsid); setsid() or die "setsid: $!"; exec @ARGV or die "exec: $!";' \
        -- "${command_runner[@]}" &
    else
      "${command_runner[@]}" &
    fi
    pid=$!
    pgid=$pid
    printf '%s\n' "$pid" > "$step_dir/pid.txt"
    printf '%s\n' "$pgid" > "$step_dir/pgid.txt"

    local elapsed_secs=0
    while kill -0 "$pid" 2>/dev/null; do
      if [[ "$elapsed_secs" -ge "$timeout_secs" ]]; then
        status=124
        {
          printf 'timed_out_at_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
          printf 'timeout_secs=%s\n' "$timeout_secs"
          printf 'pid=%s\n' "$pid"
          printf 'pgid=%s\n' "$pgid"
          printf 'command=%s\n' "$command"
        } > "$step_dir/timeout.txt"
        ps -ax -o pid,ppid,pgid,etime,stat,command > "$step_dir/process-snapshot-before-timeout-kill.log" 2>/dev/null || true
        kill -TERM -- -"$pgid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
        sleep 2
        kill -KILL -- -"$pgid" 2>/dev/null || kill -KILL "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        break
      fi
      sleep 1
      elapsed_secs=$((elapsed_secs + 1))
    done

    if [[ "$status" -eq 0 ]]; then
      if wait "$pid"; then
        PASS_COUNT=$((PASS_COUNT + 1))
        printf 'PASS: %s\n' "$slug"
      else
        status=$?
        FAIL_COUNT=$((FAIL_COUNT + 1))
        printf 'FAIL: %s (rc=%s)\n' "$slug" "$status"
      fi
    else
      FAIL_COUNT=$((FAIL_COUNT + 1))
      printf 'FAIL: %s (rc=%s timeout=%ss)\n' "$slug" "$status" "$timeout_secs"
    fi
  fi
  completed_ms="$(now_ms)"
  elapsed_ms=$((completed_ms - started_ms))
  [[ "$elapsed_ms" -ge 0 ]] || elapsed_ms=0

  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$step_dir/completed_at_utc.txt"
  printf '%s\n' "$completed_ms" > "$step_dir/completed_ms.txt"
  printf '%s\n' "$status" > "$step_dir/status.txt"
  printf '%s\n' "$elapsed_ms" > "$step_dir/elapsed_ms.txt"
  printf '%s\t%s\t%s\n' "$slug" "$status" "$elapsed_ms" >> "$STEP_TIMING_FILE"
  printf '%s\t%s\t%s\t%s\n' "$slug" "COMPLETE" "$status" "$elapsed_ms" >> "$STEP_EVENTS_FILE"
}

cleanup_queue_runtime_test_processes() {
  local pid=""
  local patterns=(
    'bash( -x)? test/integration/semantic_review_queue_runtime_test.sh'
    'scripts/semantic-mcp-server/dist/cli.js queue enqueue --project-id queueruntime-'
  )

  for pattern in "${patterns[@]}"; do
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    done < <(({ ps -o pid=,command= -ax 2>/dev/null || true; } | awk -v pattern="$pattern" '$0 ~ pattern { print $1 }'))
  done
}

collect_inventory_metrics() {
  local current_inventory_file="$RUN_DIR/current_wrapper_inventory_wc.txt"
  local baseline_inventory_file="$PROJECT_ROOT/.claude/tmp/harness-benchmarks/20260403_phase0_baseline/inventory/wrapper_inventory_wc.txt"
  local current_total="unknown"
  local baseline_total="unknown"

  wc -l \
    "$PROJECT_ROOT/scripts/codex-wrapper.sh" \
    "$PROJECT_ROOT/scripts/codex-wrapper-medium.sh" \
    "$PROJECT_ROOT/scripts/codex-wrapper-high.sh" \
    "$PROJECT_ROOT/scripts/codex-wrapper-xhigh.sh" \
    "$PROJECT_ROOT/scripts/claude-wrapper.sh" \
    "$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh" \
    > "$current_inventory_file"

  current_total=$(awk '/ total$/ { print $1 }' "$current_inventory_file")

  if [[ -f "$baseline_inventory_file" ]]; then
    baseline_total=$(awk '/ total$/ { print $1 }' "$baseline_inventory_file")
  fi

  printf '%s\t%s\n' "$baseline_total" "$current_total" > "$RUN_DIR/wrapper_inventory_totals.tsv"
}

collect_coordinator_delta() {
  local diff_file="$RUN_DIR/coordinator_core_numstat.tsv"
  local add_total=0
  local del_total=0
  local net_total=0

  if git rev-parse --verify 460dd29^{commit} >/dev/null 2>&1; then
    git diff --numstat 460dd29 -- \
      .claude/commands/auto_orchestrate.sh \
      .claude/commands/lib/session.sh \
      .claude/commands/lib/state.sh \
      .claude/commands/lib/context_analysis.sh \
      .claude/commands/lib/context_capsule.sh \
      .claude/commands/lib/shadow_verify.sh \
      .claude/commands/lib/coder.sh \
      scripts/semantic-review-queue.sh \
      > "$diff_file"

    while IFS=$'\t' read -r add del _path; do
      [[ -n "${add:-}" && -n "${del:-}" ]] || continue
      add_total=$((add_total + add))
      del_total=$((del_total + del))
    done < "$diff_file"

    net_total=$((add_total - del_total))
  else
    : > "$diff_file"
  fi

  printf '%s\t%s\t%s\n' "$add_total" "$del_total" "$net_total" > "$RUN_DIR/coordinator_core_totals.tsv"
}

write_summary() {
  local baseline_total="unknown"
  local current_total="unknown"
  local coordinator_add="0"
  local coordinator_del="0"
  local coordinator_net="0"
  local timing_rows=""

  if [[ -f "$RUN_DIR/wrapper_inventory_totals.tsv" ]]; then
    read -r baseline_total current_total < "$RUN_DIR/wrapper_inventory_totals.tsv"
  fi
  if [[ -f "$RUN_DIR/coordinator_core_totals.tsv" ]]; then
    read -r coordinator_add coordinator_del coordinator_net < "$RUN_DIR/coordinator_core_totals.tsv"
  fi
  if [[ -f "$STEP_TIMING_FILE" ]]; then
    timing_rows="$(awk -F '\t' '{ printf "- `%s`: `status=%s elapsed_ms=%s`\n", $1, $2, $3 }' "$STEP_TIMING_FILE")"
  fi

  {
    printf '# Harness Release Gate\n\n'
    printf -- '- Run ID: `%s`\n' "$RUN_ID"
    printf -- '- Repo: `%s`\n' "$PROJECT_ROOT"
    printf -- '- Tier: `%s`\n' "$RELEASE_GATE_TIER"
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
      printf -- '- Result: `PASS`\n'
    else
      printf -- '- Result: `FAIL`\n'
    fi
    printf -- '- Step counts: `pass=%s fail=%s`\n' "$PASS_COUNT" "$FAIL_COUNT"
    printf -- '- Total elapsed ms: `%s`\n\n' "$TOTAL_ELAPSED_MS"
    printf '## Wrapper / Coordinator Inventory\n\n'
    printf -- '- Benchmark baseline total: `%s`\n' "$baseline_total"
    printf -- '- Current total: `%s`\n\n' "$current_total"
    printf '## Coordinator Shell Delta vs `460dd29`\n\n'
    printf -- '- Added lines: `%s`\n' "$coordinator_add"
    printf -- '- Deleted lines: `%s`\n' "$coordinator_del"
    printf -- '- Net delta: `%s`\n\n' "$coordinator_net"
    printf '## Step Artifacts\n\n'
    printf 'Each step directory contains:\n\n'
    printf -- '- `command.txt`\n'
    printf -- '- `stdout.txt`\n'
    printf -- '- `stderr.txt`\n'
    printf -- '- `started_at_utc.txt`\n'
    printf -- '- `started_ms.txt`\n'
    printf -- '- `status.txt`\n'
    printf -- '- `elapsed_ms.txt`\n'
    printf -- '- `timeout.txt` and `process-snapshot-before-timeout-kill.log` when a step times out\n\n'
    printf '## Step Timing\n\n'
    printf '%s\n' "${timing_rows:-none}"
  } > "$RUN_DIR/summary.md"
}

write_lifecycle_manifest() {
  local completed_at="$1"
  local result_state="active"
  local disposition="active-evidence"
  local latest_pointer="latest-failure"
  local run_rel="${RUN_DIR#"$PROJECT_ROOT"/}"
  local manifest_path="$RUN_DIR/artifact-lifecycle-manifest.json"
  local manifest_rel="${manifest_path#"$PROJECT_ROOT"/}"

  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    latest_pointer="latest-success"
  fi
  if [[ "$RELEASE_GATE_TIER" == "local" ]]; then
    if [[ "$FAIL_COUNT" -eq 0 ]]; then
      latest_pointer="latest-local-success"
    else
      latest_pointer="latest-local-failure"
    fi
  fi

  jq -n \
    --arg schema_version "artifact-lifecycle/v1" \
    --arg owner "script" \
    --arg producer "test/integration/harness_release_gate.sh" \
    --arg purpose "release gate evidence" \
    --arg authority "docs/manual/harness-release-gate.md" \
    --arg task_id "none" \
    --arg slice_id "release-gate" \
    --arg run_id "$RUN_ID" \
    --arg tier "$RELEASE_GATE_TIER" \
    --arg state "$result_state" \
    --arg disposition "$disposition" \
    --arg latest_pointer "$latest_pointer" \
    --arg pinned_baseline "none" \
    --arg run_disposable "NO" \
    --arg supersedes "none" \
    --arg superseded_by "none" \
    --arg ttl "none" \
    --arg archive_after "none" \
    --arg safe_delete_after "none" \
    --arg safe_delete_class "never" \
    --arg manifest_path "$manifest_rel" \
    --arg created_at "$CREATED_AT" \
    --arg completed_at "$completed_at" \
    --arg run_path "$run_rel" \
    '$ARGS.named' > "$manifest_path"
}

manifest_path_from_pointer() {
  local pointer_path="$1"
  local manifest_rel=""
  local manifest_path=""
  local out_root_real=""
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
  out_root_real="$(cd "$OUT_ROOT" && pwd -P 2>/dev/null)" || return 1
  manifest_parent_real="$(cd "$(dirname "$manifest_path")" && pwd -P 2>/dev/null)" || return 1
  manifest_real="$manifest_parent_real/$(basename "$manifest_path")"
  case "$manifest_real" in
    "$out_root_real"/runs/*/artifact-lifecycle-manifest.json) ;;
    *) return 1 ;;
  esac
  case "$manifest_path" in
    "$OUT_ROOT"/runs/*/artifact-lifecycle-manifest.json) ;;
    *) return 1 ;;
  esac
  printf '%s\n' "$manifest_path"
}

mark_manifest_superseded() {
  local manifest_path="$1"
  local tmp_path=""

  [[ "$manifest_path" != "$RUN_DIR/artifact-lifecycle-manifest.json" ]] || return 0
  [[ -f "$manifest_path" && ! -L "$manifest_path" ]] || return 0

  tmp_path="${manifest_path}.tmp"
  jq \
    --arg superseded_by "$RUN_ID" \
    '.state = "superseded"
     | .latest_pointer = "none"
     | .superseded_by = $superseded_by
     | .run_disposable = "YES"
     | .safe_delete_class = "archived-managed-run"' \
    "$manifest_path" > "$tmp_path"
  mv "$tmp_path" "$manifest_path"
}

retire_previous_result_pointer_manifest() {
  local pointer_path="$1"
  local manifest_path=""

  [[ ! -e "$pointer_path" && ! -L "$pointer_path" ]] && return 0
  manifest_path="$(manifest_path_from_pointer "$pointer_path")" \
    || release_gate_die "invalid lifecycle pointer manifest path: $pointer_path"
  mark_manifest_superseded "$manifest_path"
}

run_symlink_escape_selftest() {
  local saved_out_root="$OUT_ROOT"
  local saved_run_dir="$RUN_DIR"
  local saved_run_id="$RUN_ID"
  local self_root="$PROJECT_ROOT/.claude/tmp/harness-release-gate-symlink-selftest.$$"
  local attack_root=""
  local pointer_path=""
  local before_state=""
  local after_state=""

  attack_root="$(mktemp -d "${TMPDIR:-/tmp}/harness-release-gate-symlink-escape.XXXXXX")"
  mkdir -p "$self_root/runs" "$attack_root"
  ln -s "$attack_root" "$self_root/runs/evil-run"
  jq -n \
    --arg schema_version "artifact-lifecycle/v1" \
    --arg state "active" \
    --arg latest_pointer "latest-success" \
    --arg run_disposable "NO" \
    --arg safe_delete_class "never" \
    '{schema_version: $schema_version, state: $state, latest_pointer: $latest_pointer, run_disposable: $run_disposable, safe_delete_class: $safe_delete_class}' \
    > "$attack_root/artifact-lifecycle-manifest.json"
  before_state="$(jq -c '{state, latest_pointer, run_disposable, safe_delete_class}' "$attack_root/artifact-lifecycle-manifest.json")"
  pointer_path="$self_root/latest-success.json"
  jq -n \
    --arg schema_version "artifact-lifecycle/latest-pointer/v1" \
    --arg manifest_path "${self_root#"$PROJECT_ROOT"/}/runs/evil-run/artifact-lifecycle-manifest.json" \
    '{schema_version: $schema_version, manifest_path: $manifest_path}' \
    > "$pointer_path"

  OUT_ROOT="$self_root"
  RUN_ID="current-run"
  RUN_DIR="$self_root/runs/$RUN_ID"
  mkdir -p "$RUN_DIR"

  if (retire_previous_result_pointer_manifest "$pointer_path") >/dev/null 2>"$self_root/selftest.stderr"; then
    release_gate_die "symlinked release-gate pointer unexpectedly retired an external manifest"
  fi

  after_state="$(jq -c '{state, latest_pointer, run_disposable, safe_delete_class}' "$attack_root/artifact-lifecycle-manifest.json")"
  [[ "$after_state" == "$before_state" ]] \
    || release_gate_die "symlinked release-gate pointer mutated external manifest"

  OUT_ROOT="$saved_out_root"
  RUN_DIR="$saved_run_dir"
  RUN_ID="$saved_run_id"
  /bin/rm -rf "$saved_run_dir"
  /bin/rm -rf "$self_root" "$attack_root"
  printf 'PASS: harness_release_gate_symlink_escape_selftest\n'
}

if [[ "${HARNESS_RELEASE_GATE_SELFTEST:-}" == "symlink-escape" ]]; then
  run_symlink_escape_selftest
  exit 0
fi

write_latest_pointers() {
  local completed_at="$1"
  local result="FAIL"
  local run_rel="${RUN_DIR#"$PROJECT_ROOT"/}"
  local manifest_rel="${run_rel}/artifact-lifecycle-manifest.json"
  local summary_rel="${run_rel}/summary.md"
  local pointer_tmp="$RUN_DIR/latest-pointer.tmp.json"
  local latest_path="$OUT_ROOT/latest.json"
  local success_path="$OUT_ROOT/latest-success.json"
  local failure_path="$OUT_ROOT/latest-failure.json"

  if [[ "$RELEASE_GATE_TIER" == "local" ]]; then
    latest_path="$OUT_ROOT/latest-local.json"
    success_path="$OUT_ROOT/latest-local-success.json"
    failure_path="$OUT_ROOT/latest-local-failure.json"
  fi

  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    result="PASS"
  fi

  if [[ "$result" == "PASS" ]]; then
    retire_previous_result_pointer_manifest "$success_path"
  else
    retire_previous_result_pointer_manifest "$failure_path"
  fi

  jq -n \
    --arg schema_version "artifact-lifecycle/latest-pointer/v1" \
    --arg producer "test/integration/harness_release_gate.sh" \
    --arg run_id "$RUN_ID" \
    --arg tier "$RELEASE_GATE_TIER" \
    --arg result "$result" \
    --arg run_path "$run_rel" \
    --arg manifest_path "$manifest_rel" \
    --arg summary_path "$summary_rel" \
    --arg completed_at "$completed_at" \
    '$ARGS.named' > "$pointer_tmp"

  cp "$pointer_tmp" "$latest_path"
  if [[ "$FAIL_COUNT" -eq 0 ]]; then
    cp "$pointer_tmp" "$success_path"
  else
    cp "$pointer_tmp" "$failure_path"
  fi
  /bin/rm -f "$pointer_tmp"
}

while IFS='|' read -r step_slug step_command; do
  case "$step_slug" in
    semantic_review_queue_runtime)
      cleanup_queue_runtime_test_processes
      run_step_inherited_output "$step_slug" "$step_command" "$QUEUE_RUNTIME_TIMEOUT_SECS"
      cleanup_queue_runtime_test_processes
      ;;
    common_task_contract_smoke)
      run_step_inherited_output "$step_slug" "$step_command" "$COMMON_TASK_CONTRACT_TIMEOUT_SECS"
      ;;
    semantic_project_id_contract)
      run_step_inherited_output "$step_slug" "$step_command" "$PROJECT_ID_CONTRACT_TIMEOUT_SECS"
      ;;
    orchestration_packet_validator)
      run_step_inherited_output "$step_slug" "$step_command" "$ORCHESTRATION_PACKET_VALIDATOR_TIMEOUT_SECS"
      ;;
    auto_orchestrate_packet_preflight)
      run_step "$step_slug" "$step_command" "$AUTO_ORCHESTRATE_PACKET_PREFLIGHT_TIMEOUT_SECS"
      ;;
    cross_family_artifact_smoke)
      run_step "$step_slug" "$step_command" "$CROSS_FAMILY_ARTIFACT_SMOKE_TIMEOUT_SECS"
      ;;
    cross_family_live_smoke_preflight)
      run_step "$step_slug" "$step_command" "$CROSS_FAMILY_LIVE_SMOKE_PREFLIGHT_TIMEOUT_SECS"
      ;;
    cross_family_live_artifact_smoke)
      run_step "$step_slug" "$step_command" "$CROSS_FAMILY_LIVE_ARTIFACT_SMOKE_TIMEOUT_SECS"
      ;;
    rev_harness_janitor_inspect)
      run_step "$step_slug" "$step_command" "$REV_HARNESS_JANITOR_TIMEOUT_SECS"
      ;;
    *)
      run_step "$step_slug" "$step_command" "$STEP_TIMEOUT_SECS"
      ;;
  esac
done < <(selected_steps)

collect_inventory_metrics
collect_coordinator_delta
TOTAL_ELAPSED_MS=$(($(now_ms) - TOTAL_STARTED_MS))
[[ "$TOTAL_ELAPSED_MS" -ge 0 ]] || TOTAL_ELAPSED_MS=0
write_summary
COMPLETED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
write_lifecycle_manifest "$COMPLETED_AT"
write_latest_pointers "$COMPLETED_AT"

printf 'SUMMARY: pass=%s fail=%s\n' "$PASS_COUNT" "$FAIL_COUNT"
printf 'ARTIFACTS: %s\n' "$RUN_DIR"

if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi

printf 'PASS: harness_release_gate\n'
