#!/usr/bin/env bash

set -u

if [[ "${SEMANTIC_INTEGRATION_SYSTEM_BASH_REEXEC:-0}" != "1" && "${BASH:-}" != "/bin/bash" && -x /bin/bash ]]; then
  export SEMANTIC_INTEGRATION_SYSTEM_BASH_REEXEC=1
  exec /bin/bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AUTO_ORCHESTRATE="$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh"
CONTEXT_ANALYSIS="$PROJECT_ROOT/.claude/commands/lib/context_analysis.sh"
CONTEXT_CAPSULE="$PROJECT_ROOT/.claude/commands/lib/context_capsule.sh"

PASS_COUNT=0
FAIL_COUNT=0

test_description() {
  local id="${1:-}"
  case "$id" in
    C1) echo "finalize_coordination_context emits registry delta and applies authoritative mutators" ;;
    C2) echo "registry mutation path fails closed when authoritative mutator call fails" ;;
    C3) echo "invalid JSON mutator response with exit 0 fails closed" ;;
    C4) echo "missing preflight artifact blocks mutation instead of degrading to empty plan" ;;
    C5) echo "malformed delta artifact blocks mutation instead of degrading to empty plan" ;;
    C6) echo "later-iteration deletions are refreshed into authoritative delete mutations" ;;
    C7) echo "contract-invalid JSON object input blocks mutation instead of degrading to empty plan" ;;
    C8) echo "delta generation failure blocks mutation instead of silently skipping authoritative registry updates" ;;
    C9) echo "invalid status enum blocks mutation instead of coercing to active" ;;
    C10) echo "later mutator failure records durable partial-apply artifact before blocking" ;;
    C11) echo "malformed changed-symbol entry blocks mutation instead of being silently dropped during normalization" ;;
    C12) echo "project_id mismatch between preflight artifact and authoritative resolver blocks mutation" ;;
    C13) echo "legacy authoritative project_id agent_base blocks mutation before registry apply" ;;
    C14) echo "invalid authoritative project_id format blocks mutation before registry apply" ;;
    C15) echo "missing preflight project_id blocks finalize before authoritative registry mutation" ;;
    C16) echo "apply-stage missing payload project_id writes durable apply error artifact and blocks" ;;
    C17) echo "apply-stage invalid payload project_id writes durable apply error artifact and blocks" ;;
    C18) echo "apply-stage payload project_id mismatch writes durable apply error artifact and blocks" ;;
    C19) echo "deleted changed-symbol status blocks finalize instead of silently dropping authoritative delete mutation" ;;
    C20) echo "nested mutation project_id override attempt is rejected before apply" ;;
    C21) echo "prepare blocks before writing preflight_input when authoritative project_id is unavailable" ;;
    C22) echo "prepare blocks before writing preflight_input when authoritative project_id is legacy" ;;
    C23) echo "prepare blocks before writing preflight_input when authoritative project_id has internal whitespace" ;;
    C24) echo "helper-level project_id resolution fails closed when canonical resolver is missing or empty" ;;
    C25) echo "helper-level project_id resolution trims edge whitespace only" ;;
    C26) echo "finalize normalizes edge whitespace in preflight project_id and proceeds when authoritative value matches" ;;
    C27) echo "finalize blocks when preflight project_id contains internal whitespace" ;;
    C28) echo "apply stage normalizes edge whitespace in payload project_id and proceeds when authoritative value matches" ;;
    C29) echo "apply stage blocks when payload project_id contains internal whitespace" ;;
    C30) echo "tampered payload summary mismatch fails closed and durable artifacts keep authoritative mutation counts" ;;
    C31) echo "malformed finalize deletion refresh entries block authoritative mutation instead of being silently dropped" ;;
    C32) echo "malformed base preflight_input entries block finalize before authoritative mutation instead of being silently dropped" ;;
    *) return 1 ;;
  esac
}

run_test() {
  local id="$1"
  local fn="$2"
  local description=""
  description="$(test_description "$id")"

  printf '[TEST] %s - %s\n' "$id" "$description"
  if "$fn"; then
    PASS_COUNT=$((PASS_COUNT + 1))
    printf '[PASS] %s\n' "$id"
  else
    FAIL_COUNT=$((FAIL_COUNT + 1))
    printf '[FAIL] %s\n' "$id"
  fi
}

build_valid_apply_stage_payload() {
  local project_id="${1:-__omit__}"

  jq -nc \
    --arg project_id "$project_id" \
    '
      {
        task_id: "task_apply_guard",
        phase: "impl",
        iteration: 1,
        scope: ["src/foo.sh"],
        changed_files: ["src/foo.sh"],
        deleted_paths: [],
        move_candidates: [],
        mutations: {
          upserts: [
            {
              semantic_id: "src/foo.sh:foo",
              name: "foo",
              module: "src/foo.sh",
              file_path: "src/foo.sh",
              kind: "function",
              exports: [],
              imports: [],
              status: "active"
            }
          ],
          set_status: [],
          deletes: []
        },
        summary: {
          upserts: 1,
          set_status: 0,
          deletes: 0
        }
      }
      + (
        if $project_id == "__omit__" then
          {}
        else
          {project_id: $project_id}
        end
      )
    '
}

test_c1_registry_mutation_positive() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_c1"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[
  {"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"},
  {"logical_id":"src/bar.sh:bar","name":"bar","module":"src/bar.sh","file":"src/bar.sh","kind":"function","_status":"inactive","_inactive_reason":"manual_hold"}
],"impacted_symbols":[],"changed_files":["src/foo.sh","src/bar.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      case "$tool_name" in
        "sem.registry.upsert")
          local semantic_id=""
          semantic_id="$(printf '%s\n' "$payload" | jq -r '.components[0].semantic_id // empty')"
          printf '%s\n' "$semantic_id" >> "$tmpdir/upserted_ids"
          echo '{"applied":true,"new_count":1,"updated_count":0}'
          ;;
        "sem.registry.set_status")
          local semantic_id=""
          semantic_id="$(printf '%s\n' "$payload" | jq -r '.semantic_id // empty')"
          if [[ -z "$semantic_id" ]] || [[ ! -f "$tmpdir/upserted_ids" ]] || ! grep -Fxq "$semantic_id" "$tmpdir/upserted_ids"; then
            echo "missing prerequisite upsert" >&2
            return 1
          fi
          echo '{"semantic_id":"src/bar.sh:bar","old_status":"active","new_status":"inactive","updated_at":"2026-04-10T00:00:00Z"}'
          ;;
        "sem.registry.delete")
          echo '{"semantic_id":"src/old.sh:old","deleted_at":"2026-04-10T00:00:00Z"}'
          ;;
        *)
          return 1
          ;;
      esac
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1","project_id":"proj_c1","scope":["src/foo.sh","src/bar.sh"],"proposed_components":[],"deleted_paths":["src/old.sh"],"removed_symbols":["src/old.sh:old"],"move_candidates":[]}
JSON

    finalize_coordination_context "$tmpdir" "impl" "2"
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: finalize_coordination_context failed unexpectedly (rc=$rc)" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter2.json" ]]; then
      echo "detail: registry delta artifact missing" >&2
      failed=1
    elif ! jq -e '
      .project_id == "proj_c1"
      and .task_id == "task_c1"
      and .summary.upserts == 2
      and .summary.set_status == 1
      and .summary.deletes == 1
      and ((.mutations.upserts | map(.semantic_id) | sort) == ["src/bar.sh:bar","src/foo.sh:foo"])
      and (.mutations.set_status[0].semantic_id == "src/bar.sh:bar")
      and (.mutations.set_status[0].status == "inactive")
      and (.mutations.deletes[0].semantic_id == "src/old.sh:old")
    ' "$tmpdir/impl_coord_registry_delta_iter2.json" >/dev/null 2>&1; then
      echo "detail: registry delta artifact did not match expected contract" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_apply_iter2.json" ]]; then
      echo "detail: registry apply artifact missing" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 2
      and .summary.set_status == 1
      and .summary.deletes == 1
      and (.applied | length == 4)
    ' "$tmpdir/impl_coord_registry_apply_iter2.json" >/dev/null 2>&1; then
      echo "detail: registry apply artifact did not capture expected calls" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mcp_or_fallback call log missing" >&2
      failed=1
    else
      local call_order=""
      call_order="$(cut -f1 "$tmpdir/mcp_calls.tsv" | paste -sd ',' -)"
      if [[ "$call_order" != "sem.registry.upsert,sem.registry.upsert,sem.registry.set_status,sem.registry.delete" ]]; then
        echo "detail: unexpected mutator call order: $call_order" >&2
        failed=1
      fi
      if ! awk -F '\t' '$1 == "sem.registry.upsert" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -s -e '
        (length == 2)
        and ((map(.components[0].semantic_id) | sort) == ["src/bar.sh:bar","src/foo.sh:foo"])
      ' >/dev/null 2>&1; then
        echo "detail: upsert payload semantic_ids mismatch" >&2
        failed=1
      fi
      if ! awk -F '\t' '$1 == "sem.registry.upsert" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -s -e 'all(.[]; .project_id == "proj_c1")' >/dev/null 2>&1; then
        echo "detail: upsert payload did not preserve authoritative project_id" >&2
        failed=1
      fi
      if ! awk -F '\t' '$1 == "sem.registry.set_status" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -e '.semantic_id == "src/bar.sh:bar" and .status == "inactive"' >/dev/null 2>&1; then
        echo "detail: set_status payload mismatch" >&2
        failed=1
      fi
      if ! awk -F '\t' '$1 == "sem.registry.set_status" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -e '.project_id == "proj_c1"' >/dev/null 2>&1; then
        echo "detail: set_status payload did not preserve authoritative project_id" >&2
        failed=1
      fi
      if ! awk -F '\t' '$1 == "sem.registry.delete" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -e '.semantic_id == "src/old.sh:old"' >/dev/null 2>&1; then
        echo "detail: delete payload mismatch" >&2
        failed=1
      fi
      if ! awk -F '\t' '$1 == "sem.registry.delete" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -e '.project_id == "proj_c1"' >/dev/null 2>&1; then
        echo "detail: delete payload did not preserve authoritative project_id" >&2
        failed=1
      fi
      local line_no=0
      local inactive_upsert_line=""
      local status_line=""
      local tool=""
      local payload=""
      while IFS=$'\t' read -r tool payload; do
        line_no=$((line_no + 1))
        [[ -n "$tool" ]] || continue
        if [[ "$tool" == "sem.registry.upsert" ]] && printf '%s\n' "$payload" | jq -e '.components[0].semantic_id == "src/bar.sh:bar"' >/dev/null 2>&1; then
          inactive_upsert_line="$line_no"
        fi
        if [[ "$tool" == "sem.registry.set_status" ]] && printf '%s\n' "$payload" | jq -e '.semantic_id == "src/bar.sh:bar"' >/dev/null 2>&1; then
          status_line="$line_no"
        fi
      done < "$tmpdir/mcp_calls.tsv"
      if [[ -z "$inactive_upsert_line" ]]; then
        echo "detail: inactive symbol was not upserted" >&2
        failed=1
      elif [[ -z "$status_line" ]] || (( inactive_upsert_line >= status_line )); then
        echo "detail: inactive symbol was not upserted before set_status" >&2
        failed=1
      fi
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c2_registry_mutation_fail_closed() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_fail"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_c1"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      if [[ "$tool_name" == "sem.registry.upsert" ]]; then
        echo "backend unavailable" >&2
        return 1
      fi
      return 1
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_fail","project_id":"proj_c1","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded on mutator failure" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked on fail-closed mutation path" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch on fail-closed mutation path" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta artifact should still exist on fail-closed path" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist after failed mutator call" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c3_registry_invalid_json_response_fail_closed() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_invalid_json"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_invalid_json"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      if [[ "$tool_name" == "sem.registry.upsert" ]]; then
        printf 'not-json\n'
        return 0
      fi
      return 1
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_invalid_json","project_id":"proj_invalid_json","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded after invalid JSON mutator response" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked on invalid JSON mutator response" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch on invalid JSON mutator response" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: apply error artifact missing on invalid JSON mutator response" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 1
      and .summary.set_status == 0
      and .summary.deletes == 0
      and (.applied | length == 0)
      and .failing_tool == "sem.registry.upsert"
      and (.error | test("invalid JSON"; "i"))
    ' "$tmpdir/impl_coord_registry_apply_iter1.json" >/dev/null 2>&1; then
      echo "detail: apply error artifact did not capture invalid JSON mutator response" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c4_registry_missing_preflight_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_missing_preflight"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_missing_preflight"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded without preflight artifact" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for missing preflight artifact" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for missing preflight artifact" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for missing preflight" >&2
      failed=1
    elif ! jq -e '.error | contains("preflight_input")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture missing preflight" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist when preflight is missing" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c5_registry_malformed_delta_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_bad_delta"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_bad_delta"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      printf 'not-json\n'
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_bad_delta","project_id":"proj_bad_delta","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with malformed delta artifact" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for malformed delta artifact" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for malformed delta artifact" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for malformed delta" >&2
      failed=1
    elif ! jq -e '.error | contains("delta_input")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture malformed delta" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist when delta artifact is malformed" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c6_registry_later_iteration_delete_refresh() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_late_delete"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_late_delete"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":["src/late.sh"],"removed_symbols":["src/late.sh:late"],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh","src/late.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      case "$tool_name" in
        "sem.registry.upsert")
          echo '{"applied":true,"new_count":1,"updated_count":0}'
          ;;
        "sem.registry.delete")
          echo '{"semantic_id":"src/late.sh:late","deleted_at":"2026-04-10T00:00:00Z"}'
          ;;
        "sem.registry.set_status")
          return 0
          ;;
        *)
          return 1
          ;;
      esac
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_late_delete","project_id":"proj_late_delete","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    finalize_coordination_context "$tmpdir" "impl" "2"
    local rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: finalize_coordination_context failed unexpectedly on later deletion refresh (rc=$rc)" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter2.json" ]]; then
      echo "detail: registry delta artifact missing for later deletion refresh" >&2
      failed=1
    elif ! jq -e '
      .summary.deletes == 1
      and (.deleted_paths | index("src/late.sh") != null)
      and (.mutations.deletes[0].semantic_id == "src/late.sh:late")
    ' "$tmpdir/impl_coord_registry_delta_iter2.json" >/dev/null 2>&1; then
      echo "detail: later deletion did not reach registry delta artifact" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mcp call log missing for later deletion refresh" >&2
      failed=1
    elif ! awk -F '\t' '$1 == "sem.registry.delete" {print $2}' "$tmpdir/mcp_calls.tsv" | jq -e '.semantic_id == "src/late.sh:late" and .project_id == "proj_late_delete"' >/dev/null 2>&1; then
      echo "detail: later deletion did not reach sem.registry.delete payload" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c7_registry_invalid_shape_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_invalid_shape"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_invalid_shape"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":"oops","changed_files":["src/foo.sh"]}
JSON
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_invalid_shape","project_id":"proj_invalid_shape","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with contract-invalid delta object" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for contract-invalid delta object" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for contract-invalid delta object" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for contract-invalid delta object" >&2
      failed=1
    elif ! jq -e '.error | contains("changed_symbols")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture invalid changed_symbols shape" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for contract-invalid delta object" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c8_registry_delta_failure_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_delta_fail"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_delta_fail"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      echo "delta backend unavailable" >&2
      return 1
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_delta_fail","project_id":"proj_delta_fail","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded after delta failure" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for delta failure" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for delta failure" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for delta failure" >&2
      failed=1
    elif ! jq -e '.error | test("delta generation failed closed|delta backend unavailable"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture delta failure reason" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist after delta failure" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called after delta failure" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c9_registry_invalid_status_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_invalid_status"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_invalid_status"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function","_status":"paused"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_invalid_status","project_id":"proj_invalid_status","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with invalid status enum" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for invalid status enum" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for invalid status enum" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for invalid status enum" >&2
      failed=1
    elif ! jq -e '.error | test("invalid changed_symbols status|active\\|inactive\\|incomplete\\|buggy\\|deprecated\\|deleted"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture invalid status enum" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for invalid status enum" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for invalid status enum" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c10_registry_partial_apply_recorded_on_late_failure() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_partial_apply"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_partial_apply"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/bar.sh:bar","name":"bar","module":"src/bar.sh","file":"src/bar.sh","kind":"function","_status":"inactive","_inactive_reason":"manual_hold"}],"impacted_symbols":[],"changed_files":["src/bar.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      case "$tool_name" in
        "sem.registry.upsert")
          echo '{"applied":true,"new_count":1,"updated_count":0}'
          ;;
        "sem.registry.set_status")
          echo "status backend unavailable" >&2
          return 1
          ;;
        *)
          return 1
          ;;
      esac
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_partial_apply","project_id":"proj_partial_apply","scope":["src/bar.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded after late mutator failure" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for late mutator failure" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for late mutator failure" >&2
      failed=1
    elif ! grep -q 'after partial apply artifact commit' "$tmpdir/state_error"; then
      echo "detail: state error did not reflect committed partial-apply artifact" >&2
      failed=1
    elif grep -q 'before apply artifact commit' "$tmpdir/state_error"; then
      echo "detail: state error incorrectly claimed failure before apply artifact commit" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: partial-apply artifact missing after late mutator failure" >&2
      failed=1
    elif ! jq -e '
      .partial_apply == true
      and .failing_tool == "sem.registry.set_status"
      and (.error | test("sem\\.registry\\.set_status|status backend unavailable"; "i"))
      and .summary.upserts == 1
      and .summary.set_status == 1
      and (.applied | length == 1)
      and (.applied[0].tool == "sem.registry.upsert")
      and (.applied[0].input.components[0].semantic_id == "src/bar.sh:bar")
    ' "$tmpdir/impl_coord_registry_apply_iter1.json" >/dev/null 2>&1; then
      echo "detail: partial-apply artifact did not capture successful calls and failing tool" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator call log missing for late mutator failure" >&2
      failed=1
    else
      local call_order=""
      call_order="$(cut -f1 "$tmpdir/mcp_calls.tsv" | paste -sd ',' -)"
      if [[ "$call_order" != "sem.registry.upsert,sem.registry.set_status" ]]; then
        echo "detail: unexpected mutator call order for late mutator failure: $call_order" >&2
        failed=1
      fi
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c11_registry_malformed_changed_symbol_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_bad_symbol"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_bad_symbol"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_bad_symbol","project_id":"proj_bad_symbol","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with malformed changed-symbol entry" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for malformed changed-symbol entry" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for malformed changed-symbol entry" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for malformed changed-symbol entry" >&2
      failed=1
    elif ! jq -e '.error | test("unable to normalize deterministic component|changed_symbols entries"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture malformed changed-symbol entry" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for malformed changed-symbol entry" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for malformed changed-symbol entry" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c12_registry_project_id_mismatch_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_project_id_mismatch"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_authoritative"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_project_id_mismatch","project_id":"proj_preflight","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with project_id mismatch" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for project_id mismatch" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for project_id mismatch" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for project_id mismatch" >&2
      failed=1
    elif ! jq -e '.error | test("project_id mismatch|proj_preflight|proj_authoritative"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture project_id mismatch" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for project_id mismatch" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for project_id mismatch" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c13_registry_legacy_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_legacy_project_id"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "agent_base"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_legacy_project_id","project_id":"proj_valid","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with legacy authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for legacy authoritative project_id" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for legacy authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for legacy authoritative project_id" >&2
      failed=1
    elif ! jq -e '.error | test("legacy project_id|agent_base"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture legacy authoritative project_id block" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for legacy authoritative project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for legacy authoritative project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c14_registry_invalid_project_id_format_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_invalid_project_id"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj invalid!"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_invalid_project_id","project_id":"proj_valid","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with invalid authoritative project_id format" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for invalid authoritative project_id format" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for invalid authoritative project_id format" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for invalid authoritative project_id format" >&2
      failed=1
    elif ! jq -e '.error | test("invalid semantic project_id|proj invalid!"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture invalid authoritative project_id format block" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for invalid authoritative project_id format" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for invalid authoritative project_id format" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c15_registry_missing_preflight_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_missing_preflight_project_id"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_authoritative"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_missing_preflight_project_id","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded without preflight project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for missing preflight project_id" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for missing preflight project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for missing preflight project_id" >&2
      failed=1
    elif ! jq -e '.error | test("missing project_id|required for authoritative registry mutation"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture missing preflight project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for missing preflight project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for missing preflight project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c16_apply_stage_missing_payload_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_apply_guard"; }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    payload_json="$(build_valid_apply_stage_payload "__omit__")"
    _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply_error.json"
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: apply-stage guard unexpectedly succeeded without payload project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply_error.json" ]]; then
      echo "detail: apply-stage error artifact missing for missing payload project_id" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 1
      and (.applied | length == 0)
      and .failing_tool == "project_id_guard"
      and (.error | test("missing authoritative project_id"; "i"))
    ' "$tmpdir/apply_error.json" >/dev/null 2>&1; then
      echo "detail: apply-stage error artifact did not capture missing payload project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for missing payload project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c17_apply_stage_invalid_payload_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_apply_guard"; }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    payload_json="$(build_valid_apply_stage_payload "proj invalid!")"
    _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply_error.json"
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: apply-stage guard unexpectedly succeeded with invalid payload project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply_error.json" ]]; then
      echo "detail: apply-stage error artifact missing for invalid payload project_id" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 1
      and (.applied | length == 0)
      and .failing_tool == "project_id_guard"
      and (.error | test("project_id is invalid"; "i"))
    ' "$tmpdir/apply_error.json" >/dev/null 2>&1; then
      echo "detail: apply-stage error artifact did not capture invalid payload project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for invalid payload project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c18_apply_stage_payload_project_id_mismatch_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_authoritative"; }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    payload_json="$(build_valid_apply_stage_payload "proj_payload")"
    _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply_error.json"
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: apply-stage guard unexpectedly succeeded with payload project_id mismatch" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply_error.json" ]]; then
      echo "detail: apply-stage error artifact missing for payload project_id mismatch" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 1
      and (.applied | length == 0)
      and .failing_tool == "project_id_guard"
      and (.error | test("project_id mismatch|proj_payload|proj_authoritative"; "i"))
    ' "$tmpdir/apply_error.json" >/dev/null 2>&1; then
      echo "detail: apply-stage error artifact did not capture payload project_id mismatch" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for payload project_id mismatch" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c20_apply_stage_nested_project_id_override_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_authoritative"; }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    payload_json="$(jq -nc '
      {
        task_id: "task_nested_override",
        phase: "impl",
        iteration: 1,
        project_id: "proj_authoritative",
        scope: ["src/foo.sh"],
        changed_files: ["src/foo.sh"],
        deleted_paths: [],
        move_candidates: [],
        mutations: {
          upserts: [],
          set_status: [
            {
              semantic_id: "src/foo.sh:foo",
              status: "inactive",
              project_id: "proj_evil"
            }
          ],
          deletes: []
        },
        summary: {
          upserts: 0,
          set_status: 1,
          deletes: 0
        }
      }
    ')"

    _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply_error.json"
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: apply-stage unexpectedly succeeded with nested mutation project_id override" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply_error.json" ]]; then
      echo "detail: apply-stage error artifact missing for nested mutation project_id override" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 0
      and .summary.set_status == 1
      and .summary.deletes == 0
      and (.applied | length == 0)
      and .failing_tool == "contract_guard"
      and (.error | test("contract invalid"; "i"))
    ' "$tmpdir/apply_error.json" >/dev/null 2>&1; then
      echo "detail: apply-stage error artifact did not capture nested mutation project_id override contract failure" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for nested mutation project_id override" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c19_registry_deleted_changed_symbol_status_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_deleted_status"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_deleted_status"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function","_status":"deleted"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      local tool_name="${1:-}"
      local payload="${2:-}"
      printf '%s\t%s\n' "$tool_name" "$payload" >> "$tmpdir/mcp_calls.tsv"
      return 0
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_deleted_status","project_id":"proj_deleted_status","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with deleted changed-symbol status" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for deleted changed-symbol status" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for deleted changed-symbol status" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for deleted changed-symbol status" >&2
      failed=1
    elif ! jq -e '.error | test("changed_symbols status|active\\|inactive\\|incomplete\\|buggy\\|deprecated"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture deleted changed-symbol status block" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for deleted changed-symbol status" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for deleted changed-symbol status" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c21_prepare_missing_authoritative_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_prepare_missing_project_id"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"
    coordination_context_unavailable="false"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    _coordination_resolve_semantic_project_id() { printf '\n'; }
    _coordination_context_update_changed_only() { echo '{"ok":true}'; }
    _coordination_collect_changed_files_json() { echo '["src/foo.sh"]'; }
    _coordination_context_detect_deletions() { echo '{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}'; }

    (
      prepare_coordination_context "$tmpdir" "impl" "prepare_missing_project_id"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: prepare_coordination_context unexpectedly succeeded without authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for missing authoritative project_id at prepare" >&2
      failed=1
    elif ! grep -q '^PREFLIGHT_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for missing authoritative project_id at prepare" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_preflight_input.json" ]]; then
      echo "detail: preflight_input artifact should not be written when authoritative project_id is unavailable" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_preflight.json" ]]; then
      echo "detail: fail-closed preflight artifact missing for missing authoritative project_id at prepare" >&2
      failed=1
    elif ! jq -e '.coordination_failure_reason | test("project_id is unavailable"; "i")' "$tmpdir/impl_coord_preflight.json" >/dev/null 2>&1; then
      echo "detail: preflight artifact did not capture missing authoritative project_id at prepare" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c22_prepare_legacy_authoritative_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_prepare_legacy_project_id"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"
    coordination_context_unavailable="false"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    _coordination_resolve_semantic_project_id() { echo "agent_base"; }
    _coordination_context_update_changed_only() { echo '{"ok":true}'; }
    _coordination_collect_changed_files_json() { echo '["src/foo.sh"]'; }
    _coordination_context_detect_deletions() { echo '{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}'; }

    (
      prepare_coordination_context "$tmpdir" "impl" "prepare_legacy_project_id"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: prepare_coordination_context unexpectedly succeeded with legacy authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for legacy authoritative project_id at prepare" >&2
      failed=1
    elif ! grep -q '^PREFLIGHT_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for legacy authoritative project_id at prepare" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_preflight_input.json" ]]; then
      echo "detail: preflight_input artifact should not be written for legacy authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_preflight.json" ]]; then
      echo "detail: fail-closed preflight artifact missing for legacy authoritative project_id at prepare" >&2
      failed=1
    elif ! jq -e '.coordination_failure_reason | test("legacy project_id|agent_base"; "i")' "$tmpdir/impl_coord_preflight.json" >/dev/null 2>&1; then
      echo "detail: preflight artifact did not capture legacy authoritative project_id at prepare" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c23_prepare_internal_whitespace_authoritative_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_prepare_internal_whitespace_project_id"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"
    coordination_context_unavailable="false"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    _coordination_resolve_semantic_project_id() { echo "proj evil"; }
    _coordination_context_update_changed_only() { echo '{"ok":true}'; }
    _coordination_collect_changed_files_json() { echo '["src/foo.sh"]'; }
    _coordination_context_detect_deletions() { echo '{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}'; }

    (
      prepare_coordination_context "$tmpdir" "impl" "prepare_internal_whitespace_project_id"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: prepare_coordination_context unexpectedly succeeded with internal-whitespace authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for internal-whitespace authoritative project_id at prepare" >&2
      failed=1
    elif ! grep -q '^PREFLIGHT_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for internal-whitespace authoritative project_id at prepare" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_preflight_input.json" ]]; then
      echo "detail: preflight_input artifact should not be written for internal-whitespace authoritative project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_preflight.json" ]]; then
      echo "detail: fail-closed preflight artifact missing for internal-whitespace authoritative project_id at prepare" >&2
      failed=1
    elif ! jq -e '.coordination_failure_reason | test("invalid semantic project_id|proj evil"; "i")' "$tmpdir/impl_coord_preflight.json" >/dev/null 2>&1; then
      echo "detail: preflight artifact did not capture internal-whitespace authoritative project_id at prepare" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c24_helper_resolution_fails_closed_without_canonical_resolver() {
  (
    set -u -o pipefail
    local failed=0
    local tmpdir
    local tmprepo
    local empty_resolver
    tmpdir="$(mktemp -d)"
    tmprepo="$tmpdir/repo"
    mkdir -p "$tmprepo"

    (
      # shellcheck source=/dev/null
      source "$AUTO_ORCHESTRATE"
      set +e
      REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local rc=0
      local stdout_file="$tmpdir/coord.stdout"
      local stderr_file="$tmpdir/coord.stderr"
      _coordination_require_authoritative_project_id >"$stdout_file" 2>"$stderr_file"
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "detail: coordination helper unexpectedly synthesized project_id without canonical resolver" >&2
        exit 1
      fi
      if [[ -s "$stdout_file" ]]; then
        echo "detail: coordination helper emitted project_id output despite missing canonical resolver" >&2
        exit 1
      fi
      if ! grep -qi 'semantic project_id is unavailable' "$stderr_file"; then
        echo "detail: coordination helper did not report unavailable project_id on missing canonical resolver" >&2
        exit 1
      fi
    ) || failed=1

    (
      # shellcheck source=/dev/null
      source "$CONTEXT_ANALYSIS"
      set +e
      CONTEXT_REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local rc=0
      local stdout_file="$tmpdir/registry.stdout"
      local stderr_file="$tmpdir/registry.stderr"
      _registry_require_project_id >"$stdout_file" 2>"$stderr_file"
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "detail: registry helper unexpectedly synthesized project_id without canonical resolver" >&2
        exit 1
      fi
      if [[ -s "$stdout_file" ]]; then
        echo "detail: registry helper emitted project_id output despite missing canonical resolver" >&2
        exit 1
      fi
      if ! grep -qi 'semantic project_id is unavailable' "$stderr_file"; then
        echo "detail: registry helper did not report unavailable project_id on missing canonical resolver" >&2
        exit 1
      fi
    ) || failed=1

    (
      # shellcheck source=/dev/null
      source "$CONTEXT_CAPSULE"
      set +e
      CONTEXT_CAPSULE_REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local rc=0
      local stdout_file="$tmpdir/capsule.stdout"
      local stderr_file="$tmpdir/capsule.stderr"
      _capsule_require_project_id >"$stdout_file" 2>"$stderr_file"
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "detail: capsule helper unexpectedly synthesized project_id without canonical resolver" >&2
        exit 1
      fi
      if [[ -s "$stdout_file" ]]; then
        echo "detail: capsule helper emitted project_id output despite missing canonical resolver" >&2
        exit 1
      fi
      if ! grep -qi 'semantic project_id is unavailable' "$stderr_file"; then
        echo "detail: capsule helper did not report unavailable project_id on missing canonical resolver" >&2
        exit 1
      fi
    ) || failed=1

    mkdir -p "$tmprepo/scripts"
    empty_resolver="$tmprepo/scripts/resolve-semantic-project-id.sh"
    cat > "$empty_resolver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '   \n'
EOF
    chmod +x "$empty_resolver"

    (
      # shellcheck source=/dev/null
      source "$AUTO_ORCHESTRATE"
      set +e
      REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local rc=0
      local stdout_file="$tmpdir/coord_empty.stdout"
      local stderr_file="$tmpdir/coord_empty.stderr"
      _coordination_require_authoritative_project_id >"$stdout_file" 2>"$stderr_file"
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "detail: coordination helper unexpectedly accepted empty canonical resolver output" >&2
        exit 1
      fi
      if [[ -s "$stdout_file" ]]; then
        echo "detail: coordination helper emitted project_id output despite empty canonical resolver output" >&2
        exit 1
      fi
      if ! grep -qi 'semantic project_id is unavailable' "$stderr_file"; then
        echo "detail: coordination helper did not report unavailable project_id on empty canonical resolver output" >&2
        exit 1
      fi
    ) || failed=1

    (
      # shellcheck source=/dev/null
      source "$CONTEXT_ANALYSIS"
      set +e
      CONTEXT_REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local rc=0
      local stdout_file="$tmpdir/registry_empty.stdout"
      local stderr_file="$tmpdir/registry_empty.stderr"
      _registry_require_project_id >"$stdout_file" 2>"$stderr_file"
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "detail: registry helper unexpectedly accepted empty canonical resolver output" >&2
        exit 1
      fi
      if [[ -s "$stdout_file" ]]; then
        echo "detail: registry helper emitted project_id output despite empty canonical resolver output" >&2
        exit 1
      fi
      if ! grep -qi 'semantic project_id is unavailable' "$stderr_file"; then
        echo "detail: registry helper did not report unavailable project_id on empty canonical resolver output" >&2
        exit 1
      fi
    ) || failed=1

    (
      # shellcheck source=/dev/null
      source "$CONTEXT_CAPSULE"
      set +e
      CONTEXT_CAPSULE_REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local rc=0
      local stdout_file="$tmpdir/capsule_empty.stdout"
      local stderr_file="$tmpdir/capsule_empty.stderr"
      _capsule_require_project_id >"$stdout_file" 2>"$stderr_file"
      rc=$?
      if [[ "$rc" -eq 0 ]]; then
        echo "detail: capsule helper unexpectedly accepted empty canonical resolver output" >&2
        exit 1
      fi
      if [[ -s "$stdout_file" ]]; then
        echo "detail: capsule helper emitted project_id output despite empty canonical resolver output" >&2
        exit 1
      fi
      if ! grep -qi 'semantic project_id is unavailable' "$stderr_file"; then
        echo "detail: capsule helper did not report unavailable project_id on empty canonical resolver output" >&2
        exit 1
      fi
    ) || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c25_helper_resolution_trims_edge_whitespace_only() {
  (
    set -u -o pipefail
    local failed=0
    local tmpdir
    local tmprepo
    local resolver
    tmpdir="$(mktemp -d)"
    tmprepo="$tmpdir/repo"
    resolver="$tmprepo/scripts/resolve-semantic-project-id.sh"
    mkdir -p "$tmprepo/scripts"

    cat > "$resolver" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

repo_root=""
mode=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo-root)
      repo_root="${2:-}"
      shift 2
      ;;
    --print)
      mode="print"
      shift
      ;;
    *)
      shift
      ;;
  esac
done

[[ -n "$repo_root" ]] || exit 1
[[ "$mode" == "print" ]] || exit 1
printf '  proj_trimmed  \n'
EOF
    chmod +x "$resolver"

    (
      # shellcheck source=/dev/null
      source "$AUTO_ORCHESTRATE"
      set +e
      REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local resolved=""
      resolved="$(_coordination_require_authoritative_project_id 2>"$tmpdir/coord_trim.stderr")"
      if [[ "$resolved" != "proj_trimmed" ]]; then
        echo "detail: coordination helper did not trim edge whitespace from canonical resolver output" >&2
        exit 1
      fi
    ) || failed=1

    (
      # shellcheck source=/dev/null
      source "$CONTEXT_ANALYSIS"
      set +e
      CONTEXT_REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local resolved=""
      resolved="$(_registry_require_project_id 2>"$tmpdir/registry_trim.stderr")"
      if [[ "$resolved" != "proj_trimmed" ]]; then
        echo "detail: registry helper did not trim edge whitespace from canonical resolver output" >&2
        exit 1
      fi
    ) || failed=1

    (
      # shellcheck source=/dev/null
      source "$CONTEXT_CAPSULE"
      set +e
      CONTEXT_CAPSULE_REPO_ROOT="$tmprepo"
      log_error() { printf '%s\n' "$*" >&2; }

      local resolved=""
      resolved="$(_capsule_require_project_id 2>"$tmpdir/capsule_trim.stderr")"
      if [[ "$resolved" != "proj_trimmed" ]]; then
        echo "detail: capsule helper did not trim edge whitespace from canonical resolver output" >&2
        exit 1
      fi
    ) || failed=1

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c26_finalize_preflight_edge_whitespace_project_id_passes() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_preflight_trim"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_trimmed"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[
  {"semantic_id":"src/trim.sh:trim","name":"trim","module":"src/trim.sh","file_path":"src/trim.sh","kind":"function","status":"active","exports":[],"imports":[]}
],"changed_files":["src/trim.sh"]}
JSON
    }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_preflight_trim","project_id":"  proj_trimmed  ","scope":["src/trim.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    if ! finalize_coordination_context "$tmpdir" "impl" 1 >"$tmpdir/finalize.out" 2>"$tmpdir/finalize.err"; then
      echo "detail: finalize_coordination_context unexpectedly failed for edge-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was invoked despite valid edge-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta artifact missing for edge-whitespace preflight project_id" >&2
      failed=1
    elif ! jq -e '.project_id == "proj_trimmed"' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta artifact did not normalize preflight project_id edge whitespace" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact missing for edge-whitespace preflight project_id" >&2
      failed=1
    elif ! jq -e '.summary.upserts == 1 and (.applied | length) == 1' "$tmpdir/impl_coord_registry_apply_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry apply artifact did not record successful mutation for edge-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator was not called for edge-whitespace preflight project_id" >&2
      failed=1
    elif ! awk -F '\t' '{print $2}' "$tmpdir/mcp_calls.tsv" | jq -s -e 'all(.[]; .project_id == "proj_trimmed")' >/dev/null 2>&1; then
      echo "detail: mutator payload did not preserve normalized authoritative project_id for edge-whitespace preflight project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c27_finalize_preflight_internal_whitespace_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_preflight_internal_ws"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_internal_ws"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[
  {"semantic_id":"src/ws.sh:ws","name":"ws","module":"src/ws.sh","file_path":"src/ws.sh","kind":"function","status":"active","exports":[],"imports":[]}
],"changed_files":["src/ws.sh"]}
JSON
    }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_preflight_internal_ws","project_id":"proj internal ws","scope":["src/ws.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" 1
    ) >"$tmpdir/finalize.out" 2>"$tmpdir/finalize.err"
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with internal-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for internal-whitespace preflight project_id" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for internal-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for internal-whitespace preflight project_id" >&2
      failed=1
    elif ! jq -e '.error | test("invalid semantic project_id|proj internal ws"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture internal-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for internal-whitespace preflight project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for internal-whitespace preflight project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c28_apply_stage_edge_whitespace_payload_project_id_passes() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_apply_trim"; }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    payload_json="$(build_valid_apply_stage_payload "  proj_apply_trim  ")"

    if ! _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply.json" >"$tmpdir/apply.out" 2>"$tmpdir/apply.err"; then
      echo "detail: apply stage unexpectedly failed for edge-whitespace payload project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply.json" ]]; then
      echo "detail: apply artifact missing for edge-whitespace payload project_id" >&2
      failed=1
    elif ! jq -e '.summary.upserts == 1 and (.applied | length) == 1' "$tmpdir/apply.json" >/dev/null 2>&1; then
      echo "detail: apply artifact did not record successful mutation for edge-whitespace payload project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator was not called for edge-whitespace payload project_id" >&2
      failed=1
    elif ! awk -F '\t' '{print $2}' "$tmpdir/mcp_calls.tsv" | jq -s -e 'all(.[]; .project_id == "proj_apply_trim")' >/dev/null 2>&1; then
      echo "detail: mutator payload did not preserve normalized authoritative project_id for edge-whitespace payload project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c29_apply_stage_internal_whitespace_payload_project_id_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_apply_internal_ws"; }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    payload_json="$(build_valid_apply_stage_payload "proj apply internal ws")"

    if _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply.json" >"$tmpdir/apply.out" 2>"$tmpdir/apply.err"; then
      echo "detail: apply stage unexpectedly succeeded with internal-whitespace payload project_id" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply.json" ]]; then
      echo "detail: apply-stage error artifact missing for internal-whitespace payload project_id" >&2
      failed=1
    elif ! jq -e '.failing_tool == "project_id_guard" and (.error | test("project_id is invalid"; "i"))' "$tmpdir/apply.json" >/dev/null 2>&1; then
      echo "detail: apply-stage error artifact did not capture internal-whitespace payload project_id" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for internal-whitespace payload project_id" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c30_tampered_payload_summary_mismatch_uses_authoritative_artifact_summary() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    local payload_json=""
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    _coordination_resolve_semantic_project_id() { echo "proj_tampered_summary"; }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    payload_json="$(
      build_valid_apply_stage_payload "proj_tampered_summary" | jq '
        .mutations.set_status = [
          {
            semantic_id: "src/foo.sh:foo",
            status: "inactive"
          }
        ]
        | .mutations.deletes = [
          {
            semantic_id: "src/old.sh:old",
            reason: "tampered payload delete"
          }
        ]
        | .summary = {
            upserts: 99,
            set_status: 77,
            deletes: 55
          }
      '
    )"

    if _coordination_apply_registry_delta_payload "$payload_json" "$tmpdir/apply.json" >"$tmpdir/apply.out" 2>"$tmpdir/apply.err"; then
      echo "detail: apply path unexpectedly succeeded for tampered payload summary mismatch" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/apply.json" ]]; then
      echo "detail: apply-stage error artifact missing for tampered payload summary mismatch" >&2
      failed=1
    elif ! jq -e '
      .summary.upserts == 1
      and .summary.set_status == 1
      and .summary.deletes == 1
      and .summary.upserts != 99
      and .summary.set_status != 77
      and .summary.deletes != 55
      and (.applied | length == 0)
      and .failing_tool == "contract_guard"
      and (.error | test("contract invalid: summary mismatch"; "i"))
    ' "$tmpdir/apply.json" >/dev/null 2>&1; then
      echo "detail: apply-stage error artifact did not preserve authoritative mutation counts for tampered payload summary mismatch" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for tampered payload summary mismatch" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c31_finalize_malformed_deletion_refresh_entries_block() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_bad_refresh"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_bad_refresh"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":["src/good.sh",123],"removed_symbols":["src/good.sh:good",{"bad":true}],"move_candidates":[{"old_path":"src/a.sh"},42]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_bad_refresh","project_id":"proj_bad_refresh","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "2"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with malformed deletion refresh entries" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for malformed deletion refresh entries" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for malformed deletion refresh entries" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter2.json" ]]; then
      echo "detail: registry delta error artifact missing for malformed deletion refresh entries" >&2
      failed=1
    elif ! jq -e '.error | test("finalize preflight refresh failed closed|invalid contract"; "i")' "$tmpdir/impl_coord_registry_delta_iter2.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture malformed deletion refresh entries" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter2.json" ]]; then
      echo "detail: registry apply artifact should not exist for malformed deletion refresh entries" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for malformed deletion refresh entries" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_c32_finalize_malformed_base_preflight_entries_block() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir
    tmpdir="$(mktemp -d)"

    REPO_ROOT="$tmpdir/repo"
    mkdir -p "$REPO_ROOT"
    STATE_FILE="$tmpdir/state.json"
    printf '{"task":{"id":"task_c1_bad_base_preflight"},"phases":[{"name":"impl","status":"running"}],"status":"running"}\n' > "$STATE_FILE"
    run_context_analysis="true"

    log_info() { :; }
    log_warn() { :; }
    log_debug() { :; }
    log_error() { :; }
    state_save() { :; }
    state_set_error() { printf '%s|%s|%s\n' "$1" "$2" "$3" > "$tmpdir/state_error"; }
    refresh_lock() { return 0; }
    _coordination_resolve_semantic_project_id() { echo "proj_bad_base_preflight"; }
    _coordination_context_detect_deletions() {
      cat <<'JSON'
{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}
JSON
    }
    _coordination_context_delta() {
      cat <<'JSON'
{"changed_symbols":[{"logical_id":"src/foo.sh:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh","kind":"function"}],"impacted_symbols":[],"changed_files":["src/foo.sh"]}
JSON
    }
    mcp_or_fallback() {
      printf '%s\t%s\n' "$1" "$2" >> "$tmpdir/mcp_calls.tsv"
      printf '%s\n' '{"ok":true}'
    }

    cat > "$tmpdir/impl_coord_preflight_input.json" <<'JSON'
{"task_id":"task_c1_bad_base_preflight","project_id":"proj_bad_base_preflight","scope":["src/foo.sh"],"proposed_components":[],"deleted_paths":[123],"removed_symbols":[{"bad":true}],"move_candidates":[{}]}
JSON

    (
      finalize_coordination_context "$tmpdir" "impl" "1"
    )
    local rc=$?
    if [[ "$rc" -eq 0 ]]; then
      echo "detail: finalize_coordination_context unexpectedly succeeded with malformed base preflight_input entries" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/state_error" ]]; then
      echo "detail: state_set_error was not invoked for malformed base preflight_input entries" >&2
      failed=1
    elif ! grep -q '^COORDINATION_MUTATION_BLOCK|' "$tmpdir/state_error"; then
      echo "detail: state error code mismatch for malformed base preflight_input entries" >&2
      failed=1
    fi

    if [[ ! -f "$tmpdir/impl_coord_registry_delta_iter1.json" ]]; then
      echo "detail: registry delta error artifact missing for malformed base preflight_input entries" >&2
      failed=1
    elif ! jq -e '.error | test("registry delta build failed closed|preflight_input invalid"; "i")' "$tmpdir/impl_coord_registry_delta_iter1.json" >/dev/null 2>&1; then
      echo "detail: registry delta error artifact did not capture malformed base preflight_input entries" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/impl_coord_registry_apply_iter1.json" ]]; then
      echo "detail: registry apply artifact should not exist for malformed base preflight_input entries" >&2
      failed=1
    fi

    if [[ -f "$tmpdir/mcp_calls.tsv" ]]; then
      echo "detail: mutator should not be called for malformed base preflight_input entries" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

run_test "C1" test_c1_registry_mutation_positive
run_test "C2" test_c2_registry_mutation_fail_closed
run_test "C3" test_c3_registry_invalid_json_response_fail_closed
run_test "C4" test_c4_registry_missing_preflight_blocks
run_test "C5" test_c5_registry_malformed_delta_blocks
run_test "C6" test_c6_registry_later_iteration_delete_refresh
run_test "C7" test_c7_registry_invalid_shape_blocks
run_test "C8" test_c8_registry_delta_failure_blocks
run_test "C9" test_c9_registry_invalid_status_blocks
run_test "C10" test_c10_registry_partial_apply_recorded_on_late_failure
run_test "C11" test_c11_registry_malformed_changed_symbol_blocks
run_test "C12" test_c12_registry_project_id_mismatch_blocks
run_test "C13" test_c13_registry_legacy_project_id_blocks
run_test "C14" test_c14_registry_invalid_project_id_format_blocks
run_test "C15" test_c15_registry_missing_preflight_project_id_blocks
run_test "C16" test_c16_apply_stage_missing_payload_project_id_blocks
run_test "C17" test_c17_apply_stage_invalid_payload_project_id_blocks
run_test "C18" test_c18_apply_stage_payload_project_id_mismatch_blocks
run_test "C19" test_c19_registry_deleted_changed_symbol_status_blocks
run_test "C20" test_c20_apply_stage_nested_project_id_override_blocks
run_test "C21" test_c21_prepare_missing_authoritative_project_id_blocks
run_test "C22" test_c22_prepare_legacy_authoritative_project_id_blocks
run_test "C23" test_c23_prepare_internal_whitespace_authoritative_project_id_blocks
run_test "C24" test_c24_helper_resolution_fails_closed_without_canonical_resolver
run_test "C25" test_c25_helper_resolution_trims_edge_whitespace_only
run_test "C26" test_c26_finalize_preflight_edge_whitespace_project_id_passes
run_test "C27" test_c27_finalize_preflight_internal_whitespace_project_id_blocks
run_test "C28" test_c28_apply_stage_edge_whitespace_payload_project_id_passes
run_test "C29" test_c29_apply_stage_internal_whitespace_payload_project_id_blocks
run_test "C30" test_c30_tampered_payload_summary_mismatch_uses_authoritative_artifact_summary
run_test "C31" test_c31_finalize_malformed_deletion_refresh_entries_block
run_test "C32" test_c32_finalize_malformed_base_preflight_entries_block

printf '\nRESULT: pass=%d fail=%d\n' "$PASS_COUNT" "$FAIL_COUNT"
if [[ "$FAIL_COUNT" -ne 0 ]]; then
  exit 1
fi
