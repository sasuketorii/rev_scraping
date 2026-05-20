#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CHECKER="$PROJECT_ROOT/scripts/rev-harness-skill-routing-check.sh"
MATRIX="$PROJECT_ROOT/.agent/registry/skill_routing_matrix.json"

"$CHECKER" --json | jq -e '
  .schema_version == "rev-harness-skill-routing-check/v1"
  and .status == "PASS"
' >/dev/null

jq -e '
  (.classes.light.default_skill_load == "none")
  and (.classes.light.allowed_skills | index("self-growth-proposal-triage") | not)
  and (.classes.light.allowed_skills | index("codex-app-server-guard") | not)
  and (.classes.light.allowed_skills | index("cloudflare-deploy-guard") | not)
  and (.classes.light.allowed_skills | index("supabase-deploy-guard") | not)
  and (.classes.light.allowed_skills | index("payload-cms-deploy-guard") | not)
  and (.classes.standard.allowed_skills | index("self-growth-proposal-triage"))
  and (.skills[] | select(.name == "self-growth-proposal-triage")
      | .min_task_class == "standard"
        and .network == false
        and (.mcp_servers | length == 0)
        and .mutation_policy == "proposal-only"
        and .provenance_path == ".claude/skills/self-growth-proposal-triage/provenance.json")
' "$MATRIX" >/dev/null

test -f "$PROJECT_ROOT/.claude/skills/self-growth-proposal-triage/SKILL.md"
test -f "$PROJECT_ROOT/.claude/skills/self-growth-proposal-triage/provenance.json"

if [[ "${REV_HARNESS_VALIDATE_EXTERNAL_SKILL_PROJECTIONS:-0}" == "1" ]]; then
  external_skill_root="${REV_DEVSKILLS_ROOT:-$PROJECT_ROOT/../rev_devskills}"
  test -f "$external_skill_root/self-growth-proposal-triage/SKILL.md"
  test -f "$external_skill_root/self-growth-proposal-triage/provenance.json"
  test -f "${CODEX_HOME:-$HOME/.codex}/skills/self-growth-proposal-triage/SKILL.md"
fi

fixture="$(mktemp)"
fixture_err="$(mktemp)"
trap '/bin/rm -f "$fixture" "$fixture_err"' EXIT
jq '.classes.light.allowed_skills += ["unregistered-heavy-workflow"]' "$MATRIX" >"$fixture"
if REV_HARNESS_SKILL_ROUTING_MATRIX="$fixture" "$CHECKER" > /dev/null 2>"$fixture_err"; then
  printf 'expected unknown allowed skill to fail\n' >&2
  exit 1
fi
rg -q "class-to-skill invariant failed" "$fixture_err"

rg -q "light.*standard.*heavy|self-growth|skill_routing_matrix.json|no autonomous mutation|untrusted evidence" \
  "$PROJECT_ROOT/docs/manual/skill-routing-matrix.md"

printf 'PASS: rev_harness_skill_routing_test\n'
