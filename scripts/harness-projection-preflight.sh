#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROJECTION_REGISTRY="${HARNESS_PROJECTION_PREFLIGHT_REGISTRY:-$PROJECT_ROOT/.agent/registry/orchestration_policy_projection.json}"

usage() {
  cat <<'EOF'
Usage:
  scripts/harness-projection-preflight.sh --validate [--mode reviewer-next-status]
  scripts/harness-projection-preflight.sh --list-statuses [--json] [--mode reviewer-next-status]
  scripts/harness-projection-preflight.sh --status <status> --json [--mode reviewer-next-status]
  scripts/harness-projection-preflight.sh --status <status> --field <field> [--mode reviewer-next-status]

Preflight the orchestration projection / reviewer next-status schema.
EOF
}

die() {
  printf 'harness-projection-preflight: %s\n' "$*" >&2
  exit 1
}

validate_registry() {
  [[ -r "$PROJECTION_REGISTRY" ]] || die "missing projection registry: $PROJECTION_REGISTRY"
  jq empty "$PROJECTION_REGISTRY" >/dev/null || die "invalid projection registry JSON: $PROJECTION_REGISTRY"
  jq -e '
    def non_empty_string:
      type == "string" and length > 0;
    def string_array:
      type == "array" and length > 0 and all(.[]; non_empty_string);
    def unique_array:
      length == (unique | length);

    type == "object"
    and (.packet | type == "object")
    and (.packet.canonical_slice_fields | string_array and unique_array)
    and (.packet.deprecated_field_aliases | string_array and unique_array)
    and (.packet.required_plan_sections | string_array and unique_array)
    and (.packet.required_packet_files | string_array and unique_array)
    and (.packet.ledger_markers | string_array and unique_array)
    and (.packet.baseline_snapshot_name | non_empty_string)
    and (.reviewer_contract | type == "object")
    and (.reviewer_contract.canonical_worker_outcome_contract_source | non_empty_string)
    and (.reviewer_contract.accepted_incoming_request_statuses | string_array and unique_array)
    and (.reviewer_contract.accepted_review_request_targets | string_array and unique_array)
    and (.reviewer_contract.accepted_discovery_owners | string_array and unique_array)
    and (.reviewer_contract.accepted_worker_outcomes | string_array and unique_array)
    and (.reviewer_contract.accepted_review_verdicts | string_array and unique_array)
    and (
      (.reviewer_contract.accepted_review_verdicts | sort)
      == (["LGTM", "BLOCK", "Request Changes", "Needs verification", "Needs Discussion"] | sort)
    )
    and (.reviewer_contract.accepted_outgoing_next_statuses | string_array and unique_array)
    and (
      (.reviewer_contract.accepted_outgoing_next_statuses | sort)
      == (["pending acceptance", "blocked", "pending review", "pending verification"] | sort)
    )
    and (.reviewer_contract.blocked_worker_outcome_intake_rule_line | non_empty_string)
    and (.reviewer_contract.verdict_outgoing_next_status | type == "object")
    and (
      (.reviewer_contract.verdict_outgoing_next_status | keys | sort)
      == (.reviewer_contract.accepted_review_verdicts | sort)
    )
    and (.reviewer_contract.verdict_outgoing_next_status == {
      "LGTM": "pending acceptance",
      "BLOCK": "blocked",
      "Request Changes": "pending review",
      "Needs verification": "pending verification",
      "Needs Discussion": "blocked"
    })
    and (
      [.reviewer_contract.verdict_outgoing_next_status[]]
      | all(.[]; non_empty_string)
    )
    and (
      .reviewer_contract.accepted_outgoing_next_statuses as $statuses
      | [.reviewer_contract.verdict_outgoing_next_status[]]
      | all(.[]; $statuses | index(.))
    )
    and (.reviewer_contract.lgtm_gate | type == "object")
    and (.reviewer_contract.lgtm_gate.required_request_target | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_incoming_request_status | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_artifact_integrity | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_required_verification_result | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_tests_result | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_adversarial_result | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_slice_contract_sheet_status | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_class_closure_sheet_status | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_slice_contract_closed_universe_status | non_empty_string)
    and (.reviewer_contract.lgtm_gate.required_class_closure_closed_universe_status | non_empty_string)
    and (.reviewer_contract.lgtm_gate == {
      "required_request_target": "FINAL",
      "required_incoming_request_status": "pending final review",
      "required_artifact_integrity": "complete",
      "required_required_verification_result": "PASS",
      "required_tests_result": "PASS",
      "required_adversarial_result": "PASS",
      "required_slice_contract_sheet_status": "CLOSED",
      "required_class_closure_sheet_status": "CLOSED",
      "required_slice_contract_closed_universe_status": "YES",
      "required_class_closure_closed_universe_status": "YES"
    })
  ' "$PROJECTION_REGISTRY" >/dev/null || die "invalid projection registry schema: $PROJECTION_REGISTRY"
}

status_json_filter='
  .reviewer_contract as $contract
  | $contract.verdict_outgoing_next_status as $mapping
  | {
      status: $status,
      matching_review_verdicts: ($mapping | to_entries | map(select(.value == $status) | .key)),
      accepted_review_verdicts: $contract.accepted_review_verdicts,
      incoming_request_statuses: $contract.accepted_incoming_request_statuses,
      reviewer_contract_source: $contract.canonical_worker_outcome_contract_source,
      blocked_worker_outcome_intake_rule_line: $contract.blocked_worker_outcome_intake_rule_line,
      lgtm_gate_required_request_target: $contract.lgtm_gate.required_request_target,
      lgtm_gate_applies: (($mapping.LGTM // "") == $status)
    }
'

output_mode="text"
policy_mode="reviewer-next-status"
status=""
field=""
list_statuses=false
validate=false
status_set=false
field_set=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --validate)
      validate=true
      shift
      ;;
    --list-statuses)
      list_statuses=true
      shift
      ;;
    --status)
      [[ "$#" -ge 2 ]] || die "--status requires a value"
      status_set=true
      status="$2"
      shift 2
      ;;
    --field)
      [[ "$#" -ge 2 ]] || die "--field requires a value"
      field_set=true
      field="$2"
      shift 2
      ;;
    --json)
      output_mode="json"
      shift
      ;;
    --mode)
      [[ "$#" -ge 2 ]] || die "--mode requires a value"
      policy_mode="$2"
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

[[ -n "$policy_mode" ]] || die "--mode cannot be empty"
[[ "$policy_mode" == "reviewer-next-status" ]] || die "unsupported mode: $policy_mode"

if [[ "$status_set" == true && -z "$status" ]]; then
  die "--status cannot be empty"
fi

if [[ "$field_set" == true && -z "$field" ]]; then
  die "--field cannot be empty"
fi

if [[ "$validate" == true && "$output_mode" != "text" ]]; then
  die "--validate does not support --json"
fi

validate_registry

if [[ "$validate" == true ]]; then
  [[ "$list_statuses" == false && "$status_set" == false && "$field_set" == false ]] \
    || die "--validate cannot be combined with status lookup options"
  printf 'PASS: projection registry schema\n'
  exit 0
fi

if [[ "$list_statuses" == true ]]; then
  [[ "$status_set" == false && "$field_set" == false ]] || die "--list-statuses cannot be combined with --status or --field"
  if [[ "$output_mode" == "json" ]]; then
    jq -c '.reviewer_contract.accepted_outgoing_next_statuses' "$PROJECTION_REGISTRY"
  else
    jq -r '.reviewer_contract.accepted_outgoing_next_statuses[]' "$PROJECTION_REGISTRY"
  fi
  exit 0
fi

[[ "$status_set" == true ]] || die "--validate, --list-statuses, or --status is required"

jq -e --arg status "$status" '.reviewer_contract.accepted_outgoing_next_statuses | index($status)' "$PROJECTION_REGISTRY" >/dev/null \
  || die "unknown status: $status"

if [[ "$field_set" == true ]]; then
  [[ "$output_mode" == "text" ]] || die "--field cannot be combined with --json"
  jq -e --arg status "$status" --arg field "$field" "$status_json_filter | has(\$field)" "$PROJECTION_REGISTRY" >/dev/null \
    || die "unknown field for status $status: $field"
  jq -r --arg status "$status" --arg field "$field" "$status_json_filter | .[\$field]" "$PROJECTION_REGISTRY"
  exit 0
fi

if [[ "$output_mode" == "json" ]]; then
  jq -c --arg status "$status" "$status_json_filter" "$PROJECTION_REGISTRY"
  exit 0
fi

jq -r --arg status "$status" '
  '"$status_json_filter"' as $projection
  | "- status: \($projection.status)",
    "- matching review verdicts: \($projection.matching_review_verdicts | join(", "))",
    "- reviewer contract source: \($projection.reviewer_contract_source)",
    "- lgtm gate applies: \($projection.lgtm_gate_applies)"
' "$PROJECTION_REGISTRY"
