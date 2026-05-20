#!/usr/bin/env bash
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LIB_DIR="$PROJECT_ROOT/.claude/commands/lib"

PASS_COUNT=0
FAIL_COUNT=0
RUN_COUNT=0
TEST_FILTER="${SEMANTIC_REGISTRY_EXPORT_CONTRACT_TEST_FILTER:-${1:-}}"
TEST_TIMEOUT_SECONDS="${SEMANTIC_REGISTRY_EXPORT_CONTRACT_TEST_TIMEOUT_SECONDS:-60}"

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

json_matches() {
  local json="$1"
  shift

  printf '%s\n' "$json" | command jq "$@" >/dev/null 2>&1
}

write_fake_context_analysis() {
  local script_path="$1"
  local marker_path="$2"
  cat > "$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf 'called\n' > "$marker_path"
echo '[{"semantic_id":"stale:component","path":"src/stale.sh","symbol":"stale","kind":"function"}]'
EOF
  chmod +x "$script_path"
}

write_registry_export_meta() {
  local meta_path="$1"
  local project_id="$2"
  cat > "$meta_path" <<EOF
{"authority":"db","export":"components_jsonl","fresh":true,"project_id":"$project_id"}
EOF
}

install_canonical_project_id_helpers() {
  local repo_root="$1"
  mkdir -p "$repo_root/scripts"
  /bin/cp "$PROJECT_ROOT/scripts/project-id.sh" "$repo_root/scripts/project-id.sh"
  /bin/cp "$PROJECT_ROOT/scripts/resolve-semantic-project-id.sh" "$repo_root/scripts/resolve-semantic-project-id.sh"
  chmod +x "$repo_root/scripts/project-id.sh" "$repo_root/scripts/resolve-semantic-project-id.sh"
}

bootstrap_repo_local_project_id() {
  local repo_root="$1"
  local seed="$2"

  install_canonical_project_id_helpers "$repo_root"
  (
    cd "$repo_root"
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      git init -q
    fi
    bash scripts/resolve-semantic-project-id.sh --repo-root "$repo_root" --bootstrap "$seed"
  )
}

assert_merge_gate_block_payload() {
  local out="$1"
  local expected_failure_kind="$2"

  json_matches "$out" -e --arg expected_failure_kind "$expected_failure_kind" '
    .gate == "block"
    and .reconcile_required == true
    and .state == "reconcile_pending"
    and (.conflicts | type == "array")
    and ((.conflicts | length) == 1)
    and (.conflicts[0].component == "merge_gate_authority")
    and (.conflicts[0].failure_kind == $expected_failure_kind)
    and (.conflicts[0].reason | contains("merge-gate authority unavailable"))
  '
}

test_r1_context_analysis_registry_query_blocks_stale_export() {
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
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry"
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"stale:component","semantic_id":"stale:component","name":"stale","module":"src/stale.sh","file":"src/stale.sh","kind":"function","_status":"active","_updated":"2026-04-05T00:00:00Z","_idem":"stale"}
JSONL
    unset REGISTRY_EXPORT_COMPAT_ALLOW_READ

    out="$(registry_query 'true' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_query returned non-zero without truth gate (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: registry_query did not return conservative empty output" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r1b_context_analysis_registry_query_rejects_foreign_meta() {
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
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry"
    bootstrap_repo_local_project_id "$CONTEXT_REPO_ROOT" "LocalRepo" >/dev/null
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"foreign:component","semantic_id":"foreign:component","name":"foreign","module":"src/foreign.sh","file":"src/foreign.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_REPO_ROOT/.agent/registry/components.export.meta.json" "foreign-proj"
    REGISTRY_EXPORT_COMPAT_ALLOW_READ=1
    SEMANTIC_PROJECT_ID="local-proj"
    unset SEMANTIC_MCP_PROJECT_ID

    out="$(registry_query 'true' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_query returned non-zero for foreign export meta (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: registry_query accepted foreign export meta unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r1c_context_analysis_registry_query_rejects_legacy_project_id() {
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
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry"
    bootstrap_repo_local_project_id "$CONTEXT_REPO_ROOT" "LocalRepo" >/dev/null
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"legacy:component","semantic_id":"legacy:component","name":"legacy","module":"src/legacy.sh","file":"src/legacy.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_REPO_ROOT/.agent/registry/components.export.meta.json" "agent_base"
    REGISTRY_EXPORT_COMPAT_ALLOW_READ=1
    SEMANTIC_PROJECT_ID="agent_base"
    unset SEMANTIC_MCP_PROJECT_ID

    out="$(registry_query 'true' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_query returned non-zero for legacy project_id gate (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: registry_query accepted legacy project_id unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r1d_context_analysis_registry_query_uses_canonical_resolver_not_env() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir out rc project_id
    tmpdir="$(mktemp -d)"

    CONTEXT_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CONTEXT_DIR="$CONTEXT_REPO_ROOT/.agent/context"
    CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry"
    project_id="$(bootstrap_repo_local_project_id "$CONTEXT_REPO_ROOT" "LocalRepo")"
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"local:component","semantic_id":"local:component","name":"local","module":"src/local.sh","file":"src/local.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_REPO_ROOT/.agent/registry/components.export.meta.json" "$project_id"
    REGISTRY_EXPORT_COMPAT_ALLOW_READ=1
    SEMANTIC_PROJECT_ID="env-override"
    SEMANTIC_MCP_PROJECT_ID="env-override-mcp"

    out="$(registry_query 'true' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_query returned non-zero when canonical resolver should win over env (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 1 and .[0].logical_id == "local:component"'; then
      echo "detail: registry_query did not use canonical resolver over env override" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r1e_context_analysis_registry_query_requires_canonical_resolver_artifact() {
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
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry" "$CONTEXT_REPO_ROOT/.agent/identity"
    install_canonical_project_id_helpers "$CONTEXT_REPO_ROOT"
    printf 'legacy-bypass\n' > "$CONTEXT_REPO_ROOT/.agent/project_id"
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"legacy:component","semantic_id":"legacy:component","name":"legacy","module":"src/legacy.sh","file":"src/legacy.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_REPO_ROOT/.agent/registry/components.export.meta.json" "legacy-bypass"
    REGISTRY_EXPORT_COMPAT_ALLOW_READ=1

    out="$(registry_query 'true' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_query returned non-zero when canonical artifact was missing (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: registry_query accepted legacy direct-file bypass without canonical artifact" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r1f_context_analysis_registry_query_rejects_legacy_bootstrap_fallback() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir out rc project_id
    tmpdir="$(mktemp -d)"

    CONTEXT_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CONTEXT_DIR="$CONTEXT_REPO_ROOT/.agent/context"
    CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry" "$CONTEXT_REPO_ROOT/.agent"
    install_canonical_project_id_helpers "$CONTEXT_REPO_ROOT"
    printf 'legacy-bypass\n' > "$CONTEXT_REPO_ROOT/.agent/project_id"

    if bash "$CONTEXT_REPO_ROOT/scripts/resolve-semantic-project-id.sh" --repo-root "$CONTEXT_REPO_ROOT" --print \
      >"$tmpdir/legacy_print.stdout" 2>"$tmpdir/legacy_print.stderr"; then
      echo "detail: canonical resolver unexpectedly accepted legacy .agent/project_id without canonical artifact" >&2
      failed=1
    fi
    if ! contains_text "missing project_id artifact" "$(cat "$tmpdir/legacy_print.stderr")"; then
      echo "detail: canonical resolver did not fail closed on missing canonical project_id artifact" >&2
      failed=1
    fi

    project_id="$(bootstrap_repo_local_project_id "$CONTEXT_REPO_ROOT" "LocalRepo")"
    if [[ "$project_id" == "legacy-bypass" ]]; then
      echo "detail: canonical bootstrap still accepted legacy .agent/project_id fallback" >&2
      failed=1
    fi
    if [[ "$(tr -d '\r\n' < "$CONTEXT_REPO_ROOT/.shared/project_id")" != "$project_id" ]]; then
      echo "detail: canonical bootstrap did not write the resolved project_id to .shared/project_id" >&2
      failed=1
    fi
    if [[ "$(tr -d '\r\n' < "$CONTEXT_REPO_ROOT/.agent/project_id")" != "legacy-bypass" ]]; then
      echo "detail: canonical bootstrap rewrote legacy .agent/project_id unexpectedly" >&2
      failed=1
    fi

    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"legacy:component","semantic_id":"legacy:component","name":"legacy","module":"src/legacy.sh","file":"src/legacy.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_REPO_ROOT/.agent/registry/components.export.meta.json" "legacy-bypass"
    REGISTRY_EXPORT_COMPAT_ALLOW_READ=1
    unset SEMANTIC_PROJECT_ID
    unset SEMANTIC_MCP_PROJECT_ID

    out="$(registry_query 'true' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_query returned non-zero after canonical bootstrap ignored legacy fallback (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: registry_query still accepted legacy bootstrap fallback unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r2_preflight_move_marks_idem_without_jsonl_write() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir before after out rc
    tmpdir="$(mktemp -d)"

    CONTEXT_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CONTEXT_DIR="$CONTEXT_REPO_ROOT/.agent/context"
    CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry" "$CONTEXT_REPO_ROOT/src"
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"move:component","semantic_id":"move:component","name":"move","module":"src/old.sh","file":"src/old.sh","kind":"function","_status":"active","_updated":"2026-04-05T00:00:00Z","_idem":"before"}
JSONL
    before="$(cat "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl")"

    out="$(_preflight_apply_move_updates_and_idem_flag '[{"old_path":"src/old.sh","new_path":"src/new.sh","type":"rename"}]' '["src/old.sh"]')"
    rc=$?
    after="$(cat "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl")"

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _preflight_apply_move_updates_and_idem_flag failed (rc=$rc)" >&2
      failed=1
    fi
    if [[ "$out" != "true" ]]; then
      echo "detail: confirmed move did not force idem recalculation" >&2
      failed=1
    fi
    if [[ "$before" != "$after" ]]; then
      echo "detail: preflight move helper mutated components.jsonl unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r2b_registry_gc_fast_is_compatibility_noop() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir before after out out_locked rc rc_locked repomap_ids_file
    tmpdir="$(mktemp -d)"

    CONTEXT_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CONTEXT_DIR="$CONTEXT_REPO_ROOT/.agent/context"
    CONTEXT_REPOMAP_DIR="$CONTEXT_CONTEXT_DIR/repomap"
    mkdir -p "$CONTEXT_REPO_ROOT/.agent/registry"
    cat > "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"stale:component","semantic_id":"stale:component","name":"stale","module":"src/stale.sh","file":"src/stale.sh","kind":"function","_status":"active","_updated":"2026-04-05T00:00:00Z","_idem":"before"}
JSONL
    before="$(cat "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl")"
    repomap_ids_file="$tmpdir/repomap_ids.json"
    printf '[]\n' > "$repomap_ids_file"

    out="$(registry_gc_fast 2>/dev/null)"
    rc=$?
    out_locked="$(_registry_gc_fast_locked "$repomap_ids_file" 2>/dev/null)"
    rc_locked=$?
    after="$(cat "$CONTEXT_REPO_ROOT/.agent/registry/components.jsonl")"

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: registry_gc_fast compatibility path returned non-zero (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e '
      .action == "gc_fast"
      and .updated_count == 0
      and .compatibility_noop == true
      and .reason == "semantic_registry_export_debug_only"
    '; then
      echo "detail: registry_gc_fast did not emit explicit compatibility no-op contract" >&2
      failed=1
    fi
    if [[ "$rc_locked" -ne 0 ]]; then
      echo "detail: _registry_gc_fast_locked compatibility path returned non-zero (rc=$rc_locked)" >&2
      failed=1
    fi
    if ! json_matches "$out_locked" -e '
      .action == "gc_fast"
      and .updated_count == 0
      and .compatibility_noop == true
      and .reason == "semantic_registry_export_debug_only"
    '; then
      echo "detail: _registry_gc_fast_locked did not emit explicit compatibility no-op contract" >&2
      failed=1
    fi
    if [[ "$before" != "$after" ]]; then
      echo "detail: registry_gc_fast compatibility path mutated components.jsonl unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r3_mcp_mutator_fallback_is_blocked() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc tool payload
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    MCP_FALLBACK_CONTEXT_ANALYSIS="$fake_context"
    MCP_FORCE_CLI_FALLBACK=1

    for tool in "sem.registry.upsert" "sem.registry.set_status" "sem.registry.delete"; do
      case "$tool" in
        "sem.registry.upsert")
          payload='{"components":[{"logical_id":"m:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh"}]}'
          ;;
        "sem.registry.set_status")
          payload='{"semantic_id":"m:foo","status":"inactive"}'
          ;;
        "sem.registry.delete")
          payload='{"semantic_id":"m:foo"}'
          ;;
      esac

      /bin/rm -f "$marker"
      out="$(mcp_or_fallback "$tool" "$payload" 2>&1)"
      rc=$?

      if [[ "$rc" -eq 0 ]]; then
        echo "detail: $tool unexpectedly succeeded via CLI fallback" >&2
        failed=1
      fi
      if ! contains_text "blocked" "$out"; then
        echo "detail: $tool error message did not explain fail-closed cutover" >&2
        failed=1
      fi
      if [[ -e "$marker" ]]; then
        echo "detail: $tool touched context_analysis fallback unexpectedly" >&2
        failed=1
      fi
    done

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r3b_mcp_jsonrpc_error_payload_blocks_mutator() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local out rc

    mcp_call() {
      local tool_name="${1:-}"
      case "$tool_name" in
        "sem.health")
          echo '{"ok":true}'
          return 0
          ;;
        "sem.registry.upsert")
          echo '{"jsonrpc":"2.0","id":"2","error":{"code":-32000,"message":"backend unavailable"}}'
          return 0
          ;;
        *)
          return 1
          ;;
      esac
    }

    out="$(mcp_or_fallback "sem.registry.upsert" '{"components":[{"logical_id":"m:foo","name":"foo","module":"src/foo.sh","file":"src/foo.sh"}]}' 2>&1)"
    rc=$?

    if [[ "$rc" -eq 0 ]]; then
      echo "detail: sem.registry.upsert unexpectedly treated JSON-RPC error payload as success" >&2
      failed=1
    fi
    if ! contains_text "blocked" "$out"; then
      echo "detail: sem.registry.upsert did not fail closed after JSON-RPC error payload" >&2
      failed=1
    fi
    if contains_text '"jsonrpc":"2.0"' "$out"; then
      echo "detail: sem.registry.upsert leaked raw JSON-RPC error payload instead of fail-closed contract" >&2
      failed=1
    fi

    [[ "$failed" -eq 0 ]]
  )
}

test_r4_mcp_query_fallback_returns_empty_compatibility() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    MCP_FALLBACK_CONTEXT_ANALYSIS="$fake_context"
    MCP_FORCE_CLI_FALLBACK=1

    out="$(mcp_or_fallback "sem.registry.query" '{"limit":5,"offset":2}' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: sem.registry.query fallback returned non-zero (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e '.items == [] and .total == 0 and (.capsule | contains("compatibility:blocked"))'; then
      echo "detail: sem.registry.query fallback did not return conservative empty compatibility output" >&2
      failed=1
    fi
    if [[ -e "$marker" ]]; then
      echo "detail: sem.registry.query fallback revived context_analysis JSONL authority unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r4b_mcp_jsonrpc_error_payload_falls_back_to_empty_query_compatibility() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local out rc

    mcp_call() {
      local tool_name="${1:-}"
      case "$tool_name" in
        "sem.health")
          echo '{"ok":true}'
          return 0
          ;;
        "sem.registry.query")
          echo '{"jsonrpc":"2.0","id":"2","error":{"code":-32000,"message":"backend unavailable"}}'
          return 0
          ;;
        *)
          return 1
          ;;
      esac
    }

    out="$(mcp_or_fallback "sem.registry.query" '{"limit":5,"offset":2}' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: sem.registry.query returned non-zero after JSON-RPC error payload (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e '.items == [] and .total == 0 and (.capsule | contains("compatibility:blocked"))'; then
      echo "detail: sem.registry.query did not fall back to conservative empty compatibility after JSON-RPC error payload" >&2
      failed=1
    fi

    [[ "$failed" -eq 0 ]]
  )
}

test_r5_capsule_registry_compat_requires_explicit_meta() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    CONTEXT_CAPSULE_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CAPSULE_TMP_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.claude/tmp/capsule"
    CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
    CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$fake_context"
    CONTEXT_CAPSULE_REGISTRY_EXPORT_META="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.export.meta.json"
    mkdir -p "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry"
    cat > "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"stale:component","semantic_id":"stale:component","name":"stale","module":"src/stale.sh","file":"src/stale.sh","kind":"function"}
JSONL
    CAPSULE_ALLOW_REGISTRY_EXPORT_COMPAT=1

    out="$(_capsule_registry_compat_json 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _capsule_registry_compat_json returned non-zero (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: capsule registry compatibility did not stay conservative without meta gate" >&2
      failed=1
    fi
    if [[ -e "$marker" ]]; then
      echo "detail: capsule registry compatibility called context_analysis without explicit meta gate" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r5b_capsule_registry_compat_rejects_foreign_meta() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    CONTEXT_CAPSULE_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CAPSULE_TMP_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.claude/tmp/capsule"
    CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
    CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$fake_context"
    CONTEXT_CAPSULE_REGISTRY_EXPORT_META="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.export.meta.json"
    mkdir -p "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry"
    bootstrap_repo_local_project_id "$CONTEXT_CAPSULE_REPO_ROOT" "LocalRepo" >/dev/null
    cat > "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"foreign:component","semantic_id":"foreign:component","name":"foreign","module":"src/foreign.sh","file":"src/foreign.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_CAPSULE_REGISTRY_EXPORT_META" "foreign-proj"
    CAPSULE_ALLOW_REGISTRY_EXPORT_COMPAT=1
    SEMANTIC_PROJECT_ID="local-proj"
    unset SEMANTIC_MCP_PROJECT_ID

    out="$(_capsule_registry_compat_json 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _capsule_registry_compat_json returned non-zero for foreign meta (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: capsule registry compatibility accepted foreign meta unexpectedly" >&2
      failed=1
    fi
    if [[ -e "$marker" ]]; then
      echo "detail: capsule registry compatibility touched context_analysis for foreign meta unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r5c_capsule_registry_compat_rejects_legacy_project_id() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    CONTEXT_CAPSULE_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CAPSULE_TMP_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.claude/tmp/capsule"
    CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
    CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$fake_context"
    CONTEXT_CAPSULE_REGISTRY_EXPORT_META="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.export.meta.json"
    mkdir -p "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry"
    bootstrap_repo_local_project_id "$CONTEXT_CAPSULE_REPO_ROOT" "LocalRepo" >/dev/null
    cat > "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"legacy:component","semantic_id":"legacy:component","name":"legacy","module":"src/legacy.sh","file":"src/legacy.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_CAPSULE_REGISTRY_EXPORT_META" "agent_base"
    CAPSULE_ALLOW_REGISTRY_EXPORT_COMPAT=1
    SEMANTIC_PROJECT_ID="agent_base"
    unset SEMANTIC_MCP_PROJECT_ID

    out="$(_capsule_registry_compat_json 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _capsule_registry_compat_json returned non-zero for legacy project_id gate (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: capsule registry compatibility accepted legacy project_id unexpectedly" >&2
      failed=1
    fi
    if [[ -e "$marker" ]]; then
      echo "detail: capsule registry compatibility touched context_analysis for legacy project_id unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r5d_capsule_registry_compat_uses_canonical_resolver_not_env() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc project_id
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    CONTEXT_CAPSULE_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CAPSULE_TMP_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.claude/tmp/capsule"
    CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
    CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$fake_context"
    CONTEXT_CAPSULE_REGISTRY_EXPORT_META="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.export.meta.json"
    mkdir -p "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry"
    project_id="$(bootstrap_repo_local_project_id "$CONTEXT_CAPSULE_REPO_ROOT" "LocalRepo")"
    cat > "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"local:component","semantic_id":"local:component","name":"local","module":"src/local.sh","file":"src/local.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_CAPSULE_REGISTRY_EXPORT_META" "$project_id"
    CAPSULE_ALLOW_REGISTRY_EXPORT_COMPAT=1
    SEMANTIC_PROJECT_ID="env-override"
    SEMANTIC_MCP_PROJECT_ID="env-override-mcp"

    out="$(_capsule_registry_compat_json 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _capsule_registry_compat_json returned non-zero when canonical resolver should win over env (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 1 and .[0].semantic_id == "stale:component"'; then
      echo "detail: capsule registry compatibility did not use canonical resolver over env override" >&2
      failed=1
    fi
    if [[ ! -e "$marker" ]]; then
      echo "detail: capsule registry compatibility did not reach context_analysis on canonical positive path" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r5e_capsule_registry_compat_requires_canonical_resolver_artifact() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_capsule.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    CONTEXT_CAPSULE_REPO_ROOT="$tmpdir/repo"
    CONTEXT_CAPSULE_TMP_DIR="$CONTEXT_CAPSULE_REPO_ROOT/.claude/tmp/capsule"
    CONTEXT_CAPSULE_LOCK_DIR="$CONTEXT_CAPSULE_TMP_DIR/.lock"
    CONTEXT_CAPSULE_CONTEXT_ANALYSIS="$fake_context"
    CONTEXT_CAPSULE_REGISTRY_EXPORT_META="$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.export.meta.json"
    mkdir -p "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry" "$CONTEXT_CAPSULE_REPO_ROOT/.agent/identity"
    install_canonical_project_id_helpers "$CONTEXT_CAPSULE_REPO_ROOT"
    printf 'legacy-bypass\n' > "$CONTEXT_CAPSULE_REPO_ROOT/.agent/project_id"
    cat > "$CONTEXT_CAPSULE_REPO_ROOT/.agent/registry/components.jsonl" <<'JSONL'
{"logical_id":"legacy:component","semantic_id":"legacy:component","name":"legacy","module":"src/legacy.sh","file":"src/legacy.sh","kind":"function"}
JSONL
    write_registry_export_meta "$CONTEXT_CAPSULE_REGISTRY_EXPORT_META" "legacy-bypass"
    CAPSULE_ALLOW_REGISTRY_EXPORT_COMPAT=1

    out="$(_capsule_registry_compat_json 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: _capsule_registry_compat_json returned non-zero when canonical artifact was missing (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e 'type == "array" and length == 0'; then
      echo "detail: capsule registry compatibility accepted legacy direct-file bypass without canonical artifact" >&2
      failed=1
    fi
    if [[ -e "$marker" ]]; then
      echo "detail: capsule registry compatibility touched context_analysis without canonical artifact" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r6_mcp_preflight_fallback_is_fail_closed() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local tmpdir fake_context marker out rc
    tmpdir="$(mktemp -d)"
    fake_context="$tmpdir/context_analysis.sh"
    marker="$tmpdir/context_called"
    write_fake_context_analysis "$fake_context" "$marker"

    MCP_FALLBACK_CONTEXT_ANALYSIS="$fake_context"
    MCP_FORCE_CLI_FALLBACK=1

    out="$(mcp_or_fallback "sem.preflight" '{"task_id":"t1","project_id":"p1"}' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: sem.preflight fallback returned non-zero (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e '
      .verdict == "BLOCK"
      and (.conflicts | type == "array")
      and ((.conflicts | length) == 1)
      and (.conflicts[0].semantic_id == "sem.preflight")
      and (.conflicts[0].reason | contains("DB-authoritative MCP path required"))
      and (.delete_impacts_summary | contains("authority:blocked"))
      and (.capsule | contains("PREFLIGHT=BLOCK"))
    '; then
      echo "detail: sem.preflight fallback did not fail closed with compatibility payload" >&2
      failed=1
    fi
    if [[ -e "$marker" ]]; then
      echo "detail: sem.preflight fallback touched context_analysis unexpectedly" >&2
      failed=1
    fi

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

test_r6b_mcp_jsonrpc_error_payload_preflight_is_fail_closed() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/mcp_fallback.sh"
    set +e

    local failed=0
    local out rc

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

    out="$(mcp_or_fallback "sem.preflight" '{"task_id":"t1","project_id":"p1"}' 2>/dev/null)"
    rc=$?

    if [[ "$rc" -ne 0 ]]; then
      echo "detail: sem.preflight returned non-zero after JSON-RPC error payload (rc=$rc)" >&2
      failed=1
    fi
    if ! json_matches "$out" -e '
      .verdict == "BLOCK"
      and (.conflicts | type == "array")
      and ((.conflicts | length) == 1)
      and (.conflicts[0].semantic_id == "sem.preflight")
      and (.conflicts[0].reason | contains("DB-authoritative MCP path required"))
      and (.delete_impacts_summary | contains("authority:blocked"))
      and (.capsule | contains("PREFLIGHT=BLOCK"))
    '; then
      echo "detail: sem.preflight did not return fail-closed BLOCK contract after JSON-RPC error payload" >&2
      failed=1
    fi

    [[ "$failed" -eq 0 ]]
  )
}

test_r7_check_merge_gate_blocks_when_authority_is_unavailable() {
  (
    set -u -o pipefail
    # shellcheck source=/dev/null
    source "$LIB_DIR/context_analysis.sh"
    set +e

    local failed=0
    local tmpdir repo_root worktree_root valid_registry_line
    tmpdir="$(mktemp -d)"
    repo_root="$tmpdir/repo"
    worktree_root="$repo_root/worktree"
    valid_registry_line='{"logical_id":"cmp:1","semantic_id":"cmp:1","_idem":"idem-1","_updated":"2026-04-05T00:00:00Z"}'
    mkdir -p "$worktree_root/.agent/registry" "$repo_root/peer"

    git() {
      local cwd=""
      if [[ "${1:-}" == "-C" ]]; then
        cwd="${2:-}"
        shift 2
      fi

      case "${1:-}" in
        rev-parse)
          if [[ "${2:-}" == "--show-toplevel" ]]; then
            printf '%s\n' "$repo_root"
            return 0
          fi
          return 1
          ;;
        worktree)
          if [[ "${2:-}" == "list" && "${3:-}" == "--porcelain" ]]; then
            if [[ "${MERGE_GATE_SCENARIO:-}" == "worktree_list_failed" ]]; then
              return 1
            fi
            printf 'worktree %s\n' "$worktree_root"
            printf 'worktree %s\n' "$repo_root/peer"
            return 0
          fi
          ;;
        merge-base)
          if [[ "${MERGE_GATE_SCENARIO:-}" == "merge_base_failed" ]]; then
            return 1
          fi
          printf 'base-commit\n'
          return 0
          ;;
        show)
          case "${2:-}" in
            base-commit:.agent/registry/components.jsonl)
              if [[ "${MERGE_GATE_SCENARIO:-}" == "base_registry_parse_failed" ]]; then
                printf '{invalid\n'
              else
                printf '%s\n' "$valid_registry_line"
              fi
              return 0
              ;;
            HEAD:.agent/registry/components.jsonl)
              if [[ "${MERGE_GATE_SCENARIO:-}" == "target_registry_parse_failed" ]]; then
                printf '{invalid\n'
              else
                printf '%s\n' "$valid_registry_line"
              fi
              return 0
              ;;
          esac
          ;;
      esac

      if [[ -n "$cwd" ]]; then
        return 1
      fi
      return 1
    }

    run_case() {
      local scenario="$1"
      local expected_failure_kind="$2"
      local out rc

      MERGE_GATE_SCENARIO="$scenario"
      /bin/rm -f "$worktree_root/.agent/registry/components.jsonl"
      printf '%s\n' "$valid_registry_line" > "$worktree_root/.agent/registry/components.jsonl"
      unset -f jq 2>/dev/null || true

      case "$scenario" in
        missing_or_empty_source_registry)
          /bin/rm -f "$worktree_root/.agent/registry/components.jsonl"
          ;;
        source_registry_parse_failed)
          printf '{invalid\n' > "$worktree_root/.agent/registry/components.jsonl"
          ;;
        conflict_analysis_failed)
          jq() {
            local arg=""
            for arg in "$@"; do
              if [[ "$arg" == "--slurpfile" ]]; then
                return 1
              fi
            done
            command jq "$@"
          }
          ;;
      esac

      out="$(check_merge_gate "$worktree_root" main 2>/dev/null)"
      rc=$?

      if [[ "$rc" -ne 0 ]]; then
        echo "detail: check_merge_gate returned non-zero for $scenario (rc=$rc)" >&2
        failed=1
        return
      fi
      if ! assert_merge_gate_block_payload "$out" "$expected_failure_kind"; then
        echo "detail: check_merge_gate did not emit fail-closed BLOCK payload for $scenario" >&2
        failed=1
      fi
    }

    run_case "missing_or_empty_source_registry" "missing_or_empty_source_registry"
    run_case "worktree_list_failed" "worktree_list_failed"
    run_case "authoritative_merge_gate_unavailable" "authoritative_merge_gate_unavailable"
    run_case "merge_base_failed" "merge_base_failed"
    run_case "source_registry_parse_failed" "source_registry_parse_failed"
    run_case "base_registry_parse_failed" "base_registry_parse_failed"
    run_case "target_registry_parse_failed" "target_registry_parse_failed"
    run_case "conflict_analysis_failed" "conflict_analysis_failed"

    /bin/rm -rf "$tmpdir"
    [[ "$failed" -eq 0 ]]
  )
}

run_test() {
  local name="$1"
  local fn="$2"
  local tmpdir stdout_file stderr_file status_file pid watchdog rc timed_out

  if [[ -n "$TEST_FILTER" && "$name" != *"$TEST_FILTER"* && "$fn" != *"$TEST_FILTER"* ]]; then
    return
  fi

  RUN_COUNT=$((RUN_COUNT + 1))
  echo "[TEST] $name"
  tmpdir="$(mktemp -d)"
  stdout_file="$tmpdir/stdout"
  stderr_file="$tmpdir/stderr"
  status_file="$tmpdir/status"
  : > "$status_file"

  "$fn" > "$stdout_file" 2> "$stderr_file" &
  pid=$!
  (
    sleep_pid=""
    trap '[[ -n "$sleep_pid" ]] && kill "$sleep_pid" 2>/dev/null || true; exit 0' TERM INT
    sleep "$TEST_TIMEOUT_SECONDS" &
    sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || exit 0
    if kill -0 "$pid" 2>/dev/null; then
      printf 'timeout\n' > "$status_file"
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
    fi
  ) >/dev/null 2>&1 &
  watchdog=$!

  wait "$pid"
  rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true

  cat "$stdout_file"
  cat "$stderr_file" >&2
  timed_out="$(cat "$status_file")"
  /bin/rm -rf "$tmpdir"

  if [[ "$timed_out" == "timeout" ]]; then
    echo "FAIL: $name"
    echo "detail: $fn exceeded ${TEST_TIMEOUT_SECONDS}s watchdog; killed fail-closed" >&2
    FAIL_COUNT=$((FAIL_COUNT + 1))
  elif [[ "$rc" -eq 0 ]]; then
    echo "PASS: $name"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $name"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
  echo
}

main() {
  require_cmd git
  require_cmd jq
  require_cmd mktemp

  run_test "R1 context_analysis registry_query blocks stale export" test_r1_context_analysis_registry_query_blocks_stale_export
  run_test "R1B context_analysis registry_query rejects foreign meta" test_r1b_context_analysis_registry_query_rejects_foreign_meta
  run_test "R1C context_analysis registry_query rejects legacy project_id" test_r1c_context_analysis_registry_query_rejects_legacy_project_id
  run_test "R1D context_analysis registry_query uses canonical resolver not env" test_r1d_context_analysis_registry_query_uses_canonical_resolver_not_env
  run_test "R1E context_analysis registry_query requires canonical resolver artifact" test_r1e_context_analysis_registry_query_requires_canonical_resolver_artifact
  run_test "R1F context_analysis registry_query rejects legacy bootstrap fallback" test_r1f_context_analysis_registry_query_rejects_legacy_bootstrap_fallback
  run_test "R2 preflight move marks idem without JSONL write" test_r2_preflight_move_marks_idem_without_jsonl_write
  run_test "R2B registry_gc_fast is compatibility no-op" test_r2b_registry_gc_fast_is_compatibility_noop
  run_test "R3 MCP mutator fallback is blocked" test_r3_mcp_mutator_fallback_is_blocked
  run_test "R3B MCP JSON-RPC error payload blocks mutator" test_r3b_mcp_jsonrpc_error_payload_blocks_mutator
  run_test "R4 MCP query fallback returns empty compatibility" test_r4_mcp_query_fallback_returns_empty_compatibility
  run_test "R4B MCP JSON-RPC error payload falls back to empty query compatibility" test_r4b_mcp_jsonrpc_error_payload_falls_back_to_empty_query_compatibility
  run_test "R5 capsule registry compatibility requires explicit meta" test_r5_capsule_registry_compat_requires_explicit_meta
  run_test "R5B capsule registry compatibility rejects foreign meta" test_r5b_capsule_registry_compat_rejects_foreign_meta
  run_test "R5C capsule registry compatibility rejects legacy project_id" test_r5c_capsule_registry_compat_rejects_legacy_project_id
  run_test "R5D capsule registry compatibility uses canonical resolver not env" test_r5d_capsule_registry_compat_uses_canonical_resolver_not_env
  run_test "R5E capsule registry compatibility requires canonical resolver artifact" test_r5e_capsule_registry_compat_requires_canonical_resolver_artifact
  run_test "R6 MCP preflight fallback is fail-closed" test_r6_mcp_preflight_fallback_is_fail_closed
  run_test "R6B MCP JSON-RPC error payload preflight is fail-closed" test_r6b_mcp_jsonrpc_error_payload_preflight_is_fail_closed
  run_test "R7 check_merge_gate blocks when authority is unavailable" test_r7_check_merge_gate_blocks_when_authority_is_unavailable

  if [[ -n "$TEST_FILTER" && "$RUN_COUNT" -eq 0 ]]; then
    echo "ERROR: no tests matched filter: $TEST_FILTER" >&2
    exit 2
  fi

  echo "RESULT: pass=$PASS_COUNT fail=$FAIL_COUNT"
  if [[ "$FAIL_COUNT" -gt 0 ]]; then
    exit 1
  fi
}

main "$@"
