#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DRY_RUN=false
JSON_OUTPUT=false
VERBOSE=false
STRICT=false
SETUP_ONLY=false
TARGET_ARG=""

usage() {
  cat <<'EOF'
Usage:
  scripts/rev-harness-install.sh [--dry-run] [--json] [--verbose] [--strict] [--setup-only] [--target <path>]

Thin composer for rev-harness-adopter-setup.sh setup.
--setup-only is accepted for the façade alias; Phase G still delegates to setup.
Init-only flows remain available through rev-harness-adopter-setup.sh directly.

Exit codes:
  Propagates rev-harness-adopter-setup.sh unchanged.
EOF
}

die() {
  printf 'rev-harness-install: %s\n' "$*" >&2
  exit 2
}

args=()
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --json) JSON_OUTPUT=true; shift ;;
    --verbose) VERBOSE=true; shift ;;
    --strict) STRICT=true; shift ;;
    --setup-only) SETUP_ONLY=true; shift ;;
    --target) [[ "$#" -ge 2 ]] || die "--target requires a path"; TARGET_ARG="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -f "$SCRIPT_DIR/rev-harness-adopter-setup.sh" ]] || die "missing composer target"

args+=(setup)
[[ -n "$TARGET_ARG" ]] && args+=(--target "$TARGET_ARG")
[[ "$DRY_RUN" == true ]] && args+=(--dry-run)
[[ "$JSON_OUTPUT" == true ]] && args+=(--json)
[[ "$VERBOSE" == true ]] && args+=(--verbose)
[[ "$STRICT" == true ]] && args+=(--strict)
[[ "$SETUP_ONLY" == true ]] && :

exec bash "$SCRIPT_DIR/rev-harness-adopter-setup.sh" "${args[@]}"
