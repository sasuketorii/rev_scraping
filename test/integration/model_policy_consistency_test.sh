#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TMP_ROOT=""

cleanup() {
  /bin/rm -rf -- "${TMP_ROOT:-}" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "required command not found: $1"
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "missing expected text: $needle"
}

assert_not_invoked() {
  local file="$1"
  [[ ! -s "$file" ]] || fail "codex subprocess was unexpectedly invoked"
}

setup_wrapper_repo() {
  local repo="$1"
  mkdir -p "$repo/scripts" "$repo/.agent/registry" "$repo/.agent/generated" "$repo/.shared"
  cp "$PROJECT_ROOT/scripts/codex-wrapper.sh" "$repo/scripts/codex-wrapper.sh"
  cp "$PROJECT_ROOT/scripts/_canonical-guard.sh" "$repo/scripts/_canonical-guard.sh"
  cp "$PROJECT_ROOT/scripts/_outbound-deny.sh" "$repo/scripts/_outbound-deny.sh"
  cp "$PROJECT_ROOT/.agent/registry/model_policy.json" "$repo/.agent/registry/model_policy.json"
  cp "$PROJECT_ROOT/.agent/generated/codex_model_policy.runtime.json" "$repo/.agent/generated/codex_model_policy.runtime.json"
  printf '%s\n' 'model-policy-fixture' > "$repo/.shared/project_id"
  chmod +x "$repo/scripts/codex-wrapper.sh"
}

setup_mock_codex() {
  local dir="$1"
  mkdir -p "$dir/mockbin"
  cat > "$dir/mockbin/codex" <<'EOF'
#!/usr/bin/env bash
printf 'argv=%s\n' "$*" >> "${MOCK_CODEX_LOG:?}"
cat >/dev/null || true
printf 'mock-codex-output\n'
EOF
  chmod +x "$dir/mockbin/codex"
}

run_wrapper_expect_fail() {
  local repo="$1"
  local mockbin="$2"
  local log="$3"
  local stderr_file="$4"

  if MOCK_CODEX_LOG="$log" PATH="$mockbin:$PATH" \
    bash "$repo/scripts/codex-wrapper.sh" --role coder --stdin \
      > /dev/null 2> "$stderr_file" <<< "policy negative"; then
    fail "wrapper unexpectedly succeeded"
  fi
  assert_not_invoked "$log"
}

test_policy_cli_baseline() {
  local forbidden_candidate="gpt-5.6" # example_forbidden_model future candidate
  local current_official_url="https://developers.openai.com/codex/models"
  bash "$PROJECT_ROOT/scripts/model-policy.sh" validate >/dev/null
  bash "$PROJECT_ROOT/scripts/model-policy.sh" generate --check >/dev/null
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run --candidate "$forbidden_candidate" \
    --official-url "$current_official_url" --checked-at 2026-04-25 \
    > "$TMP_ROOT/migrate.stdout" 2> "$TMP_ROOT/migrate.stderr"; then
    fail "gpt-5.6 candidate migration unexpectedly passed without official exact evidence" # example_forbidden_model future candidate
  fi
  assert_contains "official evidence lacks exact candidate id" "$TMP_ROOT/migrate.stderr"

  local near_context_policy="$TMP_ROOT/near-context-policy.json"
  local near_context_runtime="$TMP_ROOT/near-context-runtime.json"
  local original_path="$PATH"
  local fakebin="$TMP_ROOT/fakebin"
  mkdir -p "$fakebin"
  cp "$PROJECT_ROOT/.agent/registry/model_policy.json" "$near_context_policy"
  cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'gpt-5.6 is not available in Codex. Use gpt-5.5 for Codex CLI and SDK because it is available.' # example_forbidden_model fake official evidence
EOF
  chmod +x "$fakebin/curl"
  if PATH="$fakebin:$original_path" bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run \
    --policy-path "$near_context_policy" --generated-path "$near_context_runtime" \
    --candidate "$forbidden_candidate" --official-url "$current_official_url" --checked-at 2026-04-25 \
    > "$TMP_ROOT/near-negative.stdout" 2> "$TMP_ROOT/near-negative.stderr"; then
    fail "negative near-candidate availability context unexpectedly passed"
  fi
  assert_contains "official evidence lacks exact candidate id" "$TMP_ROOT/near-negative.stderr"

  cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'gpt-5.6 unavailable. Codex CLI and SDK are available for gpt-5.5.' # example_forbidden_model fake official evidence
EOF
  chmod +x "$fakebin/curl"
  if PATH="$fakebin:$original_path" bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run \
    --policy-path "$near_context_policy" --generated-path "$near_context_runtime" \
    --candidate "$forbidden_candidate" --official-url "$current_official_url" --checked-at 2026-04-25 \
    > "$TMP_ROOT/near-unavailable.stdout" 2> "$TMP_ROOT/near-unavailable.stderr"; then
    fail "unavailable candidate context unexpectedly passed"
  fi
  assert_contains "official evidence lacks exact candidate id" "$TMP_ROOT/near-unavailable.stderr"

  cat > "$fakebin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'gpt-5.6 is available for Codex CLI and SDK. Older text elsewhere says gpt-5.5 is available.' # example_forbidden_model fake official evidence
EOF
  chmod +x "$fakebin/curl"
  PATH="$fakebin:$original_path" bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run \
    --policy-path "$near_context_policy" --generated-path "$near_context_runtime" \
    --candidate "$forbidden_candidate" --official-url "$current_official_url" --checked-at 2026-04-25 \
    > "$TMP_ROOT/near-positive.stdout" 2> "$TMP_ROOT/near-positive.stderr"
  assert_contains "DRY-RUN: candidate $forbidden_candidate would be registered" "$TMP_ROOT/near-positive.stdout"

  if bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run --candidate "$forbidden_candidate" \
    --official-url https://openai.com/not-a-doc --checked-at 2026-04-25 \
    > "$TMP_ROOT/ambiguous-url.stdout" 2> "$TMP_ROOT/ambiguous-url.stderr"; then
    fail "ambiguous official URL unexpectedly passed"
  fi
  assert_contains "not an accepted OpenAI/Codex official docs URL" "$TMP_ROOT/ambiguous-url.stderr"

  printf '%s\n' "Official Codex docs say $forbidden_candidate is available." > "$TMP_ROOT/fake-official.txt"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run --candidate "$forbidden_candidate" \
    --official-url "$current_official_url" --checked-at 2026-04-25 \
    --official-evidence-file "$TMP_ROOT/fake-official.txt" \
    > "$TMP_ROOT/local-fake.stdout" 2> "$TMP_ROOT/local-fake.stderr"; then
    fail "local fake official evidence unexpectedly passed"
  fi
  assert_contains "local official evidence files are forbidden" "$TMP_ROOT/local-fake.stderr"
}

test_stale_ref_classification() {
  local scan="$TMP_ROOT/stale-scan"

  mkdir -p "$scan/test/integration"
  printf '%s\n' 'codex exec -c model=gpt-5.4 --stdin' > "$scan/test/integration/runtime.sh" # example_forbidden_model fixture content
  if MODEL_POLICY_SCAN_ROOT="$scan" bash "$PROJECT_ROOT/scripts/model-policy.sh" stale-refs \
    > "$TMP_ROOT/strict.stdout" 2> "$TMP_ROOT/strict.stderr"; then
    fail "strict runtime stale ref unexpectedly passed"
  fi
  assert_contains $'BLOCK\ttest/integration/runtime.sh' "$TMP_ROOT/strict.stdout"

  /bin/rm -rf "$scan"
  mkdir -p "$scan/test/integration"
  printf '%s\n' 'model=gpt-5.4 # current gpt-5.5' > "$scan/test/integration/mixed.sh" # example_forbidden_model fixture content
  if MODEL_POLICY_SCAN_ROOT="$scan" bash "$PROJECT_ROOT/scripts/model-policy.sh" stale-refs \
    > "$TMP_ROOT/mixed.stdout" 2> "$TMP_ROOT/mixed.stderr"; then
    fail "mixed current/stale strict runtime ref unexpectedly passed"
  fi
  assert_contains $'BLOCK\ttest/integration/mixed.sh' "$TMP_ROOT/mixed.stdout"

  /bin/rm -rf "$scan"
  mkdir -p "$scan/.agent/active" "$scan/.agent/active/prompts"
  printf '%s\n' 'use gpt-5.4 only' > "$scan/.agent/active/imperative.md" # example_forbidden_model fixture content
  if MODEL_POLICY_SCAN_ROOT="$scan" bash "$PROJECT_ROOT/scripts/model-policy.sh" stale-refs \
    > "$TMP_ROOT/active-block.stdout" 2> "$TMP_ROOT/active-block.stderr"; then
    fail "active imperative stale ref unexpectedly passed"
  fi
  assert_contains $'BLOCK\t.agent/active/imperative.md' "$TMP_ROOT/active-block.stdout"

  /bin/rm -rf "$scan"
  mkdir -p "$scan/.agent/active"
  printf '%s\n' 'official fallback: use gpt-5.4 only' > "$scan/.agent/active/fallback.md" # example_forbidden_model fixture content
  if MODEL_POLICY_SCAN_ROOT="$scan" bash "$PROJECT_ROOT/scripts/model-policy.sh" stale-refs \
    > "$TMP_ROOT/active-fallback.stdout" 2> "$TMP_ROOT/active-fallback.stderr"; then
    fail "active official fallback imperative stale ref unexpectedly passed"
  fi
  assert_contains $'BLOCK\t.agent/active/fallback.md' "$TMP_ROOT/active-fallback.stdout"

  /bin/rm -rf "$scan"
  mkdir -p "$scan/.agent/active"
  printf '%s\n' 'candidate migration: use gpt-5.4 only' > "$scan/.agent/active/candidate.md" # example_forbidden_model fixture content
  printf '%s\n' 'candidate worker: codex -m gpt-5.4' > "$scan/.agent/active/worker.md" # example_forbidden_model fixture content
  printf '%s\n' 'forbidden: model = "gpt-5.4"' > "$scan/.agent/active/forbidden.md" # example_forbidden_model fixture content
  if MODEL_POLICY_SCAN_ROOT="$scan" bash "$PROJECT_ROOT/scripts/model-policy.sh" stale-refs \
    > "$TMP_ROOT/active-broad.stdout" 2> "$TMP_ROOT/active-broad.stderr"; then
    fail "active broad policy context imperative stale refs unexpectedly passed"
  fi
  assert_contains $'BLOCK\t.agent/active/candidate.md' "$TMP_ROOT/active-broad.stdout"
  assert_contains $'BLOCK\t.agent/active/worker.md' "$TMP_ROOT/active-broad.stdout"
  assert_contains $'BLOCK\t.agent/active/forbidden.md' "$TMP_ROOT/active-broad.stdout"

  /bin/rm -rf "$scan"
  mkdir -p "$scan/.agent/active" "$scan/.agent/active/prompts"
  printf '%s\n' 'review report: reviewer (gpt-5.4 / xhigh) returned LGTM' > "$scan/.agent/active/report.md" # example_forbidden_model fixture content
  printf '%s\n' 'historical prompt used gpt-5.4' > "$scan/.agent/active/prompts/output.md" # example_forbidden_model fixture content
  printf '%s\n' 'log used gpt-5.4' > "$scan/log.txt" # example_forbidden_model fixture content
  MODEL_POLICY_SCAN_ROOT="$scan" bash "$PROJECT_ROOT/scripts/model-policy.sh" stale-refs \
    > "$TMP_ROOT/allow.stdout" 2> "$TMP_ROOT/allow.stderr"
  assert_contains $'WARN\t.agent/active/report.md' "$TMP_ROOT/allow.stdout"
  assert_contains $'ALLOW-HISTORICAL\t.agent/active/prompts/output.md' "$TMP_ROOT/allow.stdout"
  assert_contains $'ALLOW-HISTORICAL\tlog.txt' "$TMP_ROOT/allow.stdout"
}

test_migration_staged_paths() {
  local repo="$TMP_ROOT/migration"
  local policy="$repo/model_policy.json"
  local generated="$repo/runtime.json"
  local promoted_policy="$repo/promoted_policy.json"
  local promoted_generated="$repo/promoted_runtime.json"
  local official_url="https://developers.openai.com/codex/models"
  local candidate_model="gpt-5.5"
  local old_model="gpt-5.4" # example_forbidden_model staged migration baseline
  local older_model="gpt-5.3-codex" # example_forbidden_model staged migration baseline

  mkdir -p "$repo"
  jq --arg old_model "$old_model" --arg older_model "$older_model" '
    .current_model = $old_model
    | .stable_default_model = $old_model
    | .minimum_allowed_model = $old_model
    | .previous_model = $older_model
    | .candidate_model = null
    | .model_order = [$older_model, $old_model]
    | .native_agent_presets.model = $old_model
    | .official_sources[0].verified_model_ids = [$old_model]
  ' "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$policy"

  bash "$PROJECT_ROOT/scripts/model-policy.sh" generate --policy-path "$policy" --generated-path "$generated" >/dev/null
  bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --write --policy-path "$policy" --generated-path "$generated" \
    --candidate "$candidate_model" --official-url "$official_url" --checked-at 2026-04-25 >/dev/null
  [[ "$(jq -r '.candidate_model' "$policy")" == "$candidate_model" ]] || fail "candidate write did not update policy"
  bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --write --policy-path "$policy" --generated-path "$generated" \
    --promote-candidate >/dev/null
  [[ "$(jq -r '.current_model' "$policy")" == "$candidate_model" ]] || fail "promote did not set current model"

  cp "$policy" "$promoted_policy"
  cp "$generated" "$promoted_generated"

  bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --write --policy-path "$policy" --generated-path "$generated" \
    --rollback-to-previous >/dev/null
  [[ "$(jq -r '.current_model' "$policy")" == "$old_model" ]] || fail "rollback positive path did not restore previous model"

  bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --write --policy-path "$promoted_policy" --generated-path "$promoted_generated" \
    --raise-minimum "$candidate_model" >/dev/null
  [[ "$(jq -r '.minimum_allowed_model' "$promoted_policy")" == "$candidate_model" ]] || fail "raise-minimum did not update policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" migrate --dry-run --policy-path "$promoted_policy" --generated-path "$promoted_generated" \
    --rollback-to-previous > "$TMP_ROOT/rollback-fail.stdout" 2> "$TMP_ROOT/rollback-fail.stderr"; then
    fail "rollback below raised minimum unexpectedly passed"
  fi
  assert_contains "below minimum_allowed_model" "$TMP_ROOT/rollback-fail.stderr"
}

test_effort_lane_regression_guards() {
  local bad_policy="$TMP_ROOT/bad-policy.json"
  local bad_runtime="$TMP_ROOT/bad-runtime.json"

  jq '.roles.coder.model_reasoning_effort = "high"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/coder-high.stdout" 2> "$TMP_ROOT/coder-high.stderr"; then
    fail "coder high-effort regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/coder-high.stderr"

  jq '.roles["high-coder"].model_reasoning_effort = "medium"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/high-coder-medium.stdout" 2> "$TMP_ROOT/high-coder-medium.stderr"; then
    fail "high-coder medium-effort regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/high-coder-medium.stderr"

  jq '.roles["high-coder"].web_search = "live"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/high-coder-live.stdout" 2> "$TMP_ROOT/high-coder-live.stderr"; then
    fail "high-coder live-search regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/high-coder-live.stderr"

  jq '.routing_lanes.complex_coder.entrypoint = "native high-effort escalation"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/complex-entrypoint.stdout" 2> "$TMP_ROOT/complex-entrypoint.stderr"; then
    fail "complex coder non-wrapper entrypoint regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/complex-entrypoint.stderr"

  jq '
    .native_agent_presets.medium_effort_agents = []
    | .native_agent_presets.high_effort_agents = [
        "alternative_reviewer",
        "coder",
        "consistency_reviewer",
        "performance_reviewer",
        "stack_upgrade_researcher"
      ]
  ' "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/all-high.stdout" 2> "$TMP_ROOT/all-high.stderr"; then
    fail "all-high native agent regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/all-high.stderr"

  jq '
    .native_agent_presets.xhigh_effort_agents = (
      .native_agent_presets.xhigh_effort_agents | map(select(. != "security_reviewer"))
    )
    | .native_agent_presets.medium_effort_agents += ["security_reviewer"]
  ' "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/security-medium.stdout" 2> "$TMP_ROOT/security-medium.stderr"; then
    fail "security reviewer medium-effort regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/security-medium.stderr"

  jq '.routing_lanes.final_release_truth_wrapper_model_policy_reviewer.model_reasoning_effort = "high"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/final-high.stdout" 2> "$TMP_ROOT/final-high.stderr"; then
    fail "final/truth/wrapper reviewer non-xhigh regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/final-high.stderr"

  jq '.routing_lanes.initial_execplan_design.model_reasoning_effort = "high"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/initial-execplan-high.stdout" 2> "$TMP_ROOT/initial-execplan-high.stderr"; then
    fail "initial ExecPlan design non-xhigh regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/initial-execplan-high.stderr"

  jq '.native_agent_presets.lane_requirements.initial_execplan_design.model_reasoning_effort = "medium"' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/initial-execplan-medium-requirement.stdout" 2> "$TMP_ROOT/initial-execplan-medium-requirement.stderr"; then
    fail "initial ExecPlan design medium lane requirement unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/initial-execplan-medium-requirement.stderr"

  jq '
    .native_agent_presets.xhigh_effort_agents = (
      .native_agent_presets.xhigh_effort_agents | map(select(. != "system_planner"))
    )
    | .native_agent_presets.medium_effort_agents += ["system_planner"]
  ' "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/system-planner-medium.stdout" 2> "$TMP_ROOT/system-planner-medium.stderr"; then
    fail "system planner medium-effort regression unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/system-planner-medium.stderr"

  jq '.native_agent_presets.lane_requirements.performance_reviewer.deterministic_benchmark_or_check_required = false' \
    "$PROJECT_ROOT/.agent/registry/model_policy.json" > "$bad_policy"
  if bash "$PROJECT_ROOT/scripts/model-policy.sh" validate \
    --policy-path "$bad_policy" --generated-path "$bad_runtime" \
    > "$TMP_ROOT/perf-check.stdout" 2> "$TMP_ROOT/perf-check.stderr"; then
    fail "performance reviewer without deterministic benchmark/check requirement unexpectedly passed"
  fi
  assert_contains "policy registry schema or invariant check failed" "$TMP_ROOT/perf-check.stderr"
}

test_docs_contract_runtime_mirrors() {
  assert_contains 'scripts/codex-wrapper.sh --role <standard|research|coder|high-coder|reviewer>' \
    "$PROJECT_ROOT/.agent/PROJECT_CONTEXT.md"
  assert_contains 'high.sh -> high-coder' "$PROJECT_ROOT/CLAUDE.md"
  assert_contains 'high.sh -> high-coder' "$PROJECT_ROOT/docs/manual/agent_review_loop.md"
  assert_contains 'high.sh -> high-coder' "$PROJECT_ROOT/docs/roles/orchestrator.md"
  assert_contains 'high-coder -> high/cached' "$PROJECT_ROOT/.claude/commands/README.md"

  if grep -Fq 'scripts/codex-wrapper.sh --role <standard|research|coder|reviewer>' \
    "$PROJECT_ROOT/.agent/PROJECT_CONTEXT.md" \
    "$PROJECT_ROOT/CLAUDE.md" \
    "$PROJECT_ROOT/docs/manual/agent_review_loop.md" \
    "$PROJECT_ROOT/docs/roles/orchestrator.md" \
    "$PROJECT_ROOT/.claude/commands/README.md"; then
    fail "stale caller-facing Codex role list found in runtime docs"
  fi

  if grep -Fq 'high.sh -> coder' \
    "$PROJECT_ROOT/CLAUDE.md" \
    "$PROJECT_ROOT/docs/manual/agent_review_loop.md" \
    "$PROJECT_ROOT/docs/roles/orchestrator.md"; then
    fail "stale high.sh shim mapping found in runtime docs"
  fi
}

test_wrapper_policy_fail_closed() {
  local repo="$TMP_ROOT/wrapper-repo"
  local mock_dir="$TMP_ROOT/wrapper-mock"
  local log="$TMP_ROOT/codex.log"
  local below_minimum_model="gpt-5.4" # example_forbidden_model generated artifact mutation

  setup_wrapper_repo "$repo"
  setup_mock_codex "$mock_dir"
  : > "$log"

  /bin/rm -f "$repo/.agent/generated/codex_model_policy.runtime.json"
  run_wrapper_expect_fail "$repo" "$mock_dir/mockbin" "$log" "$TMP_ROOT/missing.stderr"
  assert_contains "missing generated model policy" "$TMP_ROOT/missing.stderr"

  setup_wrapper_repo "$repo"
  : > "$log"
  printf '{broken json\n' > "$repo/.agent/generated/codex_model_policy.runtime.json"
  run_wrapper_expect_fail "$repo" "$mock_dir/mockbin" "$log" "$TMP_ROOT/corrupt.stderr"
  assert_contains "invalid generated model policy JSON" "$TMP_ROOT/corrupt.stderr"

  setup_wrapper_repo "$repo"
  : > "$log"
  jq '.official_sources[0].checked_at = "2099-01-01"' \
    "$repo/.agent/registry/model_policy.json" > "$repo/.agent/registry/model_policy.json.tmp"
  mv "$repo/.agent/registry/model_policy.json.tmp" "$repo/.agent/registry/model_policy.json"
  run_wrapper_expect_fail "$repo" "$mock_dir/mockbin" "$log" "$TMP_ROOT/hash.stderr"
  assert_contains "hash-mismatched" "$TMP_ROOT/hash.stderr"

  setup_wrapper_repo "$repo"
  : > "$log"
  jq --arg model "$below_minimum_model" '.minimum_allowed_model = $model' \
    "$repo/.agent/generated/codex_model_policy.runtime.json" > "$repo/.agent/generated/codex_model_policy.runtime.json.tmp"
  mv "$repo/.agent/generated/codex_model_policy.runtime.json.tmp" "$repo/.agent/generated/codex_model_policy.runtime.json"
  run_wrapper_expect_fail "$repo" "$mock_dir/mockbin" "$log" "$TMP_ROOT/minimum.stderr"
  assert_contains "minimum_allowed_model does not match source policy" "$TMP_ROOT/minimum.stderr"
}

main() {
  require_cmd bash
  require_cmd jq
  require_cmd grep
  TMP_ROOT="$(mktemp -d)"

  test_policy_cli_baseline
  test_stale_ref_classification
  test_migration_staged_paths
  test_effort_lane_regression_guards
  test_docs_contract_runtime_mirrors
  test_wrapper_policy_fail_closed

  printf 'PASS: model_policy_consistency_test\n'
}

main "$@"
