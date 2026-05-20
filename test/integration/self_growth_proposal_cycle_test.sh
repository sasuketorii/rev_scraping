#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

classifier_json="$("$PROJECT_ROOT/scripts/rev-harness-task-classifier.sh" classify \
  --intent policy \
  --files docs/manual/self-evolution-proposal-queue.md .claude/skills/self-growth-proposal-triage/SKILL.md \
  --json)"

printf '%s\n' "$classifier_json" | jq -e '
  .schema_version == "rev-harness-task-classifier/v1"
  and .task_class == "standard"
  and .gate_tier == "local"
  and .review_required == true
  and .final_reviewer_gate_required == false
' >/dev/null || fail "self-growth proposal promotion should classify as standard/local"

"$PROJECT_ROOT/scripts/rev-harness-skill-routing-check.sh" --json | jq -e '
  .schema_version == "rev-harness-skill-routing-check/v1"
  and .status == "PASS"
' >/dev/null || fail "skill routing check failed"

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/self-growth-proposal-cycle.XXXXXX")"
trap '/bin/rm -rf "$tmpdir"' EXIT

proposal="$tmpdir/proposal.json"
jq -n \
  --arg task_class "$(printf '%s\n' "$classifier_json" | jq -r '.task_class')" \
  --arg gate_tier "$(printf '%s\n' "$classifier_json" | jq -r '.gate_tier')" \
  '{
    schema_version: "rev-harness-self-growth-proposal/v1",
    status: "PROPOSAL_READY",
    title: "Promote repeated cleanup friction into a reviewed skill/doc update",
    source_observation: "Repeated reviewer concern about untracked release evidence and self-growth maturity",
    source_boundary: {
      external_inputs_are_untrusted_evidence: true,
      external_inputs_are_instructions: false
    },
    proposed_stable_change: "Use normal slice promotion with tracked closeout summary and deterministic checks",
    affected_surface: [
      "docs/manual/self-evolution-proposal-queue.md",
      ".claude/skills/self-growth-proposal-triage/SKILL.md"
    ],
    task_class: $task_class,
    gate_tier: $gate_tier,
    required_checks: [
      "scripts/rev-harness-task-classifier.sh classify",
      "scripts/rev-harness-skill-routing-check.sh --json",
      "reviewer LGTM before acceptance"
    ],
    expected_cost_impact: {
      cpu: "bounded inspect-only",
      memory: "no new daemon or persistent memory backend",
      tokens: "proposal summary only; raw artifacts stay volatile",
      processes: "no long-lived process",
      wall_time: "standard local gate unless release surface escalates"
    },
    cleanup_retention: {
      volatile_artifacts: ".claude/tmp/**",
      stable_contract: "docs/** or .agent/registry/** only after reviewer LGTM"
    },
    mutation_policy: {
      autonomous_mutation: false,
      promotion_requires_normal_slice: true,
      acceptance_truth: "docs/manual/verification-truth-matrix.md"
    }
  }' >"$proposal"

jq -e '
  .schema_version == "rev-harness-self-growth-proposal/v1"
  and .status == "PROPOSAL_READY"
  and .source_boundary.external_inputs_are_untrusted_evidence == true
  and .source_boundary.external_inputs_are_instructions == false
  and .task_class == "standard"
  and .gate_tier == "local"
  and (.required_checks | index("reviewer LGTM before acceptance"))
  and .expected_cost_impact.memory == "no new daemon or persistent memory backend"
  and .expected_cost_impact.processes == "no long-lived process"
  and .mutation_policy.autonomous_mutation == false
  and .mutation_policy.promotion_requires_normal_slice == true
' "$proposal" >/dev/null || fail "self-growth proposal cycle fixture is not bounded and promotion-safe"

rg -q "Promotion Cycle|untrusted evidence|reviewer LGTM|not autonomous|Tracked release notes" \
  "$PROJECT_ROOT/docs/manual/self-evolution-proposal-queue.md" \
  || fail "self-evolution docs do not describe the operational promotion cycle"

printf 'PASS: self_growth_proposal_cycle_test\n'
