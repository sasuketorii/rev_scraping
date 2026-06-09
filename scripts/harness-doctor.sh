#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)}"

MODE=""
JSON_ONLY="false"
STRICT_MODE="false"

usage() {
  cat <<'EOF'
Usage:
  scripts/harness-doctor.sh --quick [--json] [--strict]
  scripts/harness-doctor.sh --check-vendoring [--path <project_root>] [--allow-vendored]

Modes:
  --quick
      Runs a read-only, advisory-only quick harness health summary.
      The quick doctor is not acceptance authority and does not replace
      reviewer LGTM, truth matrix rules, deterministic checks, or
      release-gate evidence.

  --strict (with --quick)
      Promotes the runtime identity-check (canonical-guard) from
      advisory to strict for this invocation by exporting
      REV_HARNESS_VENDOR_CHECK=strict and invoking the guard against
      this checkout. ambiguous-copy / invalid identity classes become
      fail-close (exit 70) instead of warn. Use this on release-gate
      and CI surfaces; runtime wrappers stay advisory by default.

  --check-vendoring
      Scans <project_root> (default: current working directory) for
      vendored copies of rev_harness wrappers (claude-wrapper.sh,
      codex-wrapper.sh). Compares each detection against the canonical
      copy under ~/dev/rev_harness/scripts (override with
      REV_HARNESS_CANONICAL_ROOT).
      Exit codes:
        0  no vendoring detected (or --allow-vendored suppressed vendored)
        70 vendored copies detected (sha256 matches canonical)
        71 mutated copies detected (sha256 differs from canonical)
EOF
}

die() {
  printf 'harness-doctor: %s\n' "$*" >&2
  exit 2
}

now_ms() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import time; print(time.monotonic_ns() // 1000000)'
  else
    printf '%s000\n' "$(date +%s)"
  fi
}

sha256_file() {
  local path="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$path" | awk '{print $1}'
  else
    shasum -a 256 "$path" | awk '{print $1}'
  fi
}

json_string_array() {
  jq -n --arg lines "$1" '$lines | split("\n") | map(select(length > 0))'
}

json_object_or_null() {
  local path="$1"
  if [[ -f "$path" && ! -L "$path" ]] && jq empty "$path" >/dev/null 2>&1; then
    jq -c '.' "$path"
  else
    printf 'null\n'
  fi
}

jq_with_input() {
  local input="$1"
  shift
  printf '%s\n' "$input" | jq "$@"
}

add_finding() {
  local kind="$1"
  local message="$2"
  case "$kind" in
    block) BLOCKS+="$message"$'\n' ;;
    warning) WARNINGS+="$message"$'\n' ;;
    unknown) UNKNOWNS+="$message"$'\n' ;;
    *) die "internal error: unknown finding kind: $kind" ;;
  esac
}

run_step() {
  local name="$1"
  local status="$2"
  local started ended elapsed
  started="$(now_ms)"
  "$3"
  ended="$(now_ms)"
  elapsed=$((ended - started))
  [[ "$elapsed" -ge 0 ]] || elapsed=0
  STEPS_JSON="$(jq_with_input "$STEPS_JSON" -c \
    --arg name "$name" \
    --arg status "$status" \
    --argjson elapsed "$elapsed" \
    '. + [{name: $name, status: $status, elapsed_ms: $elapsed}]' \
    )"
}

require_quick_dependencies() {
  command -v git >/dev/null 2>&1 || die "required command not found: git"
  command -v jq >/dev/null 2>&1 || die "required command not found: jq"
  command -v awk >/dev/null 2>&1 || die "required command not found: awk"
  command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || die "required command not found: shasum or sha256sum"
  git -C "$PROJECT_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not a Git repository: $PROJECT_ROOT"
}

collect_git_status_summary() {
  local status_output branch_line dirty_lines
  local dirty_count staged_count untracked_count sample_lines

  status_output="$(git -C "$PROJECT_ROOT" status --porcelain=v1 --branch)"
  branch_line="${status_output%%$'\n'*}"
  if [[ "$branch_line" == "$status_output" ]]; then
    dirty_lines=""
  else
    dirty_lines="${status_output#"$branch_line"$'\n'}"
  fi
  dirty_count="$(printf '%s\n' "$dirty_lines" | awk 'NF {count++} END {print count + 0}')"
  staged_count="$(printf '%s\n' "$dirty_lines" | awk 'substr($0,1,1) !~ /[ ?]/ {count++} END {print count + 0}')"
  untracked_count="$(printf '%s\n' "$dirty_lines" | awk 'substr($0,1,2) == "??" {count++} END {print count + 0}')"
  sample_lines="$(printf '%s\n' "$dirty_lines" | awk 'NF { if (count < 20) { print substr($0,4) } count++ }')"

  GIT_STATUS_JSON="$(jq -nc \
    --arg branch "$branch_line" \
    --argjson dirty "$dirty_count" \
    --argjson staged "$staged_count" \
    --argjson untracked "$untracked_count" \
    --argjson samples "$(json_string_array "$sample_lines")" \
    '{branch: $branch, dirty_count: $dirty, staged_count: $staged, untracked_count: $untracked, changed_path_samples: $samples}')"

  if [[ "$dirty_count" -gt 0 ]]; then
    add_finding warning "dirty worktree detected: ${dirty_count} changed/untracked paths"
  fi
}

safe_rel_path() {
  local value="$1"
  [[ -n "$value" ]] || return 1
  [[ "$value" != /* ]] || return 1
  case "$value" in
    *"/../"*|../*|*/..|.|..|*"//"*) return 1 ;;
  esac
  return 0
}

collect_release_gate_pointer() {
  local pointer_rel=".claude/tmp/harness-release-gate/latest.json"
  local pointer_path="$PROJECT_ROOT/$pointer_rel"
  local summary_rel="" manifest_rel="" summary_path="" manifest_path=""

  LATEST_RELEASE_GATE_JSON="$(jq -nc --arg pointer "$pointer_rel" '{pointer_path: $pointer, present: false}')"

  if [[ ! -e "$pointer_path" ]]; then
    add_finding unknown "latest release-gate pointer is missing: $pointer_rel"
    return 0
  fi
  if [[ -L "$pointer_path" || ! -f "$pointer_path" ]]; then
    add_finding block "latest release-gate pointer is not a regular file: $pointer_rel"
    return 0
  fi
  if ! jq empty "$pointer_path" >/dev/null 2>&1; then
    add_finding block "latest release-gate pointer is not valid JSON: $pointer_rel"
    return 0
  fi

  summary_rel="$(jq -r '.summary_path // empty' "$pointer_path")"
  manifest_rel="$(jq -r '.manifest_path // empty' "$pointer_path")"

  LATEST_RELEASE_GATE_JSON="$(jq -nc \
    --arg pointer "$pointer_rel" \
    --argjson pointer_json "$(json_object_or_null "$pointer_path")" \
    '{pointer_path: $pointer, present: true, pointer: $pointer_json}')"

  if safe_rel_path "$summary_rel"; then
    summary_path="$PROJECT_ROOT/$summary_rel"
    if [[ -f "$summary_path" && ! -L "$summary_path" ]]; then
      LATEST_RELEASE_GATE_JSON="$(jq_with_input "$LATEST_RELEASE_GATE_JSON" -c --arg path "$summary_rel" '.summary_path = $path | .summary_present = true')"
    else
      LATEST_RELEASE_GATE_JSON="$(jq_with_input "$LATEST_RELEASE_GATE_JSON" -c --arg path "$summary_rel" '.summary_path = $path | .summary_present = false')"
      add_finding warning "latest release-gate summary path is missing or unsafe to read: $summary_rel"
    fi
  else
    add_finding warning "latest release-gate summary path is absent or invalid"
  fi

  if safe_rel_path "$manifest_rel"; then
    manifest_path="$PROJECT_ROOT/$manifest_rel"
    if [[ -f "$manifest_path" && ! -L "$manifest_path" ]]; then
      if jq empty "$manifest_path" >/dev/null 2>&1; then
        LATEST_RELEASE_GATE_JSON="$(jq_with_input "$LATEST_RELEASE_GATE_JSON" -c --arg path "$manifest_rel" '.manifest_path = $path | .manifest_present = true | .manifest_json_valid = true')"
      else
        LATEST_RELEASE_GATE_JSON="$(jq_with_input "$LATEST_RELEASE_GATE_JSON" -c --arg path "$manifest_rel" '.manifest_path = $path | .manifest_present = true | .manifest_json_valid = false')"
        add_finding block "latest release-gate manifest is invalid JSON: $manifest_rel"
      fi
    else
      LATEST_RELEASE_GATE_JSON="$(jq_with_input "$LATEST_RELEASE_GATE_JSON" -c --arg path "$manifest_rel" '.manifest_path = $path | .manifest_present = false')"
      add_finding warning "latest release-gate manifest path is missing or unsafe to read: $manifest_rel"
    fi
  else
    add_finding warning "latest release-gate manifest path is absent or invalid"
  fi
}

collect_model_policy_summary() {
  local policy_rel=".agent/registry/model_policy.json"
  local runtime_rel=".agent/generated/codex_model_policy.runtime.json"
  local policy_path="$PROJECT_ROOT/$policy_rel"
  local runtime_path="$PROJECT_ROOT/$runtime_rel"
  local policy_hash="" runtime_source_hash="" generated_at=""

  MODEL_POLICY_JSON="$(jq -nc \
    --arg policy "$policy_rel" \
    --arg runtime "$runtime_rel" \
    '{policy_path: $policy, runtime_path: $runtime}')"

  if [[ ! -f "$policy_path" || -L "$policy_path" ]]; then
    add_finding block "required model policy source is missing or unsafe: $policy_rel"
    MODEL_POLICY_JSON="$(jq_with_input "$MODEL_POLICY_JSON" -c '.policy_present = false')"
    return 0
  fi
  if ! jq empty "$policy_path" >/dev/null 2>&1; then
    add_finding block "required model policy source is invalid JSON: $policy_rel"
    MODEL_POLICY_JSON="$(jq_with_input "$MODEL_POLICY_JSON" -c '.policy_present = true | .policy_json_valid = false')"
    return 0
  fi

  policy_hash="$(sha256_file "$policy_path")"
  MODEL_POLICY_JSON="$(jq_with_input "$MODEL_POLICY_JSON" -c \
    --arg hash "$policy_hash" \
    --arg current "$(jq -r '.current_model // "unknown"' "$policy_path")" \
    '.policy_present = true | .policy_json_valid = true | .policy_sha256 = $hash | .current_model = $current' \
    )"

  if [[ ! -f "$runtime_path" || -L "$runtime_path" ]]; then
    add_finding block "generated model policy runtime artifact is missing or unsafe: $runtime_rel"
    MODEL_POLICY_JSON="$(jq_with_input "$MODEL_POLICY_JSON" -c '.runtime_present = false')"
    return 0
  fi
  if ! jq empty "$runtime_path" >/dev/null 2>&1; then
    add_finding block "generated model policy runtime artifact is invalid JSON: $runtime_rel"
    MODEL_POLICY_JSON="$(jq_with_input "$MODEL_POLICY_JSON" -c '.runtime_present = true | .runtime_json_valid = false')"
    return 0
  fi

  runtime_source_hash="$(jq -r '.source_policy_sha256 // empty' "$runtime_path")"
  generated_at="$(jq -r '.generated_at // "unknown"' "$runtime_path")"
  MODEL_POLICY_JSON="$(jq_with_input "$MODEL_POLICY_JSON" -c \
    --arg source_hash "$runtime_source_hash" \
    --arg generated_at "$generated_at" \
    '.runtime_present = true
     | .runtime_json_valid = true
     | .runtime_source_policy_sha256 = $source_hash
     | .generated_at = $generated_at
     | .runtime_hash_matches_policy = ($source_hash == .policy_sha256)' \
    )"

  if [[ "$runtime_source_hash" != "$policy_hash" ]]; then
    add_finding block "generated model policy runtime hash does not match policy source"
  fi
}

collect_active_hold_summary() {
  local ledger_rel=".agent/active/sow/task-lineage-ledger.md"
  local active_plan_count=0
  local archive_file_count=0
  local path=""

  ACTIVE_SUMMARY_JSON="$(jq -nc \
    --arg ledger "$ledger_rel" \
    '{ledger_path: $ledger, clean_distribution_aware: true}')"

  [[ -f "$PROJECT_ROOT/$ledger_rel" && ! -L "$PROJECT_ROOT/$ledger_rel" ]] \
    || add_finding warning "task lineage ledger is missing or unsafe: $ledger_rel"

  for path in "$PROJECT_ROOT"/.agent/active/plan_*.md; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    active_plan_count=$((active_plan_count + 1))
  done

  for path in \
    "$PROJECT_ROOT"/.agent/archive/* \
    "$PROJECT_ROOT"/.agent/archive/*/* \
    "$PROJECT_ROOT"/.agent/archive/*/*/*; do
    [[ -f "$path" && ! -L "$path" ]] || continue
    archive_file_count=$((archive_file_count + 1))
  done

  ACTIVE_SUMMARY_JSON="$(jq_with_input "$ACTIVE_SUMMARY_JSON" -c \
    --argjson active_plan_count "$active_plan_count" \
    --argjson archive_file_count "$archive_file_count" \
    '.active_plan_count = $active_plan_count
     | .archive_file_count = $archive_file_count
     | .historical_plan_required = false
     | .clean_archive_allowed = true')"
}

collect_semantic_paths_summary() {
  local paths_rel=".rev-harness-state/paths.json"
  local paths_path="$PROJECT_ROOT/$paths_rel"
  local schema_ok="false" semantic_db="" rust_db="" legacy_node_db="" semantic_db_present="false" rust_db_present="false" legacy_node_db_present="false"
  local digest=""

  if [[ ! -f "$paths_path" ]]; then
    add_finding unknown "semantic paths manifest is missing: $paths_rel; semantic is optional, so raw-read required files until bootstrap/reindex restores a FRESH index"
    SEMANTIC_PATHS_JSON="$(jq -nc '{present: false}')"
    return 0
  fi

  digest="$(sha256_file "$paths_path")"
  if jq -e '.schema == "rev-harness-paths/v1"' "$paths_path" >/dev/null 2>&1; then
    schema_ok="true"
  else
    add_finding warning "semantic paths manifest schema is invalid: $paths_rel; do not rely on semantic capsule output, raw-read required files"
  fi

  if jq empty "$paths_path" >/dev/null 2>&1; then
    semantic_db="$(jq -r '.semantic_db // .rust_db // .node_db // empty' "$paths_path")"
    rust_db="$(jq -r '.rust_db // .semantic_db // empty' "$paths_path")"
    legacy_node_db="$(jq -r '.node_db // empty' "$paths_path")"
  else
    add_finding warning "semantic paths manifest is invalid JSON: $paths_rel; do not rely on semantic capsule output, raw-read required files"
  fi

  [[ -n "$semantic_db" && -f "$semantic_db" ]] && semantic_db_present="true"
  [[ -n "$rust_db" && -f "$rust_db" ]] && rust_db_present="true"
  [[ -n "$legacy_node_db" && -f "$legacy_node_db" ]] && legacy_node_db_present="true"

  SEMANTIC_PATHS_JSON="$(jq -nc \
    --argjson present true \
    --argjson schema_ok "$schema_ok" \
    --arg sha256 "$digest" \
    --arg semantic_db "$semantic_db" \
    --arg rust_db "$rust_db" \
    --arg legacy_node_db "$legacy_node_db" \
    --argjson semantic_db_present "$semantic_db_present" \
    --argjson rust_db_present "$rust_db_present" \
    --argjson legacy_node_db_present "$legacy_node_db_present" \
    '{
      present: $present,
      schema_ok: $schema_ok,
      sha256: $sha256,
      backend: "rust",
      semantic_db: $semantic_db,
      rust_db: $rust_db,
      legacy_node_db: $legacy_node_db,
      semantic_db_present: $semantic_db_present,
      rust_db_present: $rust_db_present,
      legacy_node_db_present: $legacy_node_db_present
    }')"
}

derive_status() {
  if [[ -n "$BLOCKS" ]]; then
    printf 'BLOCK\n'
  elif [[ -n "$WARNINGS" ]]; then
    printf 'WARN\n'
  elif [[ -n "$UNKNOWNS" ]]; then
    printf 'UNKNOWN\n'
  else
    printf 'OK\n'
  fi
}

render_json() {
  local elapsed_ms="$1"
  local advisory_status="$2"
  jq -nc \
    --argjson elapsed "$elapsed_ms" \
    --arg status "$advisory_status" \
    --argjson steps "$STEPS_JSON" \
    --argjson blocks "$(json_string_array "$BLOCKS")" \
    --argjson warnings "$(json_string_array "$WARNINGS")" \
    --argjson unknowns "$(json_string_array "$UNKNOWNS")" \
    --argjson git_status "$GIT_STATUS_JSON" \
    --argjson release_gate "$LATEST_RELEASE_GATE_JSON" \
    --argjson model_policy "$MODEL_POLICY_JSON" \
    --argjson active_summary "$ACTIVE_SUMMARY_JSON" \
    --argjson semantic_paths "$SEMANTIC_PATHS_JSON" \
    '{
      schema_version: "harness-doctor/v1",
      mode: "quick",
      tier: "quick",
      advisory_only: true,
      acceptance_authority: false,
      network_allowed: false,
      deep_scan: false,
      artifact_body_scan: false,
      mutated: false,
      execution_failure: false,
      advisory_status: $status,
      status: $status,
      exit_policy: "nonzero_only_for_environment_breakage_or_execution_failure",
      elapsed_ms: $elapsed,
      steps: $steps,
      blocks: $blocks,
      warnings: $warnings,
      unknowns: $unknowns,
      summaries: {
        git_status: $git_status,
        release_gate: $release_gate,
        model_policy: $model_policy,
        active_task: $active_summary,
        semantic_paths: $semantic_paths
      },
      pointers: {
        latest_release_gate_pointer: ".claude/tmp/harness-release-gate/latest.json",
        model_policy_source: ".agent/registry/model_policy.json",
        model_policy_runtime: ".agent/generated/codex_model_policy.runtime.json"
      },
      caveat: "advisory-only; not acceptance authority; does not replace truth matrix, reviewer LGTM, deterministic checks, or release-gate evidence"
    }'
}

render_human() {
  local elapsed_ms="$1"
  local advisory_status="$2"
  local latest_pointer
  latest_pointer="$(jq_with_input "$LATEST_RELEASE_GATE_JSON" -r '.pointer.run_id? // "unknown"')"
  printf 'Harness Doctor Quick\n'
  printf -- '- status: %s\n' "$advisory_status"
  printf -- '- elapsed_ms: %s\n' "$elapsed_ms"
  printf -- '- advisory_only: true\n'
  printf -- '- acceptance_authority: false\n'
  printf -- '- network_allowed: false\n'
  printf -- '- deep_scan: false\n'
  printf -- '- artifact_body_scan: false\n'
  printf -- '- latest_release_gate_run: %s\n' "$latest_pointer"
  printf -- '- caveat: advisory-only; this does not replace truth matrix, reviewer LGTM, deterministic checks, or release-gate evidence.\n'
  printf -- '- suggested_next_command: bash test/integration/harness_release_gate.sh\n'
  if [[ -n "$BLOCKS" ]]; then
    printf '\nBlocks:\n'
    printf '%s' "$BLOCKS" | awk 'NF {printf "- %s\n", $0}'
  fi
  if [[ -n "$WARNINGS" ]]; then
    printf '\nWarnings:\n'
    printf '%s' "$WARNINGS" | awk 'NF {printf "- %s\n", $0}'
  fi
  if [[ -n "$UNKNOWNS" ]]; then
    printf '\nUnknowns:\n'
    printf '%s' "$UNKNOWNS" | awk 'NF {printf "- %s\n", $0}'
  fi
}

inode_of() {
  local path="$1"
  stat -f '%i' "$path" 2>/dev/null || stat -c '%i' "$path" 2>/dev/null || printf '\n'
}

run_check_vendoring() {
  local scan_root="$1"
  local allow_vendored="$2"
  local canonical_root="${REV_HARNESS_CANONICAL_ROOT:-$HOME/dev/rev_harness}"
  local canonical_scripts="$canonical_root/scripts"

  if [[ ! -d "$scan_root" ]]; then
    printf 'harness-doctor: scan path does not exist: %s\n' "$scan_root" >&2
    exit 2
  fi

  local vendored_count=0
  local mutated_count=0
  local found_count=0

  local matches
  matches="$(find "$scan_root" -maxdepth 6 \
    \( -type d -name .git -prune \) -o \
    -type f \( -name claude-wrapper.sh -o -name codex-wrapper.sh \) -print 2>/dev/null || true)"

  local path base canonical scan_inode canon_inode scan_hash canon_hash
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    found_count=$((found_count + 1))
    base="$(basename "$path")"
    canonical="$canonical_scripts/$base"

    if [[ ! -f "$canonical" ]]; then
      printf 'WARN: no canonical reference found for %s (looked at %s)\n' "$base" "$canonical" >&2
      continue
    fi

    scan_inode="$(inode_of "$path")"
    canon_inode="$(inode_of "$canonical")"
    if [[ -n "$scan_inode" && "$scan_inode" == "$canon_inode" ]]; then
      # canonical itself; ignore.
      continue
    fi

    scan_hash="$(sha256_file "$path")"
    canon_hash="$(sha256_file "$canonical")"
    if [[ "$scan_hash" == "$canon_hash" ]]; then
      if [[ "$allow_vendored" == "true" ]]; then
        printf 'WARN: VENDORED COPY detected (allowed): %s\n' "$path"
      else
        printf 'VENDORED COPY detected: %s\n' "$path"
      fi
      vendored_count=$((vendored_count + 1))
    else
      printf 'MUTATED COPY detected: %s\n' "$path"
      mutated_count=$((mutated_count + 1))
    fi
  done <<EOF
$matches
EOF

  if [[ "$mutated_count" -gt 0 ]]; then
    printf 'rev-harness-doctor: vendoring check FAILED: mutated=%d vendored=%d\n' \
      "$mutated_count" "$vendored_count" >&2
    exit 71
  fi
  if [[ "$vendored_count" -gt 0 && "$allow_vendored" != "true" ]]; then
    printf 'rev-harness-doctor: vendoring check FAILED: vendored=%d\n' "$vendored_count" >&2
    exit 70
  fi
  printf 'rev-harness-doctor: no vendoring detected (scanned=%d under %s)\n' \
    "$found_count" "$scan_root"
  exit 0
}

VENDOR_PATH=""
ALLOW_VENDORED="false"

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --quick)
      MODE="quick"
      shift
      ;;
    --check-vendoring)
      MODE="check-vendoring"
      shift
      ;;
    --path)
      [[ "$#" -ge 2 ]] || die "--path requires an argument"
      VENDOR_PATH="$2"
      shift 2
      ;;
    --allow-vendored)
      ALLOW_VENDORED="true"
      shift
      ;;
    --json)
      JSON_ONLY="true"
      shift
      ;;
    --strict)
      STRICT_MODE="true"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

if [[ "$MODE" == "check-vendoring" ]]; then
  [[ -n "$VENDOR_PATH" ]] || VENDOR_PATH="$(pwd)"
  run_check_vendoring "$VENDOR_PATH" "$ALLOW_VENDORED"
fi

[[ "$MODE" == "quick" ]] || die "--quick or --check-vendoring is required"

# 0.0.12: --strict promotes canonical-guard from advisory to fail-close for this
# invocation. Runtime wrappers default to warn so adoption isn't blocked; doctor
# --strict and release-gate are the explicit deep-check surfaces.
if [[ "$STRICT_MODE" == "true" ]]; then
  export REV_HARNESS_VENDOR_CHECK="strict"
  # canonical-guard derives repo_root from BASH_SOURCE[1] (the script sourcing
  # it). Sourcing here means scripts/.. == PROJECT_ROOT, which matches the
  # wrapper invocation path. exit 70 propagates out of doctor.
  # shellcheck source=scripts/_canonical-guard.sh
  source "$SCRIPT_DIR/_canonical-guard.sh"
  rev_harness_assert_canonical_root harness-doctor-strict
fi

require_quick_dependencies

BLOCKS=""
WARNINGS=""
UNKNOWNS=""
STEPS_JSON="[]"
GIT_STATUS_JSON="{}"
LATEST_RELEASE_GATE_JSON="{}"
MODEL_POLICY_JSON="{}"
ACTIVE_SUMMARY_JSON="{}"
SEMANTIC_PATHS_JSON="{}"

STARTED_MS="$(now_ms)"
run_step "git_status_summary" "OK" collect_git_status_summary
run_step "release_gate_latest_pointer" "OK" collect_release_gate_pointer
run_step "model_policy_freshness" "OK" collect_model_policy_summary
run_step "active_task_summary" "OK" collect_active_hold_summary
run_step "semantic_paths" "OK" collect_semantic_paths_summary
ENDED_MS="$(now_ms)"
ELAPSED_MS=$((ENDED_MS - STARTED_MS))
[[ "$ELAPSED_MS" -ge 0 ]] || ELAPSED_MS=0

if [[ "$ELAPSED_MS" -gt 3000 ]]; then
  add_finding warning "quick doctor exceeded advisory budget: ${ELAPSED_MS}ms > 3000ms"
fi

STATUS="$(derive_status)"
JSON_OUTPUT="$(render_json "$ELAPSED_MS" "$STATUS")"

if ! printf '%s\n' "$JSON_OUTPUT" | jq empty >/dev/null 2>&1; then
  printf 'harness-doctor: failed to produce valid JSON\n' >&2
  exit 2
fi

if [[ "$JSON_ONLY" == "true" ]]; then
  printf '%s\n' "$JSON_OUTPUT"
else
  render_human "$ELAPSED_MS" "$STATUS"
  printf '\nJSON:\n%s\n' "$JSON_OUTPUT"
fi
