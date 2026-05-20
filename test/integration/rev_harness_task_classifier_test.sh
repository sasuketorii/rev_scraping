#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CLASSIFIER="$PROJECT_ROOT/scripts/rev-harness-task-classifier.sh"

assert_class() {
  local expected_class="$1"
  local expected_tier="$2"
  local expected_review="$3"
  local expected_final="$4"
  local expected_profile="$5"
  shift 5
  local json=""

  json="$("$CLASSIFIER" classify "$@" --json)"

  jq -e \
    --arg expected_class "$expected_class" \
    --arg expected_tier "$expected_tier" \
    --arg expected_profile "$expected_profile" \
    --argjson expected_review "$expected_review" \
    --argjson expected_final "$expected_final" \
    '.schema_version == "rev-harness-task-classifier/v1"
      and .task_class == $expected_class
      and .gate_tier == $expected_tier
      and .schema_profile == $expected_profile
      and .review_required == $expected_review
      and .final_reviewer_gate_required == $expected_final' \
    <<<"$json" >/dev/null
}

assert_class \
  light quick false false light-change-record \
  --intent typo --files docs/manual/harness-user-guide.md

assert_class \
  standard local true false standard-slice-contract \
  --intent implementation --files src/example.ts

assert_class \
  standard local true false standard-slice-contract \
  --intent implementation --files workspace/orchestrator-smoke-demo/app.js

workspace_json="$("$CLASSIFIER" classify --intent implementation --files workspace/orchestrator-smoke-demo/app.js --json)"
jq -e '.reasons | index("disposable workspace surface: workspace/orchestrator-smoke-demo/app.js")' \
  <<<"$workspace_json" >/dev/null

assert_class \
  standard local true false standard-slice-contract \
  --intent prompt-wording --files .agent/active/sow/task-lineage-ledger.md

assert_class \
  standard local true false standard-slice-contract \
  --intent typo --files .agent/active/prompts/reviewer_finalization_final_xhigh_output.md

assert_class \
  standard local true false standard-slice-contract \
  --intent typo --files docs/prompts/reviewer_batch.md

assert_class \
  standard local true false standard-slice-contract \
  --intent policy --files .claude/skills/self-growth-proposal-triage/SKILL.md

assert_class \
  standard local true false standard-slice-contract \
  --intent docs --files docs/manual/self-evolution-proposal-queue.md docs/manual/skill-integration.md

assert_class \
  heavy full true true heavy-canonical-final-packet \
  --intent docs --files docs/manual/verification-truth-matrix.md

assert_class \
  heavy full true true heavy-canonical-final-packet \
  --intent policy --files .agent/registry/skill_routing_matrix.json

assert_class \
  heavy full true true heavy-canonical-final-packet \
  --intent implementation --files scripts/cross-family-live-artifact-smoke.sh

assert_class \
  heavy full true true heavy-canonical-final-packet \
  --intent release --files README.md

assert_class \
  heavy full true true heavy-canonical-final-packet \
  --intent typo --files docs/generated/codex-model-policy.md

if "$CLASSIFIER" classify --intent typo --files ../outside.md --json >/tmp/rev_harness_classifier_unexpected.json 2>/dev/null; then
  printf 'expected unsafe path rejection\n' >&2
  exit 1
fi

if "$CLASSIFIER" classify --files src/auth.ts --json >/tmp/rev_harness_classifier_missing_intent.json 2>/dev/null; then
  printf 'expected missing --intent rejection\n' >&2
  exit 1
fi

printf 'PASS: rev_harness_task_classifier\n'
