#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MATRIX_PATH="${REV_HARNESS_SKILL_ROUTING_MATRIX:-$PROJECT_ROOT/.agent/registry/skill_routing_matrix.json}"
JSON_OUTPUT="NO"

die() {
  printf 'rev-harness-skill-routing-check: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/rev-harness-skill-routing-check.sh [--json]

Validates the RevHarness skill routing matrix, skill path existence, provenance,
and light/standard/heavy skill-loading invariants.
USAGE
}

rank_expr='def rank: if . == "light" then 1 elif . == "standard" then 2 elif . == "heavy" then 3 else 999 end;'

join_sorted_lines() {
  sort | awk 'BEGIN { first = 1 } NF {
    if (!first) {
      printf ","
    }
    printf "%s", $0
    first = 0
  } END {
    printf "\n"
  }'
}

normalize_tool_csv() {
  tr ',' '\n' \
    | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' \
    | join_sorted_lines
}

json_tool_list() {
  jq -r '.[]' | join_sorted_lines
}

skill_frontmatter_allowed_tools() {
  local skill_md="$1"
  awk '
    NR == 1 && $0 == "---" {
      in_frontmatter = 1
      next
    }
    in_frontmatter && $0 == "---" {
      exit
    }
    in_frontmatter && $0 ~ /^allowed-tools:/ {
      sub(/^allowed-tools:[[:space:]]*/, "", $0)
      print
      exit
    }
  ' "$skill_md"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json)
      JSON_OUTPUT="YES"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

command -v jq >/dev/null 2>&1 || die "jq is required"
[[ -f "$MATRIX_PATH" ]] || die "missing matrix: $MATRIX_PATH"

jq -e '
  .schema_version == "rev-harness-skill-routing/v1"
  and .class_order == ["light", "standard", "heavy"]
  and (.classes.light.gate_tier == "quick")
  and (.classes.standard.gate_tier == "local")
  and (.classes.heavy.gate_tier == "full")
  and (.classes.light.default_skill_load == "none")
  and (.classes.standard.default_skill_load == "explicit-only")
  and (.classes.heavy.default_skill_load == "explicit-only")
  and (.skills | type == "array" and length > 0)
  and (.proposal_state_machine.states == ["proposed", "reviewed", "approved", "promoted", "rejected", "quarantined"])
  and (.proposal_state_machine.promotion_gate | index("task_classifier_pass"))
  and (.proposal_state_machine.promotion_gate | index("skill_routing_check_pass"))
  and (.proposal_state_machine.promotion_gate | index("provenance_check_pass"))
  and (.proposal_state_machine.promotion_gate | index("reviewer_lgtm"))
' "$MATRIX_PATH" >/dev/null || die "matrix schema invariant failed"

jq -e "$rank_expr"'
  . as $root |
  ($root.skills | map(.name)) as $skill_names |
  def skill_rank($name):
    ($root.skills[] | select(.name == $name) | .min_task_class | rank) // 999;
  all($root.classes[] .allowed_skills[]; . as $skill | ($skill_names | index($skill)))
  and all(.classes.light.allowed_skills[]; skill_rank(.) <= ("light" | rank))
  and all(.classes.standard.allowed_skills[]; skill_rank(.) <= ("standard" | rank))
  and all(.classes.heavy.allowed_skills[]; skill_rank(.) <= ("heavy" | rank))
  and (.classes.light.allowed_skills | index("self-growth-proposal-triage") | not)
  and (.classes.light.allowed_skills | index("codex-app-server-guard") | not)
  and (.classes.standard.allowed_skills | index("self-growth-proposal-triage"))
' "$MATRIX_PATH" >/dev/null || die "class-to-skill invariant failed"

while IFS= read -r skill_json; do
  name="$(jq -r '.name' <<<"$skill_json")"
  path="$(jq -r '.path' <<<"$skill_json")"
  provenance_path="$(jq -r '.provenance_path // empty' <<<"$skill_json")"
  matrix_allowed_tools="$(jq -c '.allowed_tools // []' <<<"$skill_json" | json_tool_list)"

  [[ "$path" != /* && "$path" != *".."* ]] || die "unsafe skill path for $name: $path"
  skill_md="$PROJECT_ROOT/$path/SKILL.md"
  [[ -f "$skill_md" ]] || die "missing SKILL.md for $name: $path"

  if [[ -n "$provenance_path" ]]; then
    [[ "$provenance_path" != /* && "$provenance_path" != *".."* ]] || die "unsafe provenance path for $name: $provenance_path"
    [[ -f "$PROJECT_ROOT/$provenance_path" ]] || die "missing provenance for $name: $provenance_path"
    jq -e --arg name "$name" '
      .schema_version == "rev-harness-skill-provenance/v1"
      and .skill == $name
      and (.allowed_tools | type == "array")
      and all(.allowed_tools[]; . == "Read" or . == "Bash" or . == "Grep" or . == "Glob")
      and (.network == false)
      and (.mcp_servers | type == "array")
      and (.mutation_policy == "proposal-only" or .mutation_policy == "guard-only" or .mutation_policy == "inspect-only-by-default")
      and (.external_input_policy | test("untrusted evidence"))
      and (.external_input_policy | test("not instructions"))
    ' "$PROJECT_ROOT/$provenance_path" >/dev/null || die "invalid provenance for $name"

    provenance_allowed_tools="$(jq -c '.allowed_tools' "$PROJECT_ROOT/$provenance_path" | json_tool_list)"
    [[ "$matrix_allowed_tools" == "$provenance_allowed_tools" ]] \
      || die "allowed_tools drift between matrix and provenance for $name"

    frontmatter_allowed_tools="$(skill_frontmatter_allowed_tools "$skill_md" | normalize_tool_csv)"
    [[ -n "$frontmatter_allowed_tools" ]] \
      || die "missing allowed-tools frontmatter for provenance-backed skill $name"
    [[ "$matrix_allowed_tools" == "$frontmatter_allowed_tools" ]] \
      || die "allowed-tools frontmatter drift for $name"
  fi
done < <(jq -c '.skills[]' "$MATRIX_PATH")

if [[ "$JSON_OUTPUT" == "YES" ]]; then
  jq -n \
    --arg schema_version "rev-harness-skill-routing-check/v1" \
    --arg status "PASS" \
    --arg matrix ".agent/registry/skill_routing_matrix.json" \
    '$ARGS.named'
else
  printf 'PASS: rev-harness-skill-routing-check\n'
fi
