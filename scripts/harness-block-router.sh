#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ROUTING_CONFIG="$PROJECT_ROOT/.agent/registry/harness_block_routing.json"

usage() {
  cat <<'EOF'
Usage:
  scripts/harness-block-router.sh --list [--json]
  scripts/harness-block-router.sh --type <code-block|process-block|governance-block|terminal-block> [--json]
  scripts/harness-block-router.sh --type <type> --field <field>

Resolve a typed BLOCK reason to its lightweight routing contract.
EOF
}

die() {
  printf 'harness-block-router: %s\n' "$*" >&2
  exit 1
}

mode="text"
block_type=""
field=""
list=false
type_set=false
field_set=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --list)
      list=true
      shift
      ;;
    --type)
      [[ "$#" -ge 2 ]] || die "--type requires a value"
      type_set=true
      block_type="$2"
      shift 2
      ;;
    --field)
      [[ "$#" -ge 2 ]] || die "--field requires a value"
      field_set=true
      field="$2"
      shift 2
      ;;
    --json)
      mode="json"
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [[ "$type_set" == true && -z "$block_type" ]]; then
  die "--type cannot be empty"
fi

if [[ "$field_set" == true && -z "$field" ]]; then
  die "--field cannot be empty"
fi

[[ -r "$ROUTING_CONFIG" ]] || die "missing routing config: $ROUTING_CONFIG"
jq empty "$ROUTING_CONFIG" >/dev/null || die "invalid routing config JSON"

if [[ "$list" == true ]]; then
  [[ "$type_set" == false && "$field_set" == false ]] || die "--list cannot be combined with --type or --field"
  if [[ "$mode" == "json" ]]; then
    jq -c '.block_types | keys' "$ROUTING_CONFIG"
  else
    jq -r '.block_types | keys[]' "$ROUTING_CONFIG"
  fi
  exit 0
fi

[[ "$type_set" == true ]] || die "--type is required unless --list is used"

jq -e --arg type "$block_type" '.block_types[$type] | type == "object"' "$ROUTING_CONFIG" >/dev/null \
  || die "unknown block type: $block_type"

if [[ "$field_set" == true ]]; then
  [[ "$mode" == "text" ]] || die "--field cannot be combined with --json"
  jq -e --arg type "$block_type" --arg field "$field" '.block_types[$type] | has($field)' "$ROUTING_CONFIG" >/dev/null \
    || die "unknown field for block type $block_type: $field"
  jq -r --arg type "$block_type" --arg field "$field" '.block_types[$type][$field]' "$ROUTING_CONFIG"
  exit 0
fi

if [[ "$mode" == "json" ]]; then
  jq -c --arg type "$block_type" '.block_types[$type] + {block_type: $type, next_status: .default_next_status}' "$ROUTING_CONFIG"
  exit 0
fi

jq -r --arg type "$block_type" '
  .block_types[$type] as $route
  | "- block type: \($type)",
    "- next status: \(.default_next_status)",
    "- route owner: \($route.route_owner)",
    "- next action: \($route.next_action)",
    "- review intake allowed: \($route.review_intake_allowed)",
    "- auto retry allowed: \($route.auto_retry_allowed)",
    "- requires user decision: \($route.requires_user_decision)"
' "$ROUTING_CONFIG"
