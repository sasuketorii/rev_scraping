#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

MODE="classify"
INTENT=""
INTENT_PROVIDED="NO"
JSON_OUTPUT="NO"
FILES=()
REASONS=()
TASK_CLASS="standard"

die() {
  printf 'rev-harness-task-classifier: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'USAGE'
Usage: scripts/rev-harness-task-classifier.sh classify --intent <intent> --files <path>... [--json]

Intents:
  typo | reference-cleanup | admin | prompt-wording | docs
  implementation | test | policy | security | release | live-orchestration

Output classes:
  light    quick checks, no reviewer/final gate
  standard local checks, scoped reviewer signoff, no final release gate
  heavy    full checks, full canonical schema, final reviewer gate
USAGE
}

append_reason() {
  REASONS+=("$1")
}

rank_of() {
  case "$1" in
    light) printf '1\n' ;;
    standard) printf '2\n' ;;
    heavy) printf '3\n' ;;
    *) die "unknown class rank: $1" ;;
  esac
}

raise_to() {
  local candidate="$1"
  if [[ "$(rank_of "$candidate")" -gt "$(rank_of "$TASK_CLASS")" ]]; then
    TASK_CLASS="$candidate"
  fi
}

normalize_path() {
  local path="$1"
  case "$path" in
    "$PROJECT_ROOT"/*) path="${path#"$PROJECT_ROOT"/}" ;;
    ./*) path="${path#./}" ;;
  esac
  case "$path" in
    ""|.|..|../*|*/../*) die "unsafe or non-repo path: $1" ;;
    /*) die "path is outside project root: $1" ;;
  esac
  printf '%s\n' "$path"
}

is_light_intent() {
  case "$1" in
    typo|reference-cleanup|admin|prompt-wording) return 0 ;;
    *) return 1 ;;
  esac
}

is_light_safe_path() {
  case "$1" in
    README.md|docs/README.md|docs/official-docs-links.md|\
docs/manual/harness-user-guide.md|docs/manual/end-user-guide.md|docs/manual/developer-customization-guide.md|\
docs/requirements/README.md)
      return 0
      ;;
    *) return 1 ;;
  esac
}

classify_intent() {
  case "$INTENT" in
    typo|reference-cleanup|admin|prompt-wording)
      TASK_CLASS="light"
      append_reason "light intent: $INTENT"
      ;;
    docs|implementation|test|policy)
      TASK_CLASS="standard"
      append_reason "standard intent: $INTENT"
      ;;
    security|release|live-orchestration)
      TASK_CLASS="heavy"
      append_reason "heavy intent: $INTENT"
      ;;
    *)
      die "invalid --intent: $INTENT"
      ;;
  esac
}

classify_path() {
  local path="$1"

  # Role docs define orchestration authority for a canonical role and must
  # receive full reviewer gating when changed.
  # Anchored regex for specialty surface promotion.
  # Pattern: ^docs/roles/[^/]+/specialties/[^/]+\.md$
  # Rationale: case * globs in bash also match /, which lets paths like
  #   docs/roles/specialties/foo.md spoof a canonical-role-keyed specialty.
  #   The anchored regex requires EXACTLY: docs/roles/<canonical>/specialties/<slug>.md
  #   where <canonical> is a single path segment (no /).
  # Heavy promotion rationale: specialty files declare role authority narrowing;
  #   any change to a specialty file affects orchestration semantics; therefore
  #   any plan touching this surface is classified `heavy` (not `standard`),
  #   forcing the full reviewer gate set.
  if [[ "$path" =~ ^docs/roles/[^/]+\.md$ ]] || \
     [[ "$path" =~ ^docs/roles/[^/]+/specialties/[^/]+\.md$ ]]; then
    raise_to "heavy"
    append_reason "heavy surface: $path"
    return 0
  fi

  # Heavy harness-control surfaces: wrappers/session guards, release gates,
  # acceptance truth, model policy mirrors, semantic MCP, and Rust control-plane
  # code can alter trust boundaries or completion evidence.
  # Matrix and gate docs are promoted because they define acceptance semantics;
  # harness-rust/** is promoted because it owns runtime validation/control code.
  case "$path" in
    .github/workflows/*.yml|.github/workflows/*.yaml|\
scripts/*wrapper*.sh|scripts/codex-wrapper*.sh|scripts/claude-wrapper*.sh|\
scripts/cross-family-live-*.sh|scripts/subscription-auth-guard.sh|scripts/rev-harness-lease-guard.sh|\
test/integration/harness_release_gate.sh|test/integration/cross_family_live_*.sh|\
docs/manual/verification-truth-matrix.md|docs/manual/harness-release-gate.md|\
docs/generated/codex-model-policy.md|\
AGENTS.md|CLAUDE.md|.agent_rules/RULES.md|.codex/*|.codex/**/*|\
.claude/settings.json|.claude/commands/*|.claude/commands/**/*|\
.agent/registry/*|.agent/registry/**/*|.agent/generated/*|.agent/generated/**/*|\
scripts/semantic-mcp-server/*|scripts/semantic-mcp-server/**/*|harness-rust/*|harness-rust/**/*)
      raise_to "heavy"
      append_reason "heavy surface: $path"
      return 0
      ;;
  esac

  if [[ "$TASK_CLASS" == "light" ]] && is_light_safe_path "$path"; then
    append_reason "light-safe surface: $path"
    return 0
  fi

  # Standard surfaces affect implementation, tests, local plans, prompts, or
  # manual content but do not by themselves change the top-level acceptance
  # contract or runtime trust boundary handled by the heavy block above.
  case "$path" in
    scripts/*|scripts/**/*|test/*|test/**/*|src/*|src/**/*|app/*|app/**/*|\
workspace/*|workspace/**/*|\
.claude/skills/*|.claude/skills/**/*|.agent/active/plan_*|.agent/active/sow/*|.agent/active/sow/**/*|\
.agent/active/prompts/*|.agent/active/prompts/**/*|\
docs/manual/*|docs/manual/**/*)
      raise_to "standard"
      if [[ "$path" == workspace/* ]]; then
        append_reason "disposable workspace surface: $path"
      else
        append_reason "standard surface: $path"
      fi
      return 0
      ;;
  esac

  if [[ "$TASK_CLASS" == "light" ]] && ! is_light_safe_path "$path"; then
    raise_to "standard"
    append_reason "not light-safe path: $path"
  fi
}

schema_profile() {
  case "$TASK_CLASS" in
    light) printf 'light-change-record\n' ;;
    standard) printf 'standard-slice-contract\n' ;;
    heavy) printf 'heavy-canonical-final-packet\n' ;;
  esac
}

gate_tier() {
  case "$TASK_CLASS" in
    light) printf 'quick\n' ;;
    standard) printf 'local\n' ;;
    heavy) printf 'full\n' ;;
  esac
}

bool_review_required() {
  case "$TASK_CLASS" in
    light) printf 'false\n' ;;
    standard|heavy) printf 'true\n' ;;
  esac
}

bool_final_gate_required() {
  case "$TASK_CLASS" in
    heavy) printf 'true\n' ;;
    light|standard) printf 'false\n' ;;
  esac
}

emit_json() {
  local reasons_json=""
  reasons_json="$(printf '%s\n' "${REASONS[@]}" | jq -R . | jq -s .)"
  jq -n \
    --arg schema_version "rev-harness-task-classifier/v1" \
    --arg task_class "$TASK_CLASS" \
    --arg gate_tier "$(gate_tier)" \
    --arg schema_profile "$(schema_profile)" \
    --argjson review_required "$(bool_review_required)" \
    --argjson final_reviewer_gate_required "$(bool_final_gate_required)" \
    --argjson reasons "$reasons_json" \
    '$ARGS.named'
}

emit_text() {
  printf 'task_class=%s\n' "$TASK_CLASS"
  printf 'gate_tier=%s\n' "$(gate_tier)"
  printf 'schema_profile=%s\n' "$(schema_profile)"
  printf 'review_required=%s\n' "$(bool_review_required)"
  printf 'final_reviewer_gate_required=%s\n' "$(bool_final_gate_required)"
  printf 'reasons:\n'
  printf -- '- %s\n' "${REASONS[@]}"
}

parse_args() {
  [[ "$#" -gt 0 ]] || { usage; exit 0; }
  MODE="$1"
  shift
  [[ "$MODE" == "classify" ]] || die "unknown mode: $MODE"

  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      --intent)
        [[ "$#" -ge 2 ]] || die "--intent requires a value"
        INTENT="$2"
        INTENT_PROVIDED="YES"
        shift 2
        ;;
      --intent=*)
        INTENT="${1#--intent=}"
        INTENT_PROVIDED="YES"
        shift
        ;;
      --files)
        shift
        while [[ "$#" -gt 0 && "$1" != --* ]]; do
          FILES+=("$(normalize_path "$1")")
          shift
        done
        ;;
      --json)
        JSON_OUTPUT="YES"
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        FILES+=("$(normalize_path "$1")")
        shift
        ;;
    esac
  done

  [[ "$INTENT_PROVIDED" == "YES" && -n "$INTENT" ]] || die "--intent is required"
  [[ "${#FILES[@]}" -gt 0 ]] || die "at least one --files path is required"
}

parse_args "$@"
command -v jq >/dev/null 2>&1 || die "jq is required"

classify_intent
for file in "${FILES[@]}"; do
  classify_path "$file"
done

if [[ "$TASK_CLASS" == "light" ]] && ! is_light_intent "$INTENT"; then
  raise_to "standard"
  append_reason "light requires typo/reference-cleanup/admin/prompt-wording intent"
fi

if [[ "$JSON_OUTPUT" == "YES" ]]; then
  emit_json
else
  emit_text
fi
