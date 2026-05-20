#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CALLER_PWD="$(pwd)"

usage() {
  cat <<'EOF'
Usage: scripts/harness-governance-classifier.sh [--json] [--] <path>...

Classify a proposed Revharness change as light, standard, or heavy.
The classifier is conservative and advisory. It never grants acceptance,
LGTM, release, tag, merge, or completion authority.
EOF
}

die() {
  printf 'harness-governance-classifier: %s\n' "$*" >&2
  exit 1
}

json=0
declare -a PATHS=()
declare -a REASONS=()
classifier="light"

add_reason() {
  local reason="$1"
  local existing=""

  for existing in "${REASONS[@]}"; do
    [[ "$existing" != "$reason" ]] || return 0
  done
  REASONS+=("$reason")
}

escalate() {
  local target="$1"
  local reason="$2"

  case "$target" in
    heavy)
      classifier="heavy"
      ;;
    standard)
      [[ "$classifier" == "heavy" ]] || classifier="standard"
      ;;
    light)
      ;;
    *)
      die "internal invalid classifier: $target"
      ;;
  esac
  add_reason "$reason"
}

normalize_path() {
  local value="$1"
  local root="${PROJECT_ROOT%/}"

  collapse_slashes() {
    local collapsed="$1"
    while [[ "$collapsed" == *//* ]]; do
      collapsed="${collapsed//\/\//\/}"
    done
    printf '%s\n' "$collapsed"
  }

  lexical_clean() {
    local input="$1"
    local absolute=0
    local segment=""
    local joined=""
    local old_ifs="$IFS"
    local -a segments=()
    local -a stack=()

    [[ "$input" == /* ]] && absolute=1
    IFS='/'
    read -r -a segments <<< "$input"
    IFS="$old_ifs"

    for segment in "${segments[@]}"; do
      case "$segment" in
        ""|.)
          ;;
        ..)
          if [[ "${#stack[@]}" -gt 0 ]]; then
            unset "stack[$((${#stack[@]} - 1))]"
          elif [[ "$absolute" -eq 0 ]]; then
            stack+=("..")
          fi
          ;;
        *)
          stack+=("$segment")
          ;;
      esac
    done

    old_ifs="$IFS"
    IFS='/'
    joined="${stack[*]}"
    IFS="$old_ifs"

    if [[ "$absolute" -eq 1 ]]; then
      if [[ -n "$joined" ]]; then
        printf '/%s\n' "$joined"
      else
        printf '/\n'
      fi
    else
      printf '%s\n' "$joined"
    fi
  }

  root="$(collapse_slashes "$root")"
  root="$(lexical_clean "$root")"
  value="$(collapse_slashes "$value")"

  case "$value" in
    /*)
      ;;
    *)
      value="$CALLER_PWD/$value"
      ;;
  esac

  value="$(collapse_slashes "$value")"
  value="$(lexical_clean "$value")"

  case "$value" in
    "$root"/*)
      value="${value#"$root"/}"
      ;;
    "$root")
      value="."
      ;;
  esac

  value="$(lexical_clean "$value")"

  printf '%s\n' "$value"
}

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --json)
      json=1
      shift
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    --)
      shift
      while [[ "$#" -gt 0 ]]; do
        PATHS+=("$1")
        shift
      done
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      PATHS+=("$1")
      shift
      ;;
  esac
done

[[ "${#PATHS[@]}" -gt 0 ]] || die "at least one path is required"

for raw_path in "${PATHS[@]}"; do
  path="$(normalize_path "$raw_path")"
  reason_path="$path"
  if [[ "$raw_path" != "$path" ]]; then
    reason_path="$raw_path -> $path"
  fi

  case "$path" in
    AGENTS.md|CLAUDE.md|.agent_rules/RULES.md|docs/roles/*|docs/manual/verification-truth-matrix.md|docs/manual/common-task-contract.md)
      escalate heavy "normative role, acceptance, or task-contract surface: $reason_path"
      ;;
    .codex/config.toml|.codex/agents/*|.claude/settings.json|.claude/settings.local.json|.claude/skills/*|.claude/hooks/*)
      escalate heavy "Codex or Claude Code runtime/skill/hook surface: $reason_path"
      ;;
    .agent/registry/model_policy.json|scripts/model-policy.sh|scripts/*wrapper*.sh)
      escalate heavy "model policy or wrapper runtime truth: $reason_path"
      ;;
    scripts/*lease*|scripts/*auth*|scripts/*subscription*|scripts/rev-harness-*.sh|agent-core/*|agent-core/**)
      escalate heavy "security, lease, auth, or Rust authority surface: $reason_path"
      ;;
    scripts/launch-semantic-mcp.sh|scripts/*semantic*|.agent/registry/*semantic*|.agent/context/*|.agent/context/**)
      escalate heavy "semantic MCP, index, or registry authority: $reason_path"
      ;;
    test/integration/harness_release_gate.sh|scripts/harness-release-gate.sh|scripts/harness-runtime-baseline.sh)
      escalate heavy "release gate or runtime baseline authority: $reason_path"
      ;;
    .agent/active/sow/task-lineage-ledger.md)
      escalate heavy "authoritative task lineage ledger: $reason_path"
      ;;
    .agent/active/plan_*|.agent/active/sow/*.md)
      escalate standard "active plan or SOW with slice contract/provenance surface: $reason_path"
      ;;
    .agent/registry/*|scripts/*.sh|test/integration/*.sh|docs/manual/*)
      escalate standard "reviewable harness behavior or integration surface: $reason_path"
      ;;
    /*)
      escalate standard "path outside repo root defaults to standard: $reason_path"
      ;;
    .agent/active/*|.agent/active/**|docs/*|*.md)
      escalate light "docs, prompt, active artifact, or admin surface: $reason_path"
      ;;
    *)
      escalate standard "unclassified path defaults to standard: $reason_path"
      ;;
  esac
done

case "$classifier" in
  light)
    mode="dev"
    gate_tier="quick"
    reviewer_default="optional"
    ;;
  standard)
    mode="review"
    gate_tier="local"
    reviewer_default="scoped"
    ;;
  heavy)
    mode="release"
    gate_tier="full"
    reviewer_default="required"
    ;;
esac

if [[ "$json" -eq 1 ]]; then
  jq -n \
    --arg classifier "$classifier" \
    --arg operating_mode "$mode" \
    --arg gate_tier "$gate_tier" \
    --arg reviewer_default "$reviewer_default" \
    '{
      classifier: $classifier,
      operating_mode: $operating_mode,
      gate_tier: $gate_tier,
      reviewer_default: $reviewer_default,
      advisory_only: true,
      reasons: $ARGS.positional
    }' \
    --args "${REASONS[@]}"
else
  printf 'classifier=%s\n' "$classifier"
  printf 'operating_mode=%s\n' "$mode"
  printf 'gate_tier=%s\n' "$gate_tier"
  printf 'reviewer_default=%s\n' "$reviewer_default"
  printf 'advisory_only=true\n'
  printf 'reasons:\n'
  printf -- '- %s\n' "${REASONS[@]}"
fi
