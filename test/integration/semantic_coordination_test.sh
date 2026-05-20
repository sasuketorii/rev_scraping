#!/usr/bin/env bash
# Integration tests for semantic coordination (ExecPlan v6 Task 6.1)

set -u

if [[ "${SEMANTIC_INTEGRATION_SYSTEM_BASH_REEXEC:-0}" != "1" && "${BASH:-}" != "/bin/bash" && -x /bin/bash ]]; then
  export SEMANTIC_INTEGRATION_SYSTEM_BASH_REEXEC=1
  exec /bin/bash "$0" "$@"
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/.claude/commands/lib"
AUTO_ORCHESTRATE="$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh"
POLICY_PROJECTION_SOURCE="$PROJECT_ROOT/.agent/registry/orchestration_policy_projection.json"
PROJECT_RUST_SEMANTIC_BIN="$(
  /bin/bash "$PROJECT_ROOT/scripts/semantic-review-queue.sh" \
    __internal-rust-workspace-root \
    --repo-root "$PROJECT_ROOT"
)/target/debug/semantic-mcp"
PROJECT_NODE_RUNTIME_BINARY=""
PROJECT_NODE_RUNTIME_PATH=""
PROJECT_NODE_RUNTIME_HOME=""

PASS_COUNT=0
FAIL_COUNT=0

ALL_TEST_IDS=(M1 M2 M3 M4 M5 M6 M7 M8 M9 M10 M11 M12)

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd" >&2
    exit 2
  fi
}

contains_text() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" == *"$needle"* ]]
}

load_project_node_runtime_env() {
  local runtime_env=""

  runtime_env="$(
    /bin/bash "$PROJECT_ROOT/scripts/semantic-review-queue.sh" \
      __internal-runtime-env \
      --binary node \
      --repo-root "$PROJECT_ROOT"
  )" || {
    echo "ERROR: failed to resolve trusted node runtime" >&2
    exit 2
  }

  unset RUNTIME_BINARY RUNTIME_PATH RUNTIME_HOME
  eval "$runtime_env"

  [[ -n "${RUNTIME_BINARY:-}" ]] || {
    echo "ERROR: trusted node runtime binary missing" >&2
    exit 2
  }
  [[ -n "${RUNTIME_PATH:-}" ]] || {
    echo "ERROR: trusted node runtime PATH missing" >&2
    exit 2
  }
  [[ -n "${RUNTIME_HOME:-}" ]] || {
    echo "ERROR: trusted node runtime HOME missing" >&2
    exit 2
  }

  PROJECT_NODE_RUNTIME_BINARY="$RUNTIME_BINARY"
  PROJECT_NODE_RUNTIME_PATH="$(cd "$(dirname "$RUNTIME_BINARY")" && pwd -P):$RUNTIME_PATH"
  PROJECT_NODE_RUNTIME_HOME="$RUNTIME_HOME"
}

test_description() {
  local id="${1:-}"
  case "$id" in
    M1) echo "capsule_build output is <= 220 tokens" ;;
    M2) echo "_reviewer_build_packet builds diff-centered packet without full coder output" ;;
    M3) echo "shadow_verify_loop handles pass path and escalation path within 3 attempts" ;;
    M4) echo "preflight fallback and orchestration failures are fail-closed with BLOCK contract" ;;
    M5) echo "select_window completes through regex fallback without tree-sitter" ;;
    M6) echo "graph_rank_symbols returns PageRank top-k ranking" ;;
    M7) echo "auto_orchestrate blocks fail-closed when coordination modules are absent" ;;
    M8) echo "batch review runtime uses DB lease state for strict queue completion and ignores legacy JSON authority" ;;
    M9) echo "batch review rejects invalid project_id from lease and runtime state" ;;
    M10) echo "auto_orchestrate uses direct script entrypoints for capsule and shadow verify" ;;
    M11) echo "semantic preflight/capsule expose target-lock, empty-scope, and duplicate-risk fail-closed signals" ;;
    M12) echo "Node and Rust startup stay aligned on a stamped current schema fixture" ;;
    *) return 1 ;;
  esac
}

test_m1_capsule_budget() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local tmpdir response rc total_tokens body_tokens
    tmpdir="$(mktemp -d)"

    CONTEXT_CAPSULE_REPO_ROOT="$tmpdir/repo"
    mkdir -p "$CONTEXT_CAPSULE_REPO_ROOT"
    CONTEXT_CAPSULE_TMP_DIR="$tmpdir/.capsule"
    CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
    CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$tmpdir/context_analysis.sh"
    : > "$CONTEXT_CAPSULE_CONTEXT_ANALYSIS"

    _capsule_context_call_json() {
      local fallback="${1:-}"
      shift || true
      local subcommand="${1:-}"
      case "$subcommand" in
        diff-impact)
          echo '{"changed_symbols":["symA"],"impacted_symbols":["symB"],"changed_files":["src/a.sh"]}'
          ;;
        graph-rank)
          echo '{"ranked_symbols":[{"logical_id":"m:symA","name":"symA","file":"src/a.sh","line":1}],"adjacency_path":""}'
          ;;
        registry-query)
          echo '[]'
          ;;
        *)
          echo "$fallback"
          ;;
      esac
    }

    _capsule_collect_changed_files_json() { echo '["src/a.sh"]'; }
    _capsule_collect_changed_symbols_json() { echo '["symA"]'; }
    _capsule_build_preflight_input_json() { echo '{"move_candidates":[],"removed_symbols":[],"_idem_recalc_required":false}'; }
    _capsule_collect_security_pins_json() { echo '[]'; }
    _capsule_is_security_sensitive_json() { echo '{"sensitive":false,"reason":"none"}'; }
    _capsule_collect_conflicts_value() { echo 'none'; }
    _capsule_delete_impacts_summary() { echo 'none'; }
    _capsule_prepare_figma_summary_ref() { echo ''; }

    response="$(capsule_build "task6_1" "coder" --budget 220)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: capsule_build failed (rc=$rc)" >&2
      failed=1
    fi

    if ! printf '%s\n' "$response" | jq -e '.capsule and (.constraints | type == "array") and (.hints | type == "array")' >/dev/null 2>&1; then
      echo "detail: capsule_build response is not valid expected JSON shape" >&2
      failed=1
    fi

    total_tokens="$(_estimate_tokens "$response")"
    body_tokens="$(_estimate_tokens "$(printf '%s\n' "$response" | jq -r '.capsule // ""')")"

    if [[ "$total_tokens" -gt 220 ]]; then
      echo "detail: response token estimate exceeded 220 (actual=$total_tokens)" >&2
      failed=1
    fi

    if [[ "$body_tokens" -gt 200 ]]; then
      echo "detail: capsule body token estimate exceeded 200 (actual=$body_tokens)" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m2_reviewer_packet_diff_centered() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/utils.sh"
    # shellcheck source=/dev/null
    source "$LIB_DIR/reviewer.sh"
    set +e

    local failed=0
    local tmpdir outdir coder_output packet_file packet_content rc token_count
    tmpdir="$(mktemp -d)"
    outdir="$tmpdir/out"
    mkdir -p "$outdir"
    coder_output="$tmpdir/coder_output.md"
    packet_file=""

    {
      local i=1
      while [[ "$i" -le 140 ]]; do
        printf 'line-%03d\n' "$i"
        i=$((i + 1))
      done
      echo "FULL_CONTEXT_ONLY_SENTINEL"
    } > "$coder_output"

    _reviewer_use_full_context() { return 1; }
    _reviewer_detect_security_reviewer_mode() { echo "false|none"; }
    _reviewer_repo_root() { echo "$tmpdir"; }
    _reviewer_collect_changed_files_json() { echo '["src/main.sh"]'; }
    _reviewer_collect_diff_impact_json() { echo '{"changed_symbols":["foo"],"impacted_symbols":["bar"],"changed_files":["src/main.sh"]}'; }
    _reviewer_build_changed_symbols_section() { echo '- foo (function)'; }
    _reviewer_build_change_impact_graph() { echo 'foo -> bar'; }
    _reviewer_extract_delete_impacts_summary() { echo 'none'; }
    _reviewer_build_architecture_convention_capsule() { echo 'capsule-ctx'; }
    _reviewer_collect_shadow_verify_section() { echo 'lint=pass,typecheck=pass,test=pass'; }
    _reviewer_collect_diff_text() {
      cat <<'DIFF'
diff --git a/src/main.sh b/src/main.sh
@@ -1 +1 @@
-old
+new
DIFF
    }

    packet_file="$(_reviewer_build_packet "$coder_output" "$outdir" "impl" "impl")"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _reviewer_build_packet failed (rc=$rc)" >&2
      failed=1
    fi

    if [[ "$packet_file" == "$coder_output" ]]; then
      echo "detail: packet builder returned full coder output path unexpectedly" >&2
      failed=1
    fi

    if [[ ! -f "$packet_file" ]]; then
      echo "detail: packet file was not created: $packet_file" >&2
      failed=1
    else
      packet_content="$(cat "$packet_file")"
      token_count="$(_reviewer_estimate_tokens "$packet_content")"

      if ! contains_text "# Reviewer Input Packet (diff-centered)" "$packet_content"; then
        echo "detail: diff-centered header missing in packet" >&2
        failed=1
      fi
      if ! contains_text "## diff" "$packet_content"; then
        echo "detail: diff section missing in packet" >&2
        failed=1
      fi
      if ! contains_text "mode=diff-centered" "$packet_content"; then
        echo "detail: diff-centered mode metadata missing in packet" >&2
        failed=1
      fi
      if contains_text "FULL_CONTEXT_ONLY_SENTINEL" "$packet_content"; then
        echo "detail: packet unexpectedly contains full coder output sentinel" >&2
        failed=1
      fi
      if [[ "$token_count" -gt 1200 ]]; then
        echo "detail: packet token estimate exceeded 1200 (actual=$token_count)" >&2
        failed=1
      fi
    fi

    if [[ -n "$packet_file" ]]; then
      /bin/rm -f "$packet_file"
    fi
    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m3_shadow_verify_fix_loop() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/shadow_verify.sh"
    set +e

    local failed=0
    local tmpdir counter_file out rc final_count
    local tmpdir_fail counter_file_fail out_fail rc_fail final_count_fail escalation_report
    tmpdir="$(mktemp -d)"
    counter_file="$tmpdir/mock_count"
    echo "0" > "$counter_file"

    SHADOW_VERIFY_MAX_ATTEMPTS=3
    shadow_verify_run() {
      local count
      count="$(cat "$counter_file")"
      count=$((count + 1))
      echo "$count" > "$counter_file"

      local diag="$tmpdir/diag_${count}.txt"
      printf 'diag attempt %s\n' "$count" > "$diag"

      if [[ "$count" -lt 3 ]]; then
        jq -nc --arg diag "$diag" --argjson attempt "$count" '{status:"fail", diagnostics:$diag, attempt:$attempt}'
        return 1
      fi

      jq -nc --arg diag "$diag" --argjson attempt "$count" '{status:"pass", diagnostics:$diag, attempt:$attempt}'
      return 0
    }

    out="$(shadow_verify_loop --phase impl --iter 1 --workdir "$tmpdir")"
    rc=$?
    final_count="$(cat "$counter_file")"

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: shadow_verify_loop failed (rc=$rc)" >&2
      failed=1
    fi
    if [[ "$final_count" -ne 3 ]]; then
      echo "detail: shadow_verify_loop did not stop at 3 attempts (actual=$final_count)" >&2
      failed=1
    fi
    if ! contains_text '"status":"pass"' "$out"; then
      echo "detail: final output did not include pass status" >&2
      failed=1
    fi
    if ! contains_text '"attempt":3' "$out"; then
      echo "detail: final output did not include third attempt result" >&2
      failed=1
    fi

    tmpdir_fail="$(mktemp -d)"
    counter_file_fail="$tmpdir_fail/mock_count"
    echo "0" > "$counter_file_fail"

    shadow_verify_run() {
      local count
      count="$(cat "$counter_file_fail")"
      count=$((count + 1))
      echo "$count" > "$counter_file_fail"

      local diag="$tmpdir_fail/diag_${count}.txt"
      printf 'diag fail attempt %s\n' "$count" > "$diag"
      jq -nc --arg diag "$diag" --argjson attempt "$count" '{status:"fail", diagnostics:$diag, attempt:$attempt}'
      return 1
    }

    out_fail="$(shadow_verify_loop --phase impl --iter 1 --workdir "$tmpdir_fail")"
    rc_fail=$?
    final_count_fail="$(cat "$counter_file_fail")"
    escalation_report="$(printf '%s\n' "$out_fail" | grep -Eo '/[^[:space:]]+_shadow_escalation_[0-9]{8}T[0-9]{6}Z\.md' | tail -n 1 || true)"

    if [[ "$rc_fail" -eq 0 ]]; then
      echo "detail: shadow_verify_loop unexpectedly succeeded on always-fail path" >&2
      failed=1
    fi
    if [[ "$final_count_fail" -ne 3 ]]; then
      echo "detail: always-fail path did not stop at 3 attempts (actual=$final_count_fail)" >&2
      failed=1
    fi
    if [[ -z "$escalation_report" ]]; then
      echo "detail: escalation report path was not emitted on always-fail path" >&2
      failed=1
    elif [[ ! -f "$escalation_report" ]]; then
      echo "detail: escalation report file was not created: $escalation_report" >&2
      failed=1
    else
      if ! grep -q '^# Shadow Verify Escalation Report' "$escalation_report"; then
        echo "detail: escalation report header missing" >&2
        failed=1
      fi
      if ! grep -q -- '- Attempts: 3 / 3' "$escalation_report"; then
        echo "detail: escalation report attempt summary missing" >&2
        failed=1
      fi
    fi

    /bin/rm -rf "$tmpdir"
    /bin/rm -rf "$tmpdir_fail"
    [[ "$failed" -eq 0 ]]
  )
}

test_m4_preflight_fail_closed() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local out rc
    MCP_FORCE_CLI_FALLBACK=1

    out="$(mcp_or_fallback "sem.preflight" '{}')"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: mcp_or_fallback returned non-zero (rc=$rc)" >&2
      failed=1
    fi

    if ! printf '%s\n' "$out" | jq -e '
      .verdict == "BLOCK"
      and (.conflicts | type == "array")
      and ((.conflicts | length) == 1)
      and (.conflicts[0].semantic_id == "sem.preflight")
      and (.delete_impacts_summary | contains("authority:blocked"))
      and (.capsule | contains("PREFLIGHT=BLOCK"))
    ' >/dev/null 2>&1; then
      echo "detail: sem.preflight fallback did not return fail-closed BLOCK contract" >&2
      failed=1
    fi

    unset MCP_FORCE_CLI_FALLBACK
    mcp_call() {
      local tool_name="${1:-}"
      case "$tool_name" in
        "sem.health")
          echo '{"ok":true}'
          return 0
          ;;
        "sem.preflight")
          echo '{"jsonrpc":"2.0","id":"2","error":{"code":-32000,"message":"backend unavailable"}}'
          return 0
          ;;
        *)
          return 1
          ;;
      esac
    }

    out="$(mcp_or_fallback "sem.preflight" '{}')"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: mcp_or_fallback returned non-zero on JSON-RPC error payload (rc=$rc)" >&2
      failed=1
    fi

    if ! printf '%s\n' "$out" | jq -e '
      .verdict == "BLOCK"
      and (.conflicts | type == "array")
      and ((.conflicts | length) == 1)
      and (.conflicts[0].semantic_id == "sem.preflight")
      and (.delete_impacts_summary | contains("authority:blocked"))
      and (.capsule | contains("PREFLIGHT=BLOCK"))
    ' >/dev/null 2>&1; then
      echo "detail: JSON-RPC error payload was not translated to fail-closed BLOCK contract" >&2
      failed=1
    fi

    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local merge_tmpdir merge_out merge_rc
    merge_tmpdir="$(mktemp -d)"
    mkdir -p "$merge_tmpdir/repo/worktree/.agent/registry"

    git() {
      if [[ "${1:-}" == "-C" && "${3:-}" == "rev-parse" && "${4:-}" == "--show-toplevel" ]]; then
        printf '%s\n' "$merge_tmpdir/repo"
        return 0
      fi
      return 1
    }

    merge_out="$(check_merge_gate "$merge_tmpdir/repo/worktree" main 2>/dev/null)"
    merge_rc=$?

    if [[ "$merge_rc" -ne 0 ]]; then
      echo "detail: check_merge_gate returned non-zero for missing registry authority case (rc=$merge_rc)" >&2
      failed=1
    fi
    if ! printf '%s\n' "$merge_out" | jq -e '
      .gate == "block"
      and .reconcile_required == true
      and .state == "reconcile_pending"
      and (.conflicts | type == "array")
      and ((.conflicts | length) == 1)
      and (.conflicts[0].failure_kind == "missing_or_empty_source_registry")
      and (.conflicts[0].reason | contains("merge-gate authority unavailable"))
    ' >/dev/null 2>&1; then
      echo "detail: check_merge_gate did not fail closed when source registry authority was missing" >&2
      failed=1
    fi

    local merge_authority_tmpdir merge_authority_out merge_authority_rc
    merge_authority_tmpdir="$(mktemp -d)"
    mkdir -p "$merge_authority_tmpdir/repo/worktree/.agent/registry" "$merge_authority_tmpdir/repo/peer"
    cat > "$merge_authority_tmpdir/repo/worktree/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"cmp:1","semantic_id":"cmp:1","_idem":"idem-1","_updated":"2026-04-05T00:00:00Z"}
JSONL

    git() {
      if [[ "${1:-}" == "-C" ]]; then
        local cwd="${2:-}"
        shift 2
        case "${1:-}" in
          rev-parse)
            if [[ "${2:-}" == "--show-toplevel" ]]; then
              printf '%s\n' "$merge_authority_tmpdir/repo"
              return 0
            fi
            if [[ "$cwd" == "$merge_authority_tmpdir/repo/worktree" && "${2:-}" == "--verify" ]]; then
              return 1
            fi
            ;;
          worktree)
            if [[ "${2:-}" == "list" && "${3:-}" == "--porcelain" ]]; then
              printf 'worktree %s\n' "$merge_authority_tmpdir/repo/worktree"
              printf 'worktree %s\n' "$merge_authority_tmpdir/repo/peer"
              return 0
            fi
            ;;
          merge-base)
            printf 'base-commit\n'
            return 0
            ;;
          show)
            case "${2:-}" in
              base-commit:.agent/registry/components.jsonl|HEAD:.agent/registry/components.jsonl)
                printf '%s\n' '{"logical_id":"cmp:1","semantic_id":"cmp:1","_idem":"idem-1","_updated":"2026-04-05T00:00:00Z"}'
                return 0
                ;;
            esac
            ;;
        esac
      fi
      return 1
    }

    merge_authority_out="$(check_merge_gate "$merge_authority_tmpdir/repo/worktree" main 2>/dev/null)"
    merge_authority_rc=$?

    if [[ "$merge_authority_rc" -ne 0 ]]; then
      echo "detail: check_merge_gate returned non-zero for peer authority unavailable case (rc=$merge_authority_rc)" >&2
      failed=1
    fi
    if ! printf '%s\n' "$merge_authority_out" | jq -e '
      .gate == "block"
      and .reconcile_required == true
      and .state == "reconcile_pending"
      and (.conflicts | type == "array")
      and ((.conflicts | length) == 1)
      and (.conflicts[0].failure_kind == "authoritative_merge_gate_unavailable")
      and (.conflicts[0].reason | contains("merge-gate authority unavailable"))
    ' >/dev/null 2>&1; then
      echo "detail: check_merge_gate did not fail closed when peer worktree required authoritative merge-gate data" >&2
      failed=1
    fi

    unset -f git
    /bin/rm -rf "$merge_tmpdir"
    /bin/rm -rf "$merge_authority_tmpdir"

    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local tmpdir plan_file preflight_file prep_out prep_rc
    tmpdir="$(mktemp -d)"
    plan_file="$tmpdir/plan.md"
    preflight_file="$tmpdir/work/impl_coord_preflight.json"
    mkdir -p "$tmpdir/work"
    cat > "$plan_file" <<'PLAN'
# semantic preflight fail-closed test plan
PLAN

    state_init "$plan_file" "semantic_preflight_fail_closed" "$tmpdir/state" >/dev/null
    state_upsert_phase "impl" 1
    state_set '.status' '"running"'
    state_set_phase_status "impl" "running"
    state_save

    run_context_analysis=true
    _coordination_collect_changed_files_json() { echo '["src/a.sh"]'; }
    _coordination_context_update_changed_only() { echo '{"updated":true}'; }
    _coordination_context_detect_deletions() { echo '{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}'; }
    _coordination_require_src_sync_freshness() { return 0; }
    _coordination_preflight_check() {
      echo "simulated preflight failure" >&2
      return 23
    }

    prep_out="$(prepare_coordination_context "$tmpdir/work" "impl" "task_semantic_preflight" 2>&1)"
    prep_rc=$?

    if [[ "$prep_rc" -eq 0 ]]; then
      echo "detail: prepare_coordination_context unexpectedly succeeded after preflight failure" >&2
      failed=1
    fi
    if ! contains_text "Coordination preflight failed closed" "$prep_out"; then
      echo "detail: orchestration path did not report fail-closed preflight block" >&2
      failed=1
    fi
    if [[ ! -f "$preflight_file" ]]; then
      echo "detail: fail-closed preflight file was not written: $preflight_file" >&2
      failed=1
    elif ! jq -e '
      .verdict == "BLOCK"
      and (.conflicts | type == "array")
      and (.conflicts[0].semantic_id == "sem.preflight")
      and (.coordination_failure_reason | contains("simulated preflight failure"))
    ' "$preflight_file" >/dev/null 2>&1; then
      echo "detail: fail-closed preflight file did not contain expected BLOCK contract" >&2
      failed=1
    fi
    if ! jq -e '.error.code == "PREFLIGHT_BLOCK" and .error.phase == "impl"' "$STATE_FILE" >/dev/null 2>&1; then
      echo "detail: state did not record PREFLIGHT_BLOCK after fail-closed preflight" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m5_select_window_regex_fallback() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local result rc

    _capsule_context_call_json() {
      local fallback="${1:-}"
      shift || true
      local subcommand="${1:-}"
      case "$subcommand" in
        diff-impact)
          echo '{"changed_symbols":["foo"],"impacted_symbols":[],"changed_files":["src/a.sh"]}'
          ;;
        graph-rank)
          echo '{"ranked_symbols":[{"logical_id":"m:foo","name":"foo","file":"src/a.sh","line":1}],"adjacency_path":""}'
          ;;
        *)
          echo "$fallback"
          ;;
      esac
    }

    _capsule_collect_changed_files_json() { echo '["src/a.sh"]'; }
    _capsule_tree_sitter_available() { echo "false"; }
    _capsule_windows_from_diff_hunks() { echo '[]'; }
    _capsule_windows_from_regex_density() {
      echo '[{"path":"src/a.sh","start":1,"end":12,"kind":"primary","reason":"regex_symbol_density","source":"regex_fallback"}]'
    }
    _capsule_dependency_window() { echo '[]'; }

    result="$(select_window coder HEAD~1 HEAD 0)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: select_window failed (rc=$rc)" >&2
      failed=1
    fi

    if ! printf '%s\n' "$result" | jq -e '.tree_sitter_available == false and .tree_sitter_used == false and .selection_algorithm == "regex_symbol_density" and ((.windows | length) >= 1)' >/dev/null 2>&1; then
      echo "detail: regex fallback path was not selected as expected" >&2
      failed=1
    fi

    [[ "$failed" -eq 0 ]]
  )
}

test_m6_graph_rank_topk() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir out rc
    tmpdir="$(mktemp -d)"

    CONTEXT_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CONTEXT_DIR="$CONTEXT_REPO_ROOT/.agent/context"
    CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
    mkdir -p "$CONTEXT_REPOMAP_DIR"

    _context_ensure_git_repo() { return 0; }
    _context_has_repomap() { return 0; }
    _context_load_all_symbols_array() {
      cat <<'JSON'
[
  {"logical_id":"m:A","name":"A","kind":"function","file":"src/a.sh","line":1},
  {"logical_id":"m:B","name":"B","kind":"function","file":"src/b.sh","line":1},
  {"logical_id":"m:C","name":"C","kind":"function","file":"src/c.sh","line":1}
]
JSON
    }
    _context_collect_changed_files() { printf '%s\n' "src/a.sh" "src/b.sh" "src/c.sh"; }
    _context_collect_new_files() { :; }
    _context_build_adjacency_jsonl() {
      local _symbols_json="$1"
      local output_jsonl="$2"
      cat > "$output_jsonl" <<'JSONL'
{"source_logical_id":"m:A","target_logical_id":"m:B","relation_type":"symbol_ref"}
{"source_logical_id":"m:C","target_logical_id":"m:B","relation_type":"symbol_ref"}
{"source_logical_id":"m:B","target_logical_id":"m:B","relation_type":"symbol_ref"}
JSONL
    }

    out="$(graph_rank_symbols --top-k 2)"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: graph_rank_symbols failed (rc=$rc)" >&2
      failed=1
    fi

    if ! printf '%s\n' "$out" | jq -e '.top_k == 2 and (.ranked_symbols | length) == 2 and .ranked_symbols[0].logical_id == "m:B" and .ranked_symbols[0].score >= .ranked_symbols[1].score' >/dev/null 2>&1; then
      echo "detail: graph_rank_symbols did not return expected top-k ranking" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m7_missing_context_analysis_blocks() {
  (
    set -u -o pipefail
    set +e

    local failed=0
    local tmpdir out rc
    local plan_file coder_output_file state_file task_name run_out run_rc
    tmpdir="$(mktemp -d)"
    mkdir -p "$tmpdir/.claude/commands/lib" "$tmpdir/.agent/registry"

    /bin/cp "$AUTO_ORCHESTRATE" "$tmpdir/.claude/commands/auto_orchestrate.sh"
    /bin/cp "$LIB_DIR/utils.sh" "$tmpdir/.claude/commands/lib/utils.sh"
    /bin/cp "$LIB_DIR/state.sh" "$tmpdir/.claude/commands/lib/state.sh"
    /bin/cp "$LIB_DIR/timeout.sh" "$tmpdir/.claude/commands/lib/timeout.sh"
    /bin/cp "$LIB_DIR/session.sh" "$tmpdir/.claude/commands/lib/session.sh"
    /bin/cp "$LIB_DIR/coder.sh" "$tmpdir/.claude/commands/lib/coder.sh"
    /bin/cp "$LIB_DIR/reviewer.sh" "$tmpdir/.claude/commands/lib/reviewer.sh"
    /bin/cp "$LIB_DIR/orchestration_packet.sh" "$tmpdir/.claude/commands/lib/orchestration_packet.sh"
    /bin/cp "$POLICY_PROJECTION_SOURCE" "$tmpdir/.agent/registry/orchestration_policy_projection.json"

    out="$(/bin/bash "$tmpdir/.claude/commands/auto_orchestrate.sh" --help 2>&1)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: auto_orchestrate --help failed in compatibility setup (rc=$rc)" >&2
      failed=1
    fi
    if ! contains_text "Usage: auto_orchestrate.sh" "$out"; then
      echo "detail: usage output missing in compatibility setup" >&2
      failed=1
    fi
    if ! contains_text "context_analysis.sh未配置: coordination preflight は fail-closed で停止" "$out"; then
      echo "detail: context_analysis fail-closed warning missing" >&2
      failed=1
    fi
    if ! contains_text "context_capsule.sh未配置: カプセル注入をスキップ" "$out"; then
      echo "detail: context_capsule compatibility warning missing" >&2
      failed=1
    fi
    if ! contains_text "shadow_verify.sh未配置: 機械検証ゲートをスキップしreviewerへ継続" "$out"; then
      echo "detail: shadow_verify compatibility warning missing" >&2
      failed=1
    fi

    mkdir -p "$tmpdir/.agent/active" "$tmpdir/.claude/tmp"
    plan_file="$tmpdir/.agent/active/plan_semantic_compat.md"
    coder_output_file="$tmpdir/.claude/tmp/impl_coder.md"
    cat > "$plan_file" <<'PLAN'
# semantic coordination fail-closed test plan
PLAN
    cat > "$coder_output_file" <<'CODER'
# coder output (fail-closed test)
CODER

    run_out="$(PATH="/bin:/usr/bin:/opt/homebrew/bin:/usr/sbin:/sbin" /bin/bash "$tmpdir/.claude/commands/auto_orchestrate.sh" --plan "$plan_file" --phase impl --coder-output "$coder_output_file" --max-iterations 1 2>&1)"
    run_rc=$?
    task_name="$(basename "$plan_file")"
    task_name="${task_name%.*}"
    state_file="$tmpdir/.claude/tmp/$task_name/state.json"

    if [[ "$run_rc" -eq 0 ]]; then
      echo "detail: auto_orchestrate unexpectedly succeeded without context_analysis.sh" >&2
      failed=1
    fi
    if ! contains_text "Coordination preflight failed closed" "$run_out"; then
      echo "detail: missing context_analysis did not fail closed" >&2
      failed=1
    fi
    if contains_text "=== Orchestration Complete ===" "$run_out"; then
      echo "detail: fail-closed run should not reach completion log" >&2
      failed=1
    fi
    if [[ ! -f "$state_file" ]]; then
      echo "detail: state file was not created in fail-closed flow: $state_file" >&2
      failed=1
    elif ! jq -e '.error.code == "PREFLIGHT_BLOCK" and .error.phase == "impl"' "$state_file" >/dev/null 2>&1; then
      echo "detail: fail-closed flow did not record PREFLIGHT_BLOCK in state" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m8_batch_review_runtime_uses_db_lease_state() {
  (
    set -u -o pipefail
    set +e

    local failed=0
    local tmpdir outdir workdir plan_file state_file review_output complete_args_file
    local run_out run_rc
    tmpdir="$(mktemp -d)"
    outdir="$tmpdir/.claude/commands"
    workdir="$tmpdir/work"
    complete_args_file="$tmpdir/queue_complete_args.txt"
    mkdir -p "$outdir/lib" "$tmpdir/.claude/tmp" "$tmpdir/.agent/active" "$tmpdir/.agent/registry" "$tmpdir/docs/prompts" "$workdir"

    /bin/cp "$AUTO_ORCHESTRATE" "$outdir/auto_orchestrate.sh"
    /bin/cp "$LIB_DIR/utils.sh" "$outdir/lib/utils.sh"
    /bin/cp "$LIB_DIR/state.sh" "$outdir/lib/state.sh"
    /bin/cp "$LIB_DIR/timeout.sh" "$outdir/lib/timeout.sh"
    /bin/cp "$LIB_DIR/session.sh" "$outdir/lib/session.sh"
    /bin/cp "$LIB_DIR/coder.sh" "$outdir/lib/coder.sh"
    /bin/cp "$LIB_DIR/reviewer.sh" "$outdir/lib/reviewer.sh"
    /bin/cp "$LIB_DIR/orchestration_packet.sh" "$outdir/lib/orchestration_packet.sh"
    /bin/cp "$POLICY_PROJECTION_SOURCE" "$tmpdir/.agent/registry/orchestration_policy_projection.json"
    printf '# reviewer batch template\n' > "$tmpdir/docs/prompts/reviewer_batch.md"

    plan_file="$tmpdir/.agent/active/plan_batch_runtime.md"
    cat > "$plan_file" <<'PLAN'
# batch runtime queue test plan
PLAN

    cat > "$tmpdir/.claude/tmp/review_queue.json" <<'JSON'
{"pending_review":true,"changed_files":["src/legacy-only.sh"],"last_change":"2026-04-05T00:00:00Z"}
JSON

    local run_script=""
    run_script="$tmpdir/batch_runtime_inner.sh"
    cat > "$run_script" <<'EOF'
set -u -o pipefail
source "$TEST_TMPDIR/.claude/commands/auto_orchestrate.sh"
set +e

state_init "$TEST_TMPDIR/.agent/active/plan_batch_runtime.md" "batch_runtime" "$TEST_TMPDIR/state" >/dev/null
state_upsert_phase "impl" 1
state_set '.status' '"running"'
state_set_phase_status "impl" "running"
state_save

_coordination_require_authoritative_project_id() { printf '%s\n' "semantic-runtime-test"; }
_review_queue_exec() {
  local command="${1:-}"
  shift || true
  case "$command" in
    queue)
      local subcommand="${1:-}"
      shift || true
      case "$subcommand" in
        lease)
          jq -nc '
            {
              project_id: "semantic-runtime-test",
              lease_owner: "lease-owner-1",
              lease_run_id: "lease-run-1",
              leased_at: "2026-04-05T00:00:00Z",
              lease_expires_at: "2026-04-05T00:15:00Z",
              leased_count: 1,
              expected_files: ["src/db-authority.sh"],
              items: [
                {
                  file_path: "src/db-authority.sh",
                  queue_state: "leased",
                  retry_count: 0
                }
              ]
            }
          '
          return 0
          ;;
        complete)
          printf '%s\n' "$*" > "$TEST_COMPLETE_ARGS_FILE"
          jq -nc '
            {
              project_id: "semantic-runtime-test",
              lease_owner: "lease-owner-1",
              completed_at: "2026-04-05T00:10:00Z",
              completed_count: 1,
              items: [
                {
                  file_path: "src/db-authority.sh",
                  queue_state: "done"
                }
              ]
            }
          '
          return 0
          ;;
        requeue)
          echo "unexpected requeue" >&2
          return 91
          ;;
      esac
      ;;
  esac
  echo "unexpected queue exec: $command $*" >&2
  return 90
}
review_create_diff_snapshot() {
  local output_file="$1"
  local queued_files="${2:-}"
  [[ "$queued_files" == "src/db-authority.sh" ]] || {
    echo "unexpected queued files: $queued_files" >&2
    return 92
  }
  printf '%s\n' 'diff --git a/src/db-authority.sh b/src/db-authority.sh' > "$output_file"
  return 0
}
render_batch_review_prompt() {
  local template_file="$1"
  local metadata_file="$2"
  local diff_file="$3"
  local output_file="$4"
  : "${template_file:?}" "${metadata_file:?}" "${diff_file:?}"
  printf '# prompt\n' > "$output_file"
}
_run_batch_review_reviewer() {
  local input_file="$1"
  local output_file="$2"
  : "${input_file:?}"
  cat > "$output_file" <<'REVIEW'
# Code Review Report

## Review Request
- incoming request status: pending final review
- task id: task-20260422-semantic-coordination
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-semantic-coordination
- prior task id: none
- slice id: slice-semantic-coordination-batch-review
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: semantic-coordination
- worker outcome: DIFF
- request objective: Complete the leased queue item when the synthetic coordination reviewer returns canonical LGTM.
- invalid intake route: status=pending verification -> reject and require normalized review request.

## Review Outcome
- review verdict: LGTM
- outgoing next status: pending acceptance
- next action: Complete the queue item and persist the review run.

## Slice Contract
- task id: task-20260422-semantic-coordination
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-semantic-coordination
- prior task id: none
- slice id: slice-semantic-coordination-batch-review
- prior slice id: none
- review request target: FINAL
- discovery owner: coder
- bug class candidate: semantic-coordination
- change surface: synthetic semantic coordination batch-review fixture
- in-scope: canonical reviewer LGTM path for DB-authoritative queue completion
- out-of-scope: real Codex execution
- required checks: bash test/integration/semantic_coordination_test.sh
- evidence destination: tmp/semantic coordination batch-review assertions
- completion boundary: LGTM verdict can complete the queue item
- class closure sheet: tmp/semantic coordination batch-review class-closure
- sheet status: CLOSED
- owned sink universe: semantic coordination batch-review fixture
- closed universe status: YES
- closed universe basis: rg -n "semantic coordination batch-review|Worker Outcome Payload Reviewed|artifact integrity" test/integration/semantic_coordination_test.sh
- scope delta since last review: none
- re-slice delta type: none (only when prior slice id=none)
- re-slice delta summary: none (only when prior slice id=none)
- delta evidence: none (only when prior slice id=none)

## Loop Budget Ledger
- fix-review loops used: 0/2
- closure resets used: 0/2
- reviewer-found same-class finding count: 0/1
- re-slice count for task: 0/2
- cumulative reviewer requests for task: 1/6
- cumulative late same-class findings for task: 0/2
- cumulative closure resets for task: 0/2
- task-level stall-or-wall-time budget: stall<=30m; wall<=240m; basis=task-lineage-opened-at; start=2026-04-22T00:00:00Z; last-progress=2026-04-22T00:00:00Z
- task-level stall-or-wall-time budget status: within-budget

## Summary
Synthetic semantic coordination reviewer fixture returns canonical LGTM.
The DB-authoritative queue item may complete when the contract is satisfied.

## Findings
- None.

## Tests
- **実施:** YES
- **結果:** PASS
- **未実施の理由:** n/a

## Review Scope
- change surface: synthetic semantic coordination batch-review fixture
- in-scope: canonical reviewer LGTM path for DB-authoritative queue completion
- out-of-scope: real Codex execution
- 対象 hunk / ownership: test fixture only
- evidence destination: tmp/semantic coordination batch-review assertions
- completion boundary: LGTM verdict can complete the queue item

## Class Closure Sheet
- bug class: semantic-coordination
- task id: task-20260422-semantic-coordination
- task lineage ledger entry: .agent/active/sow/task-lineage-ledger.md :: task-20260422-semantic-coordination
- prior task id: none
- slice id: slice-semantic-coordination-batch-review
- change surface: synthetic semantic coordination batch-review fixture
- owned sink universe: semantic coordination batch-review fixture
- closed universe basis: rg -n "semantic coordination batch-review|Worker Outcome Payload Reviewed|artifact integrity" test/integration/semantic_coordination_test.sh
- closed universe status: YES
- search method / exact commands: rg -n "semantic coordination batch-review|Worker Outcome Payload Reviewed|artifact integrity" test/integration/semantic_coordination_test.sh
- sheet status: CLOSED
- last reset trigger: n/a
- remaining issues: 0
- basis: synthetic semantic coordination batch-review fixture is closed under the canonical FINAL LGTM contract.
- timestamp: 2026-04-22T00:00:00Z
- target scope: semantic coordination batch-review fixture

## Adversarial Pre-Closure Pass
- executed at: 2026-04-22T00:00:01Z
- reviewer request target: FINAL
- search commands: rg -n "Review Request|Review Outcome|Verdict" test/integration/semantic_coordination_test.sh
- opposite hypothesis checked: semantic coordination fixture still uses the reduced reviewer schema
- untouched owned surfaces checked: semantic coordination batch-review fixture only
- boundary / fallback / alias paths checked: legacy verdict checklist and reduced required verification fields
- new same-class sinks found: NO
- result: PASS

## Required Verification
- command: bash test/integration/semantic_coordination_test.sh
- result: PASS
- covered scope: semantic coordination batch-review reviewer fixture
- artifact pointer: /tmp/semantic-coordination-batch-review.log
- artifact integrity: complete
- no-artifact reason: n/a

## Worker Outcome Payload Reviewed
- contract source: docs/manual/verification-truth-matrix.md :: Worker Outcome Contract
- reviewer intake must match the active `worker outcome`; `worker outcome=BLOCK` intake is invalid and must be rerouted to a block report

### DIFF Payload Reviewed
- changed files: src/db-authority.sh
- evidence pointer: /tmp/semantic-coordination-batch-review.log
- next action consistency: YES

## Evidence Reviewed
- diff: synthetic coordination fixture
- change surface declaration: synthetic semantic coordination batch-review fixture
- scope declaration: synthetic semantic coordination fixture scope
- verification result: synthetic coordination fixture
- evidence destination: tmp/semantic coordination batch-review assertions
- artifact: /tmp/semantic-coordination-batch-review.log

## Unverified Areas
- None.

## Open Questions
- None.

## Verdict
- [x] LGTM - 問題なし、マージ可能
- [ ] BLOCK - fail-closed
- [ ] Request Changes - 修正が必要
- [ ] Needs verification - required checks の証跡不足
- [ ] Needs Discussion - 議論が必要
REVIEW
  return 0
}

printf '%s\n' 'semantic coordination synthetic artifact' > /tmp/semantic-coordination-batch-review.log

result="$(run_batch_review "$TEST_TMPDIR/work" "impl")"
rc=$?
printf 'RESULT_PATH=%s\n' "$result"
printf 'RESULT_RC=%s\n' "$rc"
EOF
    run_out="$(
      TEST_TMPDIR="$tmpdir" \
      TEST_COMPLETE_ARGS_FILE="$complete_args_file" \
      /bin/bash "$run_script" 2>&1
    )"
    run_rc=$?
    review_output="$(printf '%s\n' "$run_out" | awk -F= '/^RESULT_PATH=/{print $2}' | tail -n 1)"

    if [[ "$run_rc" -ne 0 ]]; then
      echo "detail: sourced batch review runtime test shell failed (rc=$run_rc)" >&2
      failed=1
    fi
    if ! contains_text "RESULT_RC=0" "$run_out"; then
      echo "detail: run_batch_review did not complete successfully" >&2
      failed=1
    fi
    if [[ -z "$review_output" || ! -f "$review_output" ]]; then
      echo "detail: batch review output file missing: $review_output" >&2
      failed=1
    fi
    if [[ ! -f "$complete_args_file" ]]; then
      echo "detail: queue complete arguments were not captured" >&2
      failed=1
    else
      local complete_args=""
      complete_args="$(cat "$complete_args_file")"
      if ! contains_text "--lease-owner lease-owner-1" "$complete_args"; then
        echo "detail: queue complete did not receive strict lease_owner" >&2
        failed=1
      fi
      if ! contains_text "--expected-file src/db-authority.sh" "$complete_args"; then
        echo "detail: queue complete did not receive expected leased file" >&2
        failed=1
      fi
      if contains_text "legacy-only.sh" "$complete_args"; then
        echo "detail: queue complete unexpectedly referenced legacy JSON queue file" >&2
        failed=1
      fi
    fi

    state_file="$tmpdir/state/state.json"
    if [[ ! -f "$state_file" ]]; then
      echo "detail: runtime state file missing: $state_file" >&2
      failed=1
    elif ! jq -e '
      .phases[0].batch_review_runtime.status == "completed"
      and .phases[0].batch_review_runtime.project_id == "semantic-runtime-test"
      and .phases[0].batch_review_runtime.lease_owner == "lease-owner-1"
      and .phases[0].batch_review_runtime.lease_run_id == "lease-run-1"
      and .phases[0].batch_review_runtime.expected_files == ["src/db-authority.sh"]
      and .phases[0].batch_review_runtime.finalization.completed_count == 1
    ' "$state_file" >/dev/null 2>&1; then
      echo "detail: runtime state did not retain strict lease metadata for completion" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m9_batch_review_rejects_invalid_project_id_contract() {
  (
    set -u -o pipefail
    set +e

    local failed=0
    local tmpdir outdir plan_file run_out finalize_out state_file
    tmpdir="$(mktemp -d)"
    outdir="$tmpdir/.claude/commands"
    mkdir -p "$outdir/lib" "$tmpdir/.claude/tmp" "$tmpdir/.agent/active" "$tmpdir/.agent/registry" "$tmpdir/docs/prompts" "$tmpdir/work"

    /bin/cp "$AUTO_ORCHESTRATE" "$outdir/auto_orchestrate.sh"
    /bin/cp "$LIB_DIR/utils.sh" "$outdir/lib/utils.sh"
    /bin/cp "$LIB_DIR/state.sh" "$outdir/lib/state.sh"
    /bin/cp "$LIB_DIR/timeout.sh" "$outdir/lib/timeout.sh"
    /bin/cp "$LIB_DIR/session.sh" "$outdir/lib/session.sh"
    /bin/cp "$LIB_DIR/coder.sh" "$outdir/lib/coder.sh"
    /bin/cp "$LIB_DIR/reviewer.sh" "$outdir/lib/reviewer.sh"
    /bin/cp "$LIB_DIR/orchestration_packet.sh" "$outdir/lib/orchestration_packet.sh"
    /bin/cp "$POLICY_PROJECTION_SOURCE" "$tmpdir/.agent/registry/orchestration_policy_projection.json"
    printf '# reviewer batch template\n' > "$tmpdir/docs/prompts/reviewer_batch.md"

    plan_file="$tmpdir/.agent/active/plan_batch_runtime_invalid_project_id.md"
    cat > "$plan_file" <<'PLAN'
# batch runtime invalid project_id test plan
PLAN

    local invalid_lease_script=""
    invalid_lease_script="$tmpdir/batch_runtime_invalid_lease_inner.sh"
    cat > "$invalid_lease_script" <<'EOF'
set -u -o pipefail
source "$TEST_TMPDIR/.claude/commands/auto_orchestrate.sh"
set +e

state_init "$TEST_TMPDIR/.agent/active/plan_batch_runtime_invalid_project_id.md" "batch_runtime_invalid_lease" "$TEST_TMPDIR/state-lease" >/dev/null
state_upsert_phase "impl" 1
state_set '.status' '"running"'
state_set_phase_status "impl" "running"
state_save

_review_queue_exec() {
  local command="${1:-}"
  shift || true
  case "$command" in
    queue)
      local subcommand="${1:-}"
      shift || true
      case "$subcommand" in
        lease)
          jq -nc '
            {
              project_id: "agent_base",
              lease_owner: "lease-owner-1",
              lease_run_id: "lease-run-1",
              leased_at: "2026-04-05T00:00:00Z",
              lease_expires_at: "2026-04-05T00:15:00Z",
              leased_count: 1,
              expected_files: ["src/invalid-project.sh"],
              items: [
                {
                  file_path: "src/invalid-project.sh",
                  queue_state: "leased",
                  retry_count: 0
                }
              ]
            }
          '
          return 0
          ;;
        *)
          echo "unexpected subcommand: $subcommand" >&2
          return 91
          ;;
      esac
      ;;
  esac
  echo "unexpected queue exec: $command $*" >&2
  return 90
}

result="$(run_batch_review "$TEST_TMPDIR/work" "impl")"
rc=$?
printf 'LEASE_RESULT_PATH=%s\n' "$result"
printf 'LEASE_RESULT_RC=%s\n' "$rc"
EOF
    run_out="$(
      TEST_TMPDIR="$tmpdir" \
      /bin/bash "$invalid_lease_script" 2>&1
    )"

    if ! contains_text "LEASE_RESULT_RC=1" "$run_out"; then
      echo "detail: invalid lease project_id did not fail closed" >&2
      failed=1
    fi

    state_file="$tmpdir/state-lease/state.json"
    if [[ ! -f "$state_file" ]]; then
      echo "detail: invalid lease state file missing: $state_file" >&2
      failed=1
    elif ! jq -e '
      .error.code == "BATCH_REVIEW_QUEUE_INVALID_LEASE"
      and .error.phase == "impl"
      and (.phases[0] | has("batch_review_runtime") | not)
    ' "$state_file" >/dev/null 2>&1; then
      echo "detail: invalid lease project_id was not recorded as strict invalid lease" >&2
      failed=1
    fi

    local invalid_finalize_script=""
    invalid_finalize_script="$tmpdir/batch_runtime_invalid_finalize_inner.sh"
    cat > "$invalid_finalize_script" <<'EOF'
set -u -o pipefail
source "$TEST_TMPDIR/.claude/commands/auto_orchestrate.sh"
set +e

state_init "$TEST_TMPDIR/.agent/active/plan_batch_runtime_invalid_project_id.md" "batch_runtime_invalid_finalize" "$TEST_TMPDIR/state-finalize" >/dev/null
state_upsert_phase "impl" 1
state_set '.status' '"running"'
state_set_phase_status "impl" "running"
state_set '.phases[0].batch_review_runtime' '{
  "status": "leased",
  "project_id": "agent_base",
  "lease_owner": "lease-owner-1",
  "lease_run_id": "lease-run-1",
  "expected_files": ["src/invalid-project.sh"]
}'
state_save

_review_queue_finalize_from_state "impl" "complete" >/dev/null
rc=$?
printf 'FINALIZE_RESULT_RC=%s\n' "$rc"
printf 'FINALIZE_LAST_ERROR=%s\n' "$REVIEW_QUEUE_LAST_ERROR"
printf 'FINALIZE_LAST_ERROR_KIND=%s\n' "$REVIEW_QUEUE_LAST_ERROR_KIND"
EOF
    finalize_out="$(
      TEST_TMPDIR="$tmpdir" \
      /bin/bash "$invalid_finalize_script" 2>&1
    )"

    if ! contains_text "FINALIZE_RESULT_RC=1" "$finalize_out"; then
      echo "detail: invalid runtime project_id did not fail finalization" >&2
      failed=1
    fi
    if ! contains_text "FINALIZE_LAST_ERROR_KIND=runtime_state_invalid" "$finalize_out"; then
      echo "detail: invalid runtime project_id did not classify as runtime_state_invalid" >&2
      failed=1
    fi
    if ! contains_text "invalid project_id" "$finalize_out" && ! contains_text "strict queue finalization" "$finalize_out"; then
      echo "detail: invalid runtime project_id did not emit a strict contract failure" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m10_auto_orchestrate_uses_direct_script_entrypoints() {
  (
    set -u -o pipefail
    set +e

    local failed=0
    local tmpdir outdir capsule_out shadow_out
    tmpdir="$(mktemp -d)"
    outdir="$tmpdir/.claude/commands"
    mkdir -p "$outdir/lib" "$tmpdir/.claude/tmp" "$tmpdir/.agent/active" "$tmpdir/.agent/registry" "$tmpdir/docs/prompts" "$tmpdir/work" "$tmpdir/scripts" "$tmpdir/.shared"

    /bin/cp "$AUTO_ORCHESTRATE" "$outdir/auto_orchestrate.sh"
    /bin/cp "$LIB_DIR/utils.sh" "$outdir/lib/utils.sh"
    /bin/cp "$LIB_DIR/state.sh" "$outdir/lib/state.sh"
    /bin/cp "$LIB_DIR/timeout.sh" "$outdir/lib/timeout.sh"
    /bin/cp "$LIB_DIR/session.sh" "$outdir/lib/session.sh"
    /bin/cp "$LIB_DIR/coder.sh" "$outdir/lib/coder.sh"
    /bin/cp "$LIB_DIR/reviewer.sh" "$outdir/lib/reviewer.sh"
    /bin/cp "$LIB_DIR/orchestration_packet.sh" "$outdir/lib/orchestration_packet.sh"
    /bin/cp "$POLICY_PROJECTION_SOURCE" "$tmpdir/.agent/registry/orchestration_policy_projection.json"

    cat > "$tmpdir/scripts/resolve-semantic-project-id.sh" <<'EOF'
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

[[ "$mode" == "print" ]] || exit 1
[[ -n "$repo_root" ]] || exit 1
cat "$repo_root/.shared/project_id"
EOF
    chmod +x "$tmpdir/scripts/resolve-semantic-project-id.sh"
    printf 'semantic-direct-entrypoint\n' > "$tmpdir/.shared/project_id"

    cat > "$outdir/lib/context_analysis.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
context_update_changed_only() { printf '%s\n' '{"ok":true}'; }
context_detect_deletions() { printf '%s\n' '{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}'; }
preflight_check() { printf '%s\n' '{"verdict":"PASS"}'; }
context_delta() { printf '%s\n' '{"delta":"ok"}'; }
EOF

    cat > "$outdir/lib/context_capsule.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  : "${TEST_TMPDIR:?}"
  : > "$TEST_TMPDIR/context_capsule_sourced"
  echo "context_capsule_should_not_be_sourced" >&2
  return 97
fi
case "${1:-}" in
  build)
    shift
    printf '%s\n' '{"capsule":"direct-cli","constraints":[],"hints":[]}'
    ;;
  *)
    echo "unexpected subcommand: ${1:-}" >&2
    exit 98
    ;;
esac
EOF

    cat > "$outdir/lib/shadow_verify.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
  echo "shadow_verify_should_not_be_sourced" >&2
  return 96
fi
case "${1:-}" in
  run)
    shift
    printf '%s\n' '{"status":"pass","phase":"impl","iteration":1,"reason":"direct-cli"}'
    ;;
  *)
    echo "unexpected subcommand: ${1:-}" >&2
    exit 99
    ;;
esac
EOF

    chmod +x "$outdir/lib/context_analysis.sh" "$outdir/lib/context_capsule.sh" "$outdir/lib/shadow_verify.sh"

    capsule_out="$(
      TEST_TMPDIR="$tmpdir" \
      /bin/bash <<'EOF'
set -u -o pipefail
source "$TEST_TMPDIR/.claude/commands/auto_orchestrate.sh"
set +e

plan_file="$TEST_TMPDIR/.agent/active/plan_task10.md"
printf '# task10\n' > "$plan_file"
state_init "$plan_file" "task10" "$TEST_TMPDIR/state-dir" >/dev/null
state_upsert_phase "impl" 1
state_set '.status' '"running"'
state_set_phase_status "impl" "running"
state_save

_coordination_require_src_sync_freshness() { return 0; }
prepare_coordination_context "$TEST_TMPDIR/.claude/tmp" "impl" "task10" 2>"$TEST_TMPDIR/capsule.err"
capsule_rc=$?
capsule_json="$(cat "$TEST_TMPDIR/.claude/tmp/impl_coord_capsule.json" 2>/dev/null || true)"
shadow_review_path="$(run_shadow_verify_gate "$TEST_TMPDIR/.claude/tmp" "impl" 1 2>"$TEST_TMPDIR/shadow.err")"
shadow_rc=$?
shadow_json="$(cat "$TEST_TMPDIR/.claude/tmp/impl_shadow_verify_iter1.json" 2>/dev/null || true)"
printf 'CAPSULE_RC=%s\n' "$capsule_rc"
printf 'CAPSULE_JSON=%s\n' "$capsule_json"
printf 'SHADOW_RC=%s\n' "$shadow_rc"
printf 'SHADOW_JSON=%s\n' "$shadow_json"
printf 'SHADOW_REVIEW_PATH=%s\n' "$shadow_review_path"
EOF
    )"

    if ! contains_text "CAPSULE_RC=0" "$capsule_out"; then
      echo "detail: capsule direct entrypoint did not succeed" >&2
      failed=1
    fi
    if ! contains_text '"capsule":"direct-cli"' "$capsule_out"; then
      echo "detail: capsule direct entrypoint did not return expected payload" >&2
      failed=1
    fi
    if ! contains_text "SHADOW_RC=0" "$capsule_out"; then
      echo "detail: shadow direct entrypoint did not succeed" >&2
      failed=1
    fi
    if ! contains_text '"status":"pass"' "$capsule_out"; then
      echo "detail: shadow direct entrypoint did not return expected payload" >&2
      failed=1
    fi
    if [[ -f "$tmpdir/capsule.err" ]] && contains_text "context_capsule_should_not_be_sourced" "$(cat "$tmpdir/capsule.err")"; then
      echo "detail: context_capsule helper was sourced instead of executed directly" >&2
      failed=1
    fi
    if [[ -e "$tmpdir/context_capsule_sourced" ]]; then
      echo "detail: context_capsule helper was sourced during bootstrap" >&2
      failed=1
    fi
    if [[ -f "$tmpdir/shadow.err" ]] && contains_text "shadow_verify_should_not_be_sourced" "$(cat "$tmpdir/shadow.err")"; then
      echo "detail: shadow_verify helper was sourced instead of executed directly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m11_semantic_preflight_and_capsule_signals() {
  (
    set -u -o pipefail
    local failed=0
    local tmpdir script out rc
    tmpdir="$(mktemp -d)"
    script="$tmpdir/preflight_signal_check.ts"

    cat > "$script" <<'EOF'
import { mkdtempSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";

async function main() {
  const repoRoot = "__REPO_ROOT__";

  const require = createRequire(`${repoRoot}/scripts/semantic-mcp-server/package.json`);
  const BetterSqlite3 = require("better-sqlite3");
  const { runMigrations } = await import(`${repoRoot}/scripts/semantic-mcp-server/src/db/migrations.ts`);
  const { handleRegistryUpsert } = await import(`${repoRoot}/scripts/semantic-mcp-server/src/tools/registry.ts`);
  const { handlePreflight } = await import(`${repoRoot}/scripts/semantic-mcp-server/src/tools/preflight.ts`);
  const { handleCapsule } = await import(`${repoRoot}/scripts/semantic-mcp-server/src/tools/capsule.ts`);

  const projectId = "coordination-signals";
  const tempRoot = mkdtempSync(join(tmpdir(), "semantic-coordination-signals-"));
  const dbPath = join(tempRoot, "semantic.db");
  const db = new BetterSqlite3(dbPath);

  try {
  runMigrations(db);
  db.prepare(
    `
      INSERT INTO projects (id, name, root_path, created_at, updated_at)
      VALUES (?, ?, ?, datetime('now'), datetime('now'))
    `
  ).run(projectId, "Coordination Signals", tempRoot);

  const context = {
    projectId,
    dbPath,
    db
  };

  handleRegistryUpsert(context, {
    components: [
      {
        semantic_id: "src/existing/render.ts:render",
        name: "render",
        module: "src/existing/render.ts",
        file_path: "src/existing/render.ts",
        kind: "function",
        exports: [],
        imports: []
      },
      {
        semantic_id: "core:SharedWidget",
        name: "SharedWidget",
        module: "core",
        file_path: "src/shared-widget.ts",
        kind: "class",
        exports: [],
        imports: []
      }
    ]
  });

  const ambiguousPreflight = handlePreflight(context, {
    project_id: projectId,
    task_id: "task-ambiguous",
    scope: ["src/new/render.ts", "src/sidecar.ts"],
    proposed_components: ["src/new/render.ts:render"]
  }) as {
    verdict: string;
    conflicts: Array<{ semantic_id: string; reason: string }>;
    target_lock: { status: string; summary: string };
    ambiguity: { status: string; summary: string };
    duplicate_risk: { status: string; summary: string };
  };

  const mismatchPreflight = handlePreflight(context, {
    project_id: projectId,
    task_id: "task-mismatch",
    scope: ["src/other.ts"],
    proposed_components: ["SRC\\\\locked.ts:foo"]
  }) as {
    verdict: string;
    conflicts: Array<{ semantic_id: string; reason: string }>;
    target_lock: { status: string; summary: string };
  };

  const emptyScopePreflight = handlePreflight(context, {
    project_id: projectId,
    task_id: "task-empty-scope",
    scope: [],
    proposed_components: ["SRC\\\\empty-scope.ts:foo"]
  }) as {
    verdict: string;
    conflicts: Array<{ semantic_id: string; reason: string }>;
    target_lock: { status: string; summary: string };
  };

  const duplicateRequestPreflight = handlePreflight(context, {
    project_id: projectId,
    task_id: "task-duplicate-request",
    scope: ["src/duplicate.ts"],
    proposed_components: ["SRC\\\\nested\\\\..\\\\duplicate.ts:Widget", "src/duplicate.ts:Widget"]
  }) as {
    verdict: string;
    conflicts: Array<{ semantic_id: string; reason: string }>;
    target_lock: { status: string; summary: string };
    ambiguity: { status: string; summary: string };
    duplicate_risk: { status: string; summary: string };
  };

  const ownershipConflictPreflight = handlePreflight(context, {
    project_id: projectId,
    task_id: "task-ownership-conflict",
    scope: ["src/shared-widget.ts"],
    proposed_components: ["SRC\\\\nested\\\\..\\\\shared-widget.ts:SharedWidget"]
  }) as {
    verdict: string;
    conflicts: Array<{ semantic_id: string; reason: string }>;
    target_lock: { status: string; summary: string };
    ambiguity: { status: string; summary: string };
    duplicate_risk: { status: string; summary: string };
  };

  for (const suffix of ["A".repeat(96), "B".repeat(96), "C".repeat(96)]) {
    handlePreflight(context, {
      project_id: projectId,
      task_id: `overlap-${suffix}`,
      scope: ["src/new/render.ts", "src/overlap-target.ts"],
      proposed_components: []
    });
  }

  const compactedPreflight = handlePreflight(context, {
    project_id: projectId,
    task_id: "task-compacted-signals",
    scope: ["src/new/render.ts", "src/overlap-target.ts"],
    proposed_components: ["SRC\\\\new\\\\render.ts:render"]
  }) as {
    verdict: string;
    capsule: string;
    target_lock: { status: string; summary: string };
    ambiguity: { status: string; summary: string };
    duplicate_risk: { status: string; summary: string };
  };

  const capsule = handleCapsule(context, {
    project_id: projectId,
    task_id: "task-ambiguous",
    phase: "impl",
    context: {
      changed_symbols: ["src/new/render.ts:render"],
      top_k_symbols: ["src/existing/render.ts:render"],
      preflight_verdict: ambiguousPreflight.verdict,
      target_lock: ambiguousPreflight.target_lock,
      ambiguity: ambiguousPreflight.ambiguity,
      duplicate_risk: ambiguousPreflight.duplicate_risk
    }
  });

  console.log(
    JSON.stringify({
      ambiguous_preflight: ambiguousPreflight,
      mismatch_preflight: mismatchPreflight,
      empty_scope_preflight: emptyScopePreflight,
      duplicate_request_preflight: duplicateRequestPreflight,
      ownership_conflict_preflight: ownershipConflictPreflight,
      compacted_preflight: compactedPreflight,
      capsule
    })
  );
  } finally {
    db.close();
    rmSync(tempRoot, { recursive: true, force: true });
  }
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
EOF

    /usr/bin/perl -0pi -e "s|__REPO_ROOT__|$PROJECT_ROOT|g" "$script"

    out="$(
      PATH="$PROJECT_NODE_RUNTIME_PATH" \
      HOME="$PROJECT_NODE_RUNTIME_HOME" \
      bash "$PROJECT_ROOT/scripts/run-semantic-node-tool.sh" \
        npx \
        --prefix "$PROJECT_ROOT/scripts/semantic-mcp-server" \
        --no-install \
        tsx \
        "$script"
    )"
    rc=$?
    if [[ "$rc" -ne 0 ]]; then
      echo "detail: direct semantic signal check failed (rc=$rc)" >&2
      failed=1
    elif ! printf '%s\n' "$out" | jq -e '
      .ambiguous_preflight.verdict == "BLOCK"
      and .ambiguous_preflight.target_lock.status == "clear"
      and .ambiguous_preflight.ambiguity.status == "blocked"
      and .ambiguous_preflight.duplicate_risk.status == "blocked"
      and (.ambiguous_preflight.conflicts | any(.reason | test("ambiguous_duplicate_risk")))
      and .mismatch_preflight.verdict == "BLOCK"
      and .mismatch_preflight.target_lock.status == "blocked"
      and (.mismatch_preflight.conflicts | any(.reason | test("target_lock_scope_mismatch")))
      and .empty_scope_preflight.verdict == "BLOCK"
      and .empty_scope_preflight.target_lock.status == "blocked"
      and (.empty_scope_preflight.conflicts | any(.reason | test("target_lock_scope_missing")))
      and .duplicate_request_preflight.verdict == "BLOCK"
      and .duplicate_request_preflight.target_lock.status == "clear"
      and .duplicate_request_preflight.ambiguity.status == "blocked"
      and .duplicate_request_preflight.duplicate_risk.status == "blocked"
      and (.duplicate_request_preflight.conflicts | any(.semantic_id == "SRC\\\\nested\\\\..\\\\duplicate.ts:Widget"))
      and (.duplicate_request_preflight.conflicts | any(.reason | test("duplicate_request_target")))
      and .ownership_conflict_preflight.verdict == "BLOCK"
      and .ownership_conflict_preflight.target_lock.status == "clear"
      and .ownership_conflict_preflight.duplicate_risk.status == "blocked"
      and (.ownership_conflict_preflight.conflicts | any(.reason | test("duplicate_target_owner")))
      and .compacted_preflight.verdict == "BLOCK"
      and (.compacted_preflight | tojson | length) <= 660
      and ((.compacted_preflight.capsule | split("\n")) | length == 5)
      and (.compacted_preflight.capsule | test("TARGET_LOCK=clear"))
      and (.compacted_preflight.capsule | test("AMBIGUITY=blocked"))
      and (.compacted_preflight.capsule | test("DUPLICATE_RISK=blocked"))
      and (.capsule.capsule | test("TARGET_LOCK=clear"))
      and (.capsule.capsule | test("AMBIGUITY=blocked"))
      and (.capsule.capsule | test("DUPLICATE_RISK=blocked"))
      and (.capsule.hints | any(. == "target_lock=clear"))
      and (.capsule.hints | any(. == "ambiguity=blocked"))
    ' >/dev/null 2>&1; then
      echo "detail: semantic preflight/capsule signals did not match expected fail-closed contract" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_m12_schema_fast_path_current_parity() {
  (
    set -u -o pipefail
    local failed=0
    local tmpdir script
    tmpdir="$(mktemp -d)"
    script="$tmpdir/schema_fast_path_current_check.mjs"

    cat > "$script" <<'EOF'
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";

function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

const repoRoot = process.env.REPO_ROOT;
const rustSemanticBin = process.env.RUST_SEMANTIC_BIN;
const nodeBinary = process.env.NODE_BINARY;
if (!repoRoot) {
  throw new Error("REPO_ROOT is required");
}
if (!rustSemanticBin) {
  throw new Error("RUST_SEMANTIC_BIN is required");
}
if (!nodeBinary) {
  throw new Error("NODE_BINARY is required");
}

const require = createRequire(`${repoRoot}/scripts/semantic-mcp-server/package.json`);
const BetterSqlite3 = require("better-sqlite3");
const { runMigrations } = await import(`${repoRoot}/scripts/semantic-mcp-server/dist/db/migrations.js`);

const tempRoot = mkdtempSync(join(tmpdir(), "semantic-schema-fast-path-current-"));
const nodeHome = join(tempRoot, "home-node");
const rustHome = join(tempRoot, "home-rust");
mkdirSync(nodeHome, { recursive: true });
mkdirSync(rustHome, { recursive: true });

function initCurrentFixture(homeRoot, projectId) {
  const dbPath = join(homeRoot, ".semantic-mcp", projectId, "semantic.db");
  mkdirSync(join(dbPath, ".."), { recursive: true });
  const db = new BetterSqlite3(dbPath);
  try {
    const first = runMigrations(db);
    const second = runMigrations(db);
    assert(first.path === "full", `expected first migration to be full for ${projectId}`);
    assert(second.path === "fast-path", `expected second migration to fast-path for ${projectId}`);
    assert(db.pragma("user_version", { simple: true }) === 1, `expected schema version marker for ${projectId}`);
  } finally {
    db.close();
  }
}

function inspectSchema(homeRoot, projectId) {
  const dbPath = join(homeRoot, ".semantic-mcp", projectId, "semantic.db");
  const db = new BetterSqlite3(dbPath, { readonly: true });
  try {
    const userVersion = db.pragma("user_version", { simple: true });
    const indexNames = db.prepare("SELECT name FROM sqlite_master WHERE type = 'index' ORDER BY name").all().map((row) => row.name);
    return {
      userVersion,
      hasEventIndex: indexNames.includes("idx_review_queue_items_project_event"),
      hasPhaseIndex: indexNames.includes("idx_review_runs_project_phase_kind")
    };
  } finally {
    db.close();
  }
}

function runBackend(kind, homeRoot, projectId, outputPath) {
  const env = { ...process.env, HOME: homeRoot, USERPROFILE: "" };
  if (kind === "node") {
    execFileSync(
      nodeBinary,
      [
        `${repoRoot}/scripts/semantic-mcp-server/dist/cli.js`,
        "queue",
        "export-json",
        "--project-id",
        projectId,
        "--output",
        outputPath
      ],
      { env, stdio: "pipe" }
    );
    return;
  }

  execFileSync(
    rustSemanticBin,
    [
      "queue",
      "export-json",
      "--project-id",
      projectId,
      "--output",
      outputPath
    ],
    { env, stdio: "pipe" }
  );
}

try {
  initCurrentFixture(nodeHome, "coord-fast-current-node");
  initCurrentFixture(rustHome, "coord-fast-current-rust");

  const nodeOutput = join(tempRoot, "node-export.json");
  const rustOutput = join(tempRoot, "rust-export.json");

  runBackend("node", nodeHome, "coord-fast-current-node", nodeOutput);
  runBackend("rust", rustHome, "coord-fast-current-rust", rustOutput);

  const nodeExport = JSON.parse(readFileSync(nodeOutput, "utf8"));
  const rustExport = JSON.parse(readFileSync(rustOutput, "utf8"));
  const nodeSchema = inspectSchema(nodeHome, "coord-fast-current-node");
  const rustSchema = inspectSchema(rustHome, "coord-fast-current-rust");

  assert(nodeExport.pending_count === 0, "node current export pending_count mismatch");
  assert(rustExport.pending_count === 0, "rust current export pending_count mismatch");
  assert(nodeSchema.userVersion === 1, "node current schema marker changed unexpectedly");
  assert(rustSchema.userVersion === 1, "rust current schema marker changed unexpectedly");
  assert(nodeSchema.hasEventIndex, "node current schema lost review queue event index");
  assert(rustSchema.hasEventIndex, "rust current schema lost review queue event index");
  assert(nodeSchema.hasPhaseIndex, "node current schema lost review run phase index");
  assert(rustSchema.hasPhaseIndex, "rust current schema lost review run phase index");
} finally {
  rmSync(tempRoot, { recursive: true, force: true });
}
EOF

    if ! REPO_ROOT="$PROJECT_ROOT" \
      RUST_SEMANTIC_BIN="$PROJECT_RUST_SEMANTIC_BIN" \
      NODE_BINARY="$PROJECT_NODE_RUNTIME_BINARY" \
      PATH="$PROJECT_NODE_RUNTIME_PATH" \
      HOME="$PROJECT_NODE_RUNTIME_HOME" \
      "$PROJECT_NODE_RUNTIME_BINARY" "$script"; then
      echo "detail: stamped current-schema parity check failed" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

dispatch_test() {
  local id="$1"
  case "$id" in
    M1) test_m1_capsule_budget ;;
    M2) test_m2_reviewer_packet_diff_centered ;;
    M3) test_m3_shadow_verify_fix_loop ;;
    M4) test_m4_preflight_fail_closed ;;
    M5) test_m5_select_window_regex_fallback ;;
    M6) test_m6_graph_rank_topk ;;
    M7) test_m7_missing_context_analysis_blocks ;;
    M8) test_m8_batch_review_runtime_uses_db_lease_state ;;
    M9) test_m9_batch_review_rejects_invalid_project_id_contract ;;
    M10) test_m10_auto_orchestrate_uses_direct_script_entrypoints ;;
    M11) test_m11_semantic_preflight_and_capsule_signals ;;
    M12) test_m12_schema_fast_path_current_parity ;;
    *) return 2 ;;
  esac
}

run_test() {
  local id="$1"
  local description=""
  description="$(test_description "$id")" || description="(unknown)"

  echo "[TEST] $id - $description"
  if dispatch_test "$id"; then
    echo "PASS: $id"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $id"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

list_tests() {
  local id
  for id in "${ALL_TEST_IDS[@]}"; do
    echo "$id - $(test_description "$id")"
  done
}

main() {
  require_cmd jq
  require_cmd git
  require_cmd mktemp
  require_cmd awk
  load_project_node_runtime_env

  local selected_tests=()
  if [[ "$#" -eq 0 ]]; then
    selected_tests=("${ALL_TEST_IDS[@]}")
  elif [[ "$#" -eq 1 && "$1" == "--list" ]]; then
    list_tests
    exit 0
  else
    local id
    for id in "$@"; do
      if ! test_description "$id" >/dev/null 2>&1; then
        echo "ERROR: unknown test id: $id" >&2
        echo "Use --list to show available test ids." >&2
        exit 2
      fi
      selected_tests+=("$id")
    done
  fi

  local id
  for id in "${selected_tests[@]}"; do
    run_test "$id"
    echo
  done

  echo "RESULT: pass=$PASS_COUNT fail=$FAIL_COUNT"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
  exit 0
}

main "$@"
