#!/usr/bin/env bash
set -euo pipefail

ORCHESTRATION_POLICY_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=.claude/commands/lib/utils.sh
# shellcheck disable=SC1091
source "$ORCHESTRATION_POLICY_LIB_DIR/utils.sh"
# shellcheck source=.claude/commands/lib/task_contract.sh
# shellcheck disable=SC1091
source "$ORCHESTRATION_POLICY_LIB_DIR/task_contract.sh"

readonly ORCHESTRATION_POLICY_BUNDLE_VERSION="1.1.0"

orchestration_policy_repo_root() {
  local repo_root=""

  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  [[ -n "$repo_root" ]] || die "orchestration policy requires a git repository"
  (cd "$repo_root" && pwd -P)
}

orchestration_policy_sha256_file() {
  local file_path="${1:-}"
  local digest=""

  [[ -r "$file_path" ]] || die "missing readable file for sha256: $file_path"

  if command -v shasum >/dev/null 2>&1; then
    digest=$(shasum -a 256 "$file_path" | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$file_path" | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(openssl dgst -sha256 -r "$file_path" | awk '{print $1}')
  else
    die "no SHA-256 tool available"
  fi

  [[ -n "$digest" ]] || die "failed to compute SHA-256: $file_path"
  printf '%s\n' "$digest"
}

orchestration_policy_normalize_path() {
  local path="${1:-}"
  local dir_path=""
  local base_name=""

  [[ -n "$path" ]] || die "path is empty"
  base_name="$(basename "$path")"
  dir_path="$(cd -- "$(dirname -- "$path")" && pwd -P)"
  printf '%s/%s\n' "$dir_path" "$base_name"
}

orchestration_policy_compute_bundle_id() {
  local payload="${1:-}"
  local digest=""

  [[ -n "$payload" ]] || die "bundle payload is empty"

  if command -v shasum >/dev/null 2>&1; then
    digest=$(printf '%s' "$payload" | jq -cS 'del(.bundle_id)' | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(printf '%s' "$payload" | jq -cS 'del(.bundle_id)' | sha256sum | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(printf '%s' "$payload" | jq -cS 'del(.bundle_id)' | openssl dgst -sha256 -r | awk '{print $1}')
  else
    die "no SHA-256 tool available"
  fi

  [[ -n "$digest" ]] || die "failed to compute bundle digest"
  printf 'policy-bundle-%s\n' "$digest"
}

orchestration_policy_compute_bundle_id_from_file() {
  local bundle_path="${1:-}"
  local digest=""

  [[ -n "$bundle_path" ]] || die "bundle path is empty"
  ensure_file "$bundle_path"

  if command -v shasum >/dev/null 2>&1; then
    digest=$(jq -cS 'del(.bundle_id)' "$bundle_path" | shasum -a 256 | awk '{print $1}')
  elif command -v sha256sum >/dev/null 2>&1; then
    digest=$(jq -cS 'del(.bundle_id)' "$bundle_path" | sha256sum | awk '{print $1}')
  elif command -v openssl >/dev/null 2>&1; then
    digest=$(jq -cS 'del(.bundle_id)' "$bundle_path" | openssl dgst -sha256 -r | awk '{print $1}')
  else
    die "no SHA-256 tool available"
  fi

  [[ -n "$digest" ]] || die "failed to compute bundle digest"
  printf 'policy-bundle-%s\n' "$digest"
}

orchestration_policy_projection_source_path() {
  local repo_root=""
  local canonical_path=""
  local source_path="${ORCHESTRATION_POLICY_PROJECTION_PATH:-.agent/registry/orchestration_policy_projection.json}"

  repo_root="$(orchestration_policy_repo_root)"
  canonical_path="$(orchestration_policy_normalize_path "$repo_root/.agent/registry/orchestration_policy_projection.json")"
  if [[ "$source_path" == /* ]]; then
    source_path="$(orchestration_policy_normalize_path "$source_path")"
  else
    source_path="$(orchestration_policy_normalize_path "$repo_root/$source_path")"
  fi

  if [[ "$source_path" != "$canonical_path" ]]; then
    die "non-manifest orchestration policy projection override rejected: $source_path"
  fi

  printf '%s\n' "$source_path"
}

orchestration_policy_validate_projection_source() {
  local projection_source_path="${1:-}"

  [[ -n "$projection_source_path" ]] || die "projection source path is empty"
  ensure_file "$projection_source_path"
  jq -e '
    def non_empty_string:
      type == "string" and length > 0;
    def string_array:
      type == "array" and length > 0 and all(.[]; non_empty_string);
    type == "object"
    and (.packet | type == "object")
    and (.packet.canonical_slice_fields | string_array)
    and (.packet.deprecated_field_aliases | string_array)
    and (.packet.required_plan_sections | string_array)
    and (.packet.required_packet_files | string_array)
    and (.packet.ledger_markers | string_array)
    and (.packet.baseline_snapshot_name | non_empty_string)
    and (.reviewer_contract | type == "object")
    and (.reviewer_contract.canonical_worker_outcome_contract_source | non_empty_string)
    and (.reviewer_contract.accepted_incoming_request_statuses | string_array)
    and (.reviewer_contract.accepted_review_request_targets | string_array)
    and (.reviewer_contract.accepted_discovery_owners | string_array)
    and (.reviewer_contract.accepted_worker_outcomes | string_array)
    and (.reviewer_contract.accepted_review_verdicts | string_array)
    and (
      (.reviewer_contract.accepted_review_verdicts | sort)
      == (["LGTM", "BLOCK", "Request Changes", "Needs verification", "Needs Discussion"] | sort)
    )
    and (.reviewer_contract.accepted_outgoing_next_statuses | string_array)
    and (.reviewer_contract.blocked_worker_outcome_intake_rule_line | non_empty_string)
    and (.reviewer_contract.verdict_outgoing_next_status | type == "object")
    and (
      (.reviewer_contract.verdict_outgoing_next_status | keys | sort)
      == (.reviewer_contract.accepted_review_verdicts | sort)
    )
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
  ' "$projection_source_path" >/dev/null || die "invalid orchestration policy projection source: $projection_source_path"
}

orchestration_policy_projection_json() {
  local projection_source_path=""

  projection_source_path="$(orchestration_policy_projection_source_path)"
  orchestration_policy_validate_projection_source "$projection_source_path"

  jq -cS '{
    canonical_slice_fields: .packet.canonical_slice_fields,
    deprecated_field_aliases: .packet.deprecated_field_aliases,
    required_plan_sections: .packet.required_plan_sections,
    required_packet_files: .packet.required_packet_files,
    ledger_markers: .packet.ledger_markers,
    baseline_snapshot_name: .packet.baseline_snapshot_name,
    reviewer_contract: .reviewer_contract
  }' "$projection_source_path" || die "failed to build projection json from source: $projection_source_path"
}

orchestration_policy_canonical_manifest_path() {
  local repo_root=""

  repo_root="$(orchestration_policy_repo_root)"
  orchestration_policy_normalize_path "$repo_root/.agent/registry/policy_sources.json"
}

orchestration_policy_validate_manifest() {
  local manifest_abs="${1:-}"
  local repo_root=""
  local canonical_manifest_abs=""
  local rel_path=""
  local authority_type=""
  local local_abs_path=""
  local has_projection_source=0
  local manifest_rows_file=""

  [[ -n "$manifest_abs" ]] || die "manifest path is empty"
  ensure_file "$manifest_abs"
  repo_root="$(orchestration_policy_repo_root)"
  canonical_manifest_abs="$(orchestration_policy_canonical_manifest_path)"
  [[ "$manifest_abs" == "$canonical_manifest_abs" ]] || die "policy source manifest must be canonical: $canonical_manifest_abs"
  jq -e '
    def non_empty_string:
      type == "string" and length > 0;
    def relative_path_string:
      type == "string" and length > 0 and (startswith("/") | not);
    type == "array"
    and length > 0
    and all(
      .[];
      (.stable == true)
      and (.path | relative_path_string)
      and (.authority_type | non_empty_string)
      and (.governs | type == "array" and length > 0)
      and (.required_checks_surface | type == "array" and length > 0)
    )
  ' "$manifest_abs" >/dev/null || die "policy source manifest must contain only stable repo-relative sources: $manifest_abs"

  manifest_rows_file="$(create_temp_file orchestration_policy_manifest_validation_rows)"
  jq -r '.[] | [.path, .authority_type] | @tsv' "$manifest_abs" > "$manifest_rows_file"

  while IFS=$'\t' read -r rel_path authority_type; do
    [[ -n "$rel_path" ]] || continue
    if [[ "$rel_path" == ".agent/registry/orchestration_policy_projection.json" ]]; then
      has_projection_source=1
    fi
    case "$authority_type" in
      hard_rules|verification_truth|runtime_policy|project_context|role_policy|dependency_gate|contract_surface|contract_runtime)
        ;;
      *)
        die "unknown authority_type for manifest path: $rel_path ($authority_type)"
        ;;
    esac

    case "$rel_path" in
      .agent/active/*|.agent/archive/*|.claude/tmp/*)
        die "manifest path must not point to volatile surface: $rel_path"
        ;;
    esac

    local_abs_path="$(orchestration_policy_normalize_path "$repo_root/$rel_path")"
    case "$local_abs_path" in
      "$repo_root"/*)
        ;;
      *)
        die "manifest path escapes repo root: $rel_path -> $local_abs_path"
        ;;
    esac
    ensure_file "$local_abs_path"
  done < "$manifest_rows_file"

  /bin/rm -f "$manifest_rows_file"

  [[ "$has_projection_source" -eq 1 ]] || die "policy source manifest must include .agent/registry/orchestration_policy_projection.json"
}

orchestration_policy_manifest_record_path() {
  local repo_root="${1:-}"
  local manifest_abs="${2:-}"

  [[ -n "$repo_root" ]] || die "repo root is empty"
  [[ -n "$manifest_abs" ]] || die "manifest path is empty"

  if [[ "$manifest_abs" == "$repo_root"/* ]]; then
    printf '%s\n' "${manifest_abs#"$repo_root"/}"
  else
    printf '%s\n' "$manifest_abs"
  fi
}

orchestration_policy_sources_json_from_manifest() {
  local repo_root="${1:-}"
  local manifest_abs="${2:-}"
  local tmp_entries=""
  local tmp_manifest_rows=""
  local path=""
  local authority_type=""
  local stable=""
  local governs_json=""
  local checks_json=""
  local source_sha=""

  [[ -n "$repo_root" ]] || die "repo root is empty"
  [[ -n "$manifest_abs" ]] || die "manifest path is empty"

  orchestration_policy_validate_manifest "$manifest_abs"

  tmp_entries="$(create_temp_file orchestration_policy_sources)"
  tmp_manifest_rows="$(create_temp_file orchestration_policy_manifest_rows)"

  jq -r '
    .[]
    | [
        .path,
        .authority_type,
        (.stable | tostring),
        (.governs | @json),
        (.required_checks_surface | @json)
      ]
    | @tsv
  ' "$manifest_abs" > "$tmp_manifest_rows"

  while IFS=$'\t' read -r path authority_type stable governs_json checks_json; do
    source_sha="$(orchestration_policy_sha256_file "$repo_root/$path")"

    jq -n \
      --arg path "$path" \
      --arg authority_type "$authority_type" \
      --arg sha256 "$source_sha" \
      --argjson stable "$stable" \
      --argjson governs "$governs_json" \
      --argjson required_checks_surface "$checks_json" \
      '{
        path: $path,
        authority_type: $authority_type,
        stable: $stable,
        governs: $governs,
        required_checks_surface: $required_checks_surface,
        sha256: $sha256
      }' >> "$tmp_entries"
  done < "$tmp_manifest_rows"

  jq -s '.' "$tmp_entries" || die "failed to build sources array"
  /bin/rm -f "$tmp_entries" "$tmp_manifest_rows"
}

orchestration_policy_compile_bundle() {
  local output_path="${1:-}"
  local manifest_path="${2:-.agent/registry/policy_sources.json}"
  local repo_root=""
  local manifest_abs=""
  local manifest_rel=""
  local manifest_sha=""
  local tmp_bundle=""
  local sources_file=""
  local projection_file=""
  local bundle_id=""

  [[ -n "$output_path" ]] || die "orchestration_policy_compile_bundle requires <output_path>"
  ensure_cmd jq

  repo_root="$(orchestration_policy_repo_root)"
  if [[ "$manifest_path" == /* ]]; then
    manifest_abs="$(orchestration_policy_normalize_path "$manifest_path")"
  else
    manifest_abs="$(orchestration_policy_normalize_path "$repo_root/$manifest_path")"
  fi
  ensure_file "$manifest_abs"
  jq empty "$manifest_abs" >/dev/null
  orchestration_policy_validate_manifest "$manifest_abs"

  manifest_rel="$(orchestration_policy_manifest_record_path "$repo_root" "$manifest_abs")"
  manifest_sha="$(orchestration_policy_sha256_file "$manifest_abs")"
  tmp_bundle="$(create_temp_file orchestration_policy_bundle)"
  sources_file="$(create_temp_file orchestration_policy_sources_json)"
  projection_file="$(create_temp_file orchestration_policy_projection_json)"

  orchestration_policy_sources_json_from_manifest "$repo_root" "$manifest_abs" > "$sources_file" \
    || die "failed to build sources json from manifest: $manifest_abs"
  orchestration_policy_projection_json > "$projection_file" \
    || die "failed to build projection json"

  ensure_dir "$(dirname "$output_path")"
  jq -n \
    --arg bundle_version "$ORCHESTRATION_POLICY_BUNDLE_VERSION" \
    --arg manifest_path "$manifest_rel" \
    --arg manifest_sha "$manifest_sha" \
    --slurpfile sources "$sources_file" \
    --slurpfile projection "$projection_file" \
    '{
      bundle_version: $bundle_version,
      bundle_id: "",
      derived_only: true,
      source_manifest: {
        path: $manifest_path,
        sha256: $manifest_sha
      },
      sources: $sources[0],
      projection: $projection[0]
    }' > "$tmp_bundle" || die "failed to build bundle payload"

  bundle_id="$(orchestration_policy_compute_bundle_id_from_file "$tmp_bundle")"
  jq --arg bundle_id "$bundle_id" '.bundle_id = $bundle_id' "$tmp_bundle" > "$output_path" \
    || die "failed to set bundle id"

  /bin/rm -f "$tmp_bundle" "$sources_file" "$projection_file"
  printf '%s\n' "$bundle_id"
}

orchestration_policy_validate_bundle() {
  local bundle_path="${1:-}"
  local repo_root=""
  local actual_id=""
  local expected_id=""
  local manifest_path=""
  local manifest_sha=""
  local manifest_record_path=""
  local actual_sources_json=""
  local actual_projection_json=""
  local expected_sources_file=""
  local expected_projection_file=""
  local expected_sources_canonical=""
  local expected_projection_canonical=""
  local source_path=""
  local source_sha=""
  local source_rows_file=""

  [[ -n "$bundle_path" ]] || die "orchestration_policy_validate_bundle requires <bundle_path>"
  ensure_cmd jq
  ensure_file "$bundle_path"

  jq -e '
    def non_empty_string:
      type == "string" and length > 0;
    def hex_sha256:
      type == "string" and test("^[0-9a-f]{64}$");
    type == "object"
    and (.bundle_version | non_empty_string)
    and (.bundle_id | non_empty_string)
    and (.derived_only == true)
    and (.source_manifest | type == "object")
    and (.source_manifest.path | non_empty_string)
    and (.source_manifest.sha256 | hex_sha256)
    and (.sources | type == "array" and length > 0)
    and all(
      .sources[];
      (.path | non_empty_string)
      and (.authority_type | non_empty_string)
      and (.stable | type == "boolean")
      and (.governs | type == "array" and length > 0)
      and (.required_checks_surface | type == "array" and length > 0)
      and (.sha256 | hex_sha256)
    )
    and (.projection | type == "object")
    and (.projection.canonical_slice_fields | type == "array" and length > 0)
    and (.projection.deprecated_field_aliases | type == "array" and length > 0)
    and (.projection.required_plan_sections | type == "array" and length > 0)
    and (.projection.required_packet_files | type == "array" and length > 0)
    and (.projection.ledger_markers | type == "array" and length > 0)
    and (.projection.baseline_snapshot_name | non_empty_string)
  ' "$bundle_path" >/dev/null || die "bundle is invalid or incomplete: $bundle_path"

  expected_id="$(orchestration_policy_compute_bundle_id_from_file "$bundle_path")"
  actual_id="$(jq -r '.bundle_id' "$bundle_path")"
  [[ "$actual_id" == "$expected_id" ]] || die "bundle id mismatch: $bundle_path"

  repo_root="$(orchestration_policy_repo_root)"
  manifest_path="$(jq -r '.source_manifest.path' "$bundle_path")"
  manifest_sha="$(jq -r '.source_manifest.sha256' "$bundle_path")"
  if [[ "$manifest_path" == /* ]]; then
    manifest_path="$(orchestration_policy_normalize_path "$manifest_path")"
  else
    manifest_path="$repo_root/$manifest_path"
  fi
  [[ "$manifest_path" == "$(orchestration_policy_canonical_manifest_path)" ]] \
    || die "bundle manifest path must be canonical: $manifest_path"
  [[ "$(orchestration_policy_sha256_file "$manifest_path")" == "$manifest_sha" ]] \
    || die "bundle manifest digest drift detected: $manifest_path"
  manifest_record_path="$(orchestration_policy_manifest_record_path "$repo_root" "$manifest_path")"
  [[ "$(jq -r '.source_manifest.path' "$bundle_path")" == "$manifest_record_path" ]] \
    || die "bundle manifest path drift detected: $bundle_path"

  expected_sources_file="$(create_temp_file orchestration_policy_expected_sources)"
  expected_projection_file="$(create_temp_file orchestration_policy_expected_projection)"

  orchestration_policy_sources_json_from_manifest "$repo_root" "$manifest_path" > "$expected_sources_file" \
    || die "failed to rebuild expected bundle sources: $manifest_path"
  actual_sources_json="$(jq -cS '.sources' "$bundle_path")"
  expected_sources_canonical="$(jq -cS '.' "$expected_sources_file")" \
    || die "failed to canonicalize expected bundle sources: $manifest_path"
  [[ "$actual_sources_json" == "$expected_sources_canonical" ]] \
    || die "bundle sources drift detected: $bundle_path"

  orchestration_policy_projection_json > "$expected_projection_file" \
    || die "failed to rebuild expected bundle projection"
  actual_projection_json="$(jq -cS '.projection' "$bundle_path")"
  expected_projection_canonical="$(jq -cS '.' "$expected_projection_file")" \
    || die "failed to canonicalize expected bundle projection"
  [[ "$actual_projection_json" == "$expected_projection_canonical" ]] \
    || die "bundle projection drift detected: $bundle_path"

  source_rows_file="$(create_temp_file orchestration_policy_bundle_source_rows)"
  jq -r '.sources[] | [.path, .sha256] | @tsv' "$bundle_path" > "$source_rows_file"

  while IFS=$'\t' read -r source_path source_sha; do
    if [[ "$source_path" == /* ]]; then
      source_path="$(orchestration_policy_normalize_path "$source_path")"
    else
      source_path="$repo_root/$source_path"
    fi
    [[ "$(orchestration_policy_sha256_file "$source_path")" == "$source_sha" ]] \
      || die "bundle source digest drift detected: $source_path"
  done < "$source_rows_file"

  /bin/rm -f "$expected_sources_file" "$expected_projection_file" "$source_rows_file"
}

orchestration_policy_section_has_content() {
  local file_path="$1"
  local section_title="$2"

  awk -v heading="## ${section_title}" '
    BEGIN {
      in_section = 0
      saw_content = 0
    }
    $0 == heading {
      in_section = 1
      next
    }
    in_section && /^## / {
      exit
    }
    in_section {
      line = $0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", line)
      if (length(line) > 0) {
        saw_content = 1
      }
    }
    END {
      exit(saw_content ? 0 : 1)
    }
  ' "$file_path"
}

orchestration_policy_task_block() {
  local ledger_path="$1"
  local task_id="$2"

  awk -v heading="## ${task_id}" '
    BEGIN {
      capture = 0
    }
    $0 == heading {
      capture = 1
      print
      next
    }
    capture && /^## / {
      exit
    }
    capture {
      print
    }
  ' "$ledger_path"
}

orchestration_policy_alias_scan() {
  local file_path="$1"
  local alias_name="$2"

  awk -v alias_name="$alias_name" '
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/^[-*][[:space:]]+/, "", line)
      sub(/^[0-9]+[.)][[:space:]]+/, "", line)
      if (index(line, alias_name ":") == 1) {
        found = 1
        exit 0
      }
      if (index(line, "`" alias_name "`:") == 1) {
        found = 1
        exit 0
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$file_path"
}

orchestration_policy_require_file() {
  local label="$1"
  local file_path="$2"

  [[ -n "$file_path" ]] || die "missing packet file argument: $label"
  ensure_file "$file_path"
}

orchestration_policy_validate_packet() {
  local bundle_path="${1:-}"
  local plan_path="${2:-}"
  local sow_path="${3:-}"
  local ledger_path="${4:-}"
  local coder_prompt_path="${5:-}"
  local reviewer_prompt_path="${6:-}"
  local coder_output_stub_path="${7:-}"
  local reviewer_output_stub_path="${8:-}"
  local baseline_freeze_path="${9:-}"
  local task_id="${10:-}"
  local expected_accepted_slice="${11:-}"
  local expected_active_slice="${12:-}"
  local baseline_snapshot_name=""
  local section_title=""
  local deprecated_alias=""
  local ledger_block_file=""
  local accepted_slice=""
  local active_slice=""
  local budget_line=""
  local budget_status_line=""
  local required_sections_file=""
  local deprecated_aliases_file=""

  [[ -n "$task_id" ]] || die "packet validation requires task id"
  orchestration_policy_validate_bundle "$bundle_path"

  orchestration_policy_require_file "plan" "$plan_path"
  orchestration_policy_require_file "sow" "$sow_path"
  orchestration_policy_require_file "ledger" "$ledger_path"
  orchestration_policy_require_file "coder_prompt" "$coder_prompt_path"
  orchestration_policy_require_file "reviewer_prompt" "$reviewer_prompt_path"
  orchestration_policy_require_file "coder_output_stub" "$coder_output_stub_path"
  orchestration_policy_require_file "reviewer_output_stub" "$reviewer_output_stub_path"
  orchestration_policy_require_file "baseline_snapshot" "$baseline_freeze_path"

  required_sections_file="$(create_temp_file orchestration_policy_required_sections)"
  jq -r '.projection.required_plan_sections[]' "$bundle_path" > "$required_sections_file"
  while IFS= read -r section_title; do
    orchestration_policy_section_has_content "$plan_path" "$section_title" \
      || die "plan section is missing or empty: $section_title"
  done < "$required_sections_file"

  task_contract_extract_required_checks "$plan_path" >/dev/null \
    || die "plan required checks are not exact-command safe: $plan_path"

  deprecated_aliases_file="$(create_temp_file orchestration_policy_deprecated_aliases)"
  jq -r '.projection.deprecated_field_aliases[]' "$bundle_path" > "$deprecated_aliases_file"
  while IFS= read -r deprecated_alias; do
    for file_path in \
      "$plan_path" \
      "$sow_path" \
      "$ledger_path" \
      "$coder_prompt_path" \
      "$reviewer_prompt_path"; do
      if orchestration_policy_alias_scan "$file_path" "$deprecated_alias"; then
        die "deprecated packet alias detected: $file_path ($deprecated_alias)"
      fi
    done
  done < "$deprecated_aliases_file"

  ledger_block_file="$(create_temp_file orchestration_policy_ledger_block)"
  orchestration_policy_task_block "$ledger_path" "$task_id" > "$ledger_block_file"
  [[ -s "$ledger_block_file" ]] || die "task lineage ledger entry missing: $task_id"
  grep -Fq -- "- task id: \`$task_id\`" "$ledger_block_file" || die "ledger task id marker missing: $task_id"

  accepted_slice="$(sed -n 's/^- latest orchestrator-accepted slice:[[:space:]]*`\([^`]*\)`.*/\1/p' "$ledger_block_file" | head -n 1)"
  active_slice="$(sed -n 's/^- current active slice:[[:space:]]*`\([^`]*\)`.*/\1/p' "$ledger_block_file" | head -n 1)"
  [[ -n "$accepted_slice" ]] || die "ledger accepted-slice marker missing: $task_id"
  [[ -n "$active_slice" ]] || die "ledger active-slice marker missing: $task_id"
  if [[ -n "$expected_accepted_slice" && "$accepted_slice" != "$expected_accepted_slice" ]]; then
    die "ledger accepted-slice mismatch: expected=$expected_accepted_slice actual=$accepted_slice"
  fi
  if [[ -n "$expected_active_slice" && "$active_slice" != "$expected_active_slice" ]]; then
    die "ledger active-slice mismatch: expected=$expected_active_slice actual=$active_slice"
  fi

  budget_line="$(grep -F 'task-level stall-or-wall-time budget:' "$ledger_block_file" || true)"
  budget_status_line="$(grep -F 'task-level stall-or-wall-time budget status:' "$ledger_block_file" || true)"
  [[ -n "$budget_line" ]] || die "ledger budget marker missing: $task_id"
  [[ -n "$budget_status_line" ]] || die "ledger budget-status marker missing: $task_id"

  [[ -s "$coder_prompt_path" ]] || die "coder prompt is empty: $coder_prompt_path"
  [[ -s "$reviewer_prompt_path" ]] || die "reviewer prompt is empty: $reviewer_prompt_path"
  [[ ! -s "$coder_output_stub_path" ]] || die "coder output stub must be empty: $coder_output_stub_path"
  [[ ! -s "$reviewer_output_stub_path" ]] || die "reviewer output stub must be empty: $reviewer_output_stub_path"

  baseline_snapshot_name="$(jq -r '.projection.baseline_snapshot_name' "$bundle_path")" \
    || die "failed to read baseline snapshot name"
  [[ "$(basename "$baseline_freeze_path")" == "$baseline_snapshot_name" ]] \
    || die "baseline snapshot must use canonical name: $baseline_freeze_path"
  grep -Fq '# baseline_freeze_version=1' "$baseline_freeze_path" || die "baseline snapshot header missing version"
  grep -Fq '# repo_root=' "$baseline_freeze_path" || die "baseline snapshot header missing repo_root"
  grep -Fq '# generated_at=' "$baseline_freeze_path" || die "baseline snapshot header missing generated_at"

  /bin/rm -f "$ledger_block_file" "$required_sections_file" "$deprecated_aliases_file"
}
