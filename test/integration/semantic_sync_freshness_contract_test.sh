#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/.claude/commands/lib"
AUTO_ORCHESTRATE="$PROJECT_ROOT/.claude/commands/auto_orchestrate.sh"

PASS_COUNT=0
FAIL_COUNT=0
SEMANTIC_SYNC_FRESHNESS_TEST_TIMEOUT_SECS="${SEMANTIC_SYNC_FRESHNESS_TEST_TIMEOUT_SECS:-120}"
PRODUCT_REL_PATH="apps/web/app.sh"
SUPPORT_REL_PATH="docs/operator-guide.md"
UNDECLARED_PRODUCT_REL_PATH="libs/core/runtime.sh"
REQUESTED_TEST_IDS=("$@")

contains_text() {
  local needle="$1"
  local haystack="$2"
  [[ "$haystack" == *"$needle"* ]]
}

test_description() {
  case "${1:-}" in
    F1) echo "context_update records native-layout product freshness artifact on changed-only sync" ;;
    F2) echo "prepare_coordination_context fails closed on stale product freshness even when support freshness is green" ;;
    F3) echo "no changed declared product-surface paths keeps completion freshness gate green" ;;
    F4) echo "delete after sync marks declared product-surface freshness stale and blocks" ;;
    F5) echo "support-only HEAD advance remains fresh after empty-scope changed-only sync" ;;
    F6) echo "committed product-surface HEAD advance stays stale after empty-scope changed-only sync" ;;
    F7) echo "committed undeclared candidate-root HEAD advance stays stale after empty-scope changed-only sync" ;;
    *) return 1 ;;
  esac
}

_setup_git_repo() {
  local repo_root="$1"

  mkdir -p "$repo_root/apps/web" "$repo_root/.agent"
  /bin/cp "$PROJECT_ROOT/.agent/PROJECT_CONTEXT.md" "$repo_root/.agent/PROJECT_CONTEXT.md"
  git -C "$repo_root" init -q
  git -C "$repo_root" config user.name "Test User"
  git -C "$repo_root" config user.email "test@example.com"
  printf '%s\n' 'echo base' > "$repo_root/$PRODUCT_REL_PATH"
  git -C "$repo_root" add "$PRODUCT_REL_PATH" .agent/PROJECT_CONTEXT.md
  git -C "$repo_root" commit -qm "init"
}

_setup_context_env() {
  local repo_root="$1"

  CONTEXT_REPO_ROOT="$repo_root"
  CONTEXT_CONTEXT_DIR="$repo_root/.agent/context"
  CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
  CONTEXT_SRC_SYNC_FRESHNESS_FILE="$CONTEXT_CONTEXT_DIR/product_surface_sync_freshness.json"
  CONTEXT_PRODUCT_SURFACE_SYNC_FRESHNESS_FILE="$CONTEXT_SRC_SYNC_FRESHNESS_FILE"
  TREE_SITTER_AVAILABLE=false
  TREE_SITTER_CHECKED=true
}

_setup_coordination_env() {
  local repo_root="$1"

  REPO_ROOT="$repo_root"
  TMP_BASE="$repo_root/.claude/tmp"
  SRC_SYNC_FRESHNESS_FILE="$repo_root/.agent/context/product_surface_sync_freshness.json"
  PRODUCT_SURFACE_SYNC_FRESHNESS_FILE="$SRC_SYNC_FRESHNESS_FILE"
  _setup_context_env "$repo_root"
}

_setup_phase_state() {
  local tmpdir="$1"
  local task_id="$2"
  local phase="${3:-impl}"
  local plan_file="$tmpdir/plan.md"

  printf '# %s\n' "$task_id" > "$plan_file"
  state_init "$plan_file" "$task_id" "$tmpdir/state" >/dev/null
  state_upsert_phase "$phase" 1
  state_set '.status' '"running"'
  state_set_phase_status "$phase" "running"
  state_save
}

_write_support_context_green_fixture() {
  local repo_root="$1"
  local fixture_path="$repo_root/.claude/tmp/support-context-green/task-contract.json"

  mkdir -p "$(dirname "$fixture_path")"
  printf '%s\n' \
    '{' \
    '  "support_context_freshness": {' \
    '    "resolver": "slice-b-test-fixture",' \
    '    "current_plan_path": ".agent/active/plan.md",' \
    '    "current_sow_path": ".agent/active/sow.md",' \
    '    "project_context_path": ".agent/PROJECT_CONTEXT.md",' \
    '    "support_read_order": [' \
    '      ".agent/PROJECT_CONTEXT.md"' \
    '    ],' \
    '    "required_current_documents": [' \
    '      ".agent/PROJECT_CONTEXT.md"' \
    '    ],' \
    '    "optional_handover": {' \
    '      "present": false' \
    '    },' \
    '    "freshness_expectations": {' \
    '      "current_docs_must_match": true' \
    '    },' \
    '    "evidence_only_patterns": [' \
    '      ".claude/tmp/**"' \
    '    ]' \
    '  }' \
    '}' > "$fixture_path"
}

test_f1_context_update_records_freshness() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir repo_root freshness_file result rc expected_head
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"
    printf '%s\n' 'echo changed' > "$repo_root/$PRODUCT_REL_PATH"

    _setup_context_env "$repo_root"

    result="$(context_update --changed-only)"
    rc=$?
    freshness_file="$CONTEXT_SRC_SYNC_FRESHNESS_FILE"
    expected_head="$(git -C "$repo_root" rev-parse HEAD)"

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: context_update --changed-only failed (rc=$rc)" >&2
      failed=1
    fi

    if [[ ! -f "$freshness_file" ]]; then
      echo "detail: freshness artifact missing: $freshness_file" >&2
      failed=1
    elif ! jq -e \
      --arg head "$expected_head" \
      --arg repomap_dir "$CONTEXT_REPOMAP_DIR" \
      --arg product_path "$PRODUCT_REL_PATH" \
      '
        .head_sha == $head
        and .repomap_dir == $repomap_dir
        and ((.changed_product_files // .changed_surface_files // .changed_src_files // []) | type == "array")
        and ((.changed_product_files // .changed_surface_files // .changed_src_files // []) == [$product_path])
        and (.synced_at | type == "string" and length > 0)
      ' "$freshness_file" >/dev/null 2>&1; then
      echo "detail: freshness artifact shape/content invalid" >&2
      failed=1
    fi

    if ! printf '%s\n' "$result" | jq -e '.mode == "changed-only"' >/dev/null 2>&1; then
      echo "detail: context_update summary did not report changed-only mode" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_f2_prepare_blocks_when_stale() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root prep_out prep_rc freshness_artifact
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"
    printf '%s\n' 'echo changed' > "$repo_root/$PRODUCT_REL_PATH"

    _setup_coordination_env "$repo_root"
    _write_support_context_green_fixture "$repo_root"

    mkdir -p "$tmpdir/work"
    _setup_phase_state "$tmpdir" "semantic_sync_stale"

    run_context_analysis=true
    coordination_context_unavailable=false
    _coordination_context_update_changed_only() { return 1; }
    _coordination_context_detect_deletions() { echo '{"deleted_paths":[],"removed_symbols":[],"move_candidates":[]}'; }
    _coordination_require_authoritative_project_id() { echo "semantic-sync-test"; }
    _coordination_preflight_check() { echo '{"verdict":"PASS","conflicts":[]}'; }

    prep_out="$(prepare_coordination_context "$tmpdir/work" "impl" "task_semantic_sync_stale" 2>&1)"
    prep_rc=$?
    freshness_artifact="$SRC_SYNC_FRESHNESS_FILE"

    if [[ "$prep_rc" -eq 0 ]]; then
      echo "detail: prepare_coordination_context unexpectedly succeeded on stale freshness" >&2
      failed=1
    fi
    if ! contains_text "freshness stale" "$prep_out"; then
      echo "detail: stale freshness error message missing" >&2
      failed=1
    fi
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e '.error.code == "SRC_SYNC_FRESHNESS_BLOCK" and .error.phase == "impl"' "$STATE_FILE" >/dev/null 2>&1; then
      echo "detail: state did not record SRC_SYNC_FRESHNESS_BLOCK" >&2
      failed=1
    fi
    if [[ -f "$freshness_artifact" ]]; then
      echo "detail: stale test unexpectedly produced freshness artifact despite sync failure" >&2
      failed=1
    fi
    if [[ ! -f "$repo_root/.claude/tmp/support-context-green/task-contract.json" ]]; then
      echo "detail: support-context freshness fixture missing; separation check is invalid" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_f3_gate_passes_with_no_changed_src() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root rc out status_json
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"

    _setup_coordination_env "$repo_root"
    _setup_phase_state "$tmpdir" "semantic_sync_no_changed_product_surface"

    out="$(_coordination_require_src_sync_freshness "impl" "phase completed" 2>&1)"
    rc=$?
    status_json="$(_coordination_src_sync_freshness_status)"

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: freshness gate unexpectedly blocked with no changed declared product-surface paths" >&2
      failed=1
    fi
    if [[ -n "$out" ]]; then
      echo "detail: freshness gate emitted unexpected output on pass path" >&2
      failed=1
    fi
    if ! printf '%s\n' "$status_json" | jq -e '
      .fresh == true
      and .summary == "fresh"
      and .reasons == []
      and ((.current_changed_product_files // .current_changed_surface_files // .current_changed_src_files // []) == [])
    ' >/dev/null 2>&1; then
      echo "detail: no-changed-product-surface status was not fresh" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_f4_delete_after_sync_blocks() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root rc out status_json
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"
    printf '%s\n' 'echo synced candidate' > "$repo_root/$PRODUCT_REL_PATH"

    _setup_coordination_env "$repo_root"
    _setup_phase_state "$tmpdir" "semantic_sync_delete_after_sync"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: initial changed-only sync failed before delete scenario" >&2
      failed=1
    fi

    /bin/rm -f "$repo_root/$PRODUCT_REL_PATH"

    out="$(_coordination_require_src_sync_freshness "impl" "phase completed" 2>&1)"
    rc=$?
    status_json="$(context_src_sync_status)"

    if [[ "$rc" -eq 0 ]]; then
      echo "detail: freshness gate unexpectedly passed after deleting synced product-surface path" >&2
      failed=1
    fi
    if ! contains_text "freshness stale" "$out"; then
      echo "detail: delete-after-sync stale message missing" >&2
      failed=1
    fi
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e '.error.code == "SRC_SYNC_FRESHNESS_BLOCK" and .error.phase == "impl"' "$STATE_FILE" >/dev/null 2>&1; then
      echo "detail: delete-after-sync block was not recorded in state" >&2
      failed=1
    fi
    if ! printf '%s\n' "$status_json" | jq -e --arg product_path "$PRODUCT_REL_PATH" '
      .stale == true
      and ((.deleted_product_files_since_sync // .deleted_surface_files_since_sync // .deleted_src_files_since_sync // []) == [$product_path])
    ' >/dev/null 2>&1; then
      echo "detail: delete-after-sync status did not report deleted product-surface path" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_f5_docs_only_head_advance_stays_fresh() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root rc out status_json expected_head freshness_file
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"

    _setup_coordination_env "$repo_root"
    _setup_phase_state "$tmpdir" "semantic_sync_support_only_head_advance"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: baseline changed-only sync failed before support-only HEAD advance" >&2
      failed=1
    fi

    mkdir -p "$(dirname "$repo_root/$SUPPORT_REL_PATH")"
    printf '%s\n' '# support only' > "$repo_root/$SUPPORT_REL_PATH"
    git -C "$repo_root" add "$SUPPORT_REL_PATH"
    git -C "$repo_root" commit -qm "support only advance"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: empty-scope changed-only sync failed after support-only HEAD advance" >&2
      failed=1
    fi

    out="$(_coordination_require_src_sync_freshness "impl" "phase completed" 2>&1)"
    rc=$?
    status_json="$(context_src_sync_status)"
    expected_head="$(git -C "$repo_root" rev-parse HEAD)"
    freshness_file="$SRC_SYNC_FRESHNESS_FILE"

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: support-only HEAD advance unexpectedly blocked freshness gate" >&2
      failed=1
    fi
    if [[ -n "$out" ]]; then
      echo "detail: support-only HEAD advance emitted unexpected gate output" >&2
      failed=1
    fi
    if ! printf '%s\n' "$status_json" | jq -e '
      .stale == false
      and ((.committed_product_files_since_sync // .committed_surface_files_since_sync // .committed_src_files_since_sync // []) == [])
      and ((.current_changed_product_files // .current_changed_surface_files // .current_changed_src_files // []) == [])
    ' >/dev/null 2>&1; then
      echo "detail: support-only HEAD advance was not reported fresh" >&2
      failed=1
    fi
    if [[ ! -f "$freshness_file" ]] || ! jq -e --arg head "$expected_head" '
      .head_sha == $head
      and ((.changed_product_files // .changed_surface_files // .changed_src_files // []) == [])
    ' "$freshness_file" >/dev/null 2>&1; then
      echo "detail: support-only HEAD advance did not refresh clean baseline artifact" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_f6_committed_src_head_advance_blocks_after_empty_scope_sync() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root rc out status_json freshness_file baseline_head current_head
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"

    _setup_coordination_env "$repo_root"
    _setup_phase_state "$tmpdir" "semantic_sync_committed_product_head_advance"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: baseline changed-only sync failed before committed product-surface HEAD advance" >&2
      failed=1
    fi
    baseline_head="$(git -C "$repo_root" rev-parse HEAD)"

    printf '%s\n' 'echo committed product advance' > "$repo_root/$PRODUCT_REL_PATH"
    git -C "$repo_root" add "$PRODUCT_REL_PATH"
    git -C "$repo_root" commit -qm "product surface advance"
    current_head="$(git -C "$repo_root" rev-parse HEAD)"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: empty-scope changed-only sync failed after committed product-surface HEAD advance" >&2
      failed=1
    fi

    out="$(_coordination_require_src_sync_freshness "impl" "phase completed" 2>&1)"
    rc=$?
    status_json="$(context_src_sync_status)"
    freshness_file="$SRC_SYNC_FRESHNESS_FILE"

    if [[ "$rc" -eq 0 ]]; then
      echo "detail: committed product-surface HEAD advance unexpectedly passed freshness gate" >&2
      failed=1
    fi
    if ! contains_text "freshness stale" "$out"; then
      echo "detail: committed product-surface HEAD advance stale message missing" >&2
      failed=1
    fi
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e '.error.code == "SRC_SYNC_FRESHNESS_BLOCK" and .error.phase == "impl"' "$STATE_FILE" >/dev/null 2>&1; then
      echo "detail: committed product-surface HEAD advance block was not recorded in state" >&2
      failed=1
    fi
    if ! printf '%s\n' "$status_json" | jq -e --arg product_path "$PRODUCT_REL_PATH" '
      .stale == true
      and ((.committed_product_files_since_sync // .committed_surface_files_since_sync // .committed_src_files_since_sync // []) == [$product_path])
    ' >/dev/null 2>&1; then
      echo "detail: committed product-surface HEAD advance status did not report stale committed delta" >&2
      failed=1
    fi
    if [[ ! -f "$freshness_file" ]] || ! jq -e --arg baseline "$baseline_head" --arg current "$current_head" '
      .head_sha == $baseline
      and .head_sha != $current
      and ((.changed_product_files // .changed_surface_files // .changed_src_files // []) == [])
    ' "$freshness_file" >/dev/null 2>&1; then
      echo "detail: stale committed product-surface HEAD advance unexpectedly refreshed baseline artifact" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_f7_committed_undeclared_candidate_root_head_advance_blocks_after_empty_scope_sync() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$AUTO_ORCHESTRATE"
    set +e

    local failed=0
    local tmpdir repo_root rc out status_json freshness_file baseline_head current_head
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    mkdir -p "$repo_root"
    _setup_git_repo "$repo_root"

    _setup_coordination_env "$repo_root"
    _setup_phase_state "$tmpdir" "semantic_sync_committed_undeclared_candidate_root_head_advance"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: baseline changed-only sync failed before committed undeclared candidate-root HEAD advance" >&2
      failed=1
    fi
    baseline_head="$(git -C "$repo_root" rev-parse HEAD)"

    mkdir -p "$(dirname "$repo_root/$UNDECLARED_PRODUCT_REL_PATH")"
    printf '%s\n' 'echo undeclared candidate root advance' > "$repo_root/$UNDECLARED_PRODUCT_REL_PATH"
    git -C "$repo_root" add "$UNDECLARED_PRODUCT_REL_PATH"
    git -C "$repo_root" commit -qm "undeclared candidate root advance"
    current_head="$(git -C "$repo_root" rev-parse HEAD)"

    if ! context_update --changed-only >/dev/null; then
      echo "detail: empty-scope changed-only sync failed after committed undeclared candidate-root HEAD advance" >&2
      failed=1
    fi

    out="$(_coordination_require_src_sync_freshness "impl" "phase completed" 2>&1)"
    rc=$?
    status_json="$(context_src_sync_status)"
    freshness_file="$SRC_SYNC_FRESHNESS_FILE"

    if [[ "$rc" -eq 0 ]]; then
      echo "detail: committed undeclared candidate-root HEAD advance unexpectedly passed freshness gate" >&2
      failed=1
    fi
    if ! contains_text "freshness stale" "$out"; then
      echo "detail: committed undeclared candidate-root HEAD advance stale message missing" >&2
      failed=1
    fi
    if [[ ! -f "$STATE_FILE" ]] || ! jq -e '.error.code == "SRC_SYNC_FRESHNESS_BLOCK" and .error.phase == "impl"' "$STATE_FILE" >/dev/null 2>&1; then
      echo "detail: committed undeclared candidate-root HEAD advance block was not recorded in state" >&2
      failed=1
    fi
    if ! printf '%s\n' "$status_json" | jq -e '
      .stale == true
      and (.unresolved_candidate_roots == ["libs/"])
      and (.committed_unresolved_candidate_roots == ["libs/"])
      and ((.committed_product_files_since_sync // .committed_surface_files_since_sync // .committed_src_files_since_sync // []) == [])
    ' >/dev/null 2>&1; then
      echo "detail: committed undeclared candidate-root HEAD advance status did not report unresolved candidate root" >&2
      failed=1
    fi
    if [[ ! -f "$freshness_file" ]] || ! jq -e --arg baseline "$baseline_head" --arg current "$current_head" '
      .head_sha == $baseline
      and .head_sha != $current
      and ((.changed_product_files // .changed_surface_files // .changed_src_files // []) == [])
    ' "$freshness_file" >/dev/null 2>&1; then
      echo "detail: undeclared candidate-root HEAD advance unexpectedly refreshed baseline artifact" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

_requested_test_ids_valid() {
  local requested_id

  for requested_id in "${REQUESTED_TEST_IDS[@]}"; do
    if ! test_description "$requested_id" >/dev/null 2>&1; then
      echo "ERROR: unknown semantic sync freshness test id: $requested_id" >&2
      return 1
    fi
  done
}

_should_run_test() {
  local test_id="$1"
  local requested_id

  if [[ "${#REQUESTED_TEST_IDS[@]}" -eq 0 ]]; then
    return 0
  fi

  for requested_id in "${REQUESTED_TEST_IDS[@]}"; do
    if [[ "$requested_id" == "$test_id" ]]; then
      return 0
    fi
  done

  return 1
}

_kill_test_tree() {
  local pid="$1"
  local signal="${2:-TERM}"
  local child_pid

  while IFS= read -r child_pid; do
    [[ -n "$child_pid" ]] || continue
    _kill_test_tree "$child_pid" "$signal"
  done < <(pgrep -P "$pid" 2>/dev/null || true)

  kill "-$signal" "$pid" 2>/dev/null || true
}

_print_test_tree() {
  local root_pid="$1"
  local ps_file

  ps_file="$(mktemp)"
  ps -ax -o pid,ppid,pgid,etime,stat,command > "$ps_file" 2>/dev/null || {
    /bin/rm -f "$ps_file"
    return 0
  }
  awk -v root="$root_pid" '
    {
      line[NR] = $0
      pid[NR] = $1
      ppid[NR] = $2
    }
    END {
      seen[root] = 1
      changed = 1
      while (changed) {
        changed = 0
        for (i = 1; i <= NR; i++) {
          if (seen[ppid[i]] && !seen[pid[i]]) {
            seen[pid[i]] = 1
            changed = 1
          }
        }
      }
      for (i = 1; i <= NR; i++) {
        if (seen[pid[i]]) {
          print line[i]
        }
      }
    }
  ' "$ps_file" >&2
  /bin/rm -f "$ps_file"
}

_run_with_timeout() {
  local test_id="$1"
  local fn="$2"
  local timeout_secs="$SEMANTIC_SYNC_FRESHNESS_TEST_TIMEOUT_SECS"
  local out_file err_file pid elapsed status

  if [[ "$timeout_secs" == "0" ]]; then
    "$fn"
    return $?
  fi
  if [[ ! "$timeout_secs" =~ ^[1-9][0-9]*$ ]]; then
    echo "detail: invalid SEMANTIC_SYNC_FRESHNESS_TEST_TIMEOUT_SECS=$timeout_secs" >&2
    return 2
  fi

  out_file="$(mktemp)"
  err_file="$(mktemp)"
  (
    "$fn"
  ) > "$out_file" 2> "$err_file" &
  pid=$!
  elapsed=0

  while kill -0 "$pid" 2>/dev/null; do
    if [[ "$elapsed" -ge "$timeout_secs" ]]; then
      echo "detail: $test_id timed out after ${timeout_secs}s" >&2
      _print_test_tree "$pid"
      _kill_test_tree "$pid"
      sleep 1
      _kill_test_tree "$pid" KILL
      wait "$pid" 2>/dev/null || true
      cat "$out_file"
      cat "$err_file" >&2
      /bin/rm -f "$out_file" "$err_file"
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$pid"
  status=$?
  cat "$out_file"
  cat "$err_file" >&2
  /bin/rm -f "$out_file" "$err_file"
  return "$status"
}

run_test() {
  local test_id="$1"
  local fn="$2"

  if ! _should_run_test "$test_id"; then
    return 0
  fi

  echo "[TEST] $test_id - $(test_description "$test_id")"
  if _run_with_timeout "$test_id" "$fn"; then
    echo "PASS: $test_id"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $test_id"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo
}

_requested_test_ids_valid || exit 2

run_test F1 test_f1_context_update_records_freshness
run_test F2 test_f2_prepare_blocks_when_stale
run_test F3 test_f3_gate_passes_with_no_changed_src
run_test F4 test_f4_delete_after_sync_blocks
run_test F5 test_f5_docs_only_head_advance_stays_fresh
run_test F6 test_f6_committed_src_head_advance_blocks_after_empty_scope_sync
run_test F7 test_f7_committed_undeclared_candidate_root_head_advance_blocks_after_empty_scope_sync

echo "RESULT: pass=$PASS_COUNT fail=$FAIL_COUNT"
[[ "$FAIL_COUNT" -eq 0 ]]
