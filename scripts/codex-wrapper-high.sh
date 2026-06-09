#!/usr/bin/env bash
#
# codex-wrapper-high.sh - Compatibility shim for the canonical Codex wrapper
#
# 目的:
#   移行期間の互換性のため残す historical name。silent medium downgrade
#   を避けるため high cached implementation lane に委譲する。
#
set -euo pipefail

readonly SHIM_PREFIX="codex-wrapper-high"
readonly SHIM_ROLE="high-coder"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CANONICAL_WRAPPER="${SCRIPT_DIR}/codex-wrapper.sh"

fail() {
  echo "[${SHIM_PREFIX}] ERROR: $*" >&2
  exit 1
}

if [[ ! -f "${CANONICAL_WRAPPER}" ]]; then
  fail "Canonical wrapper not found: ${CANONICAL_WRAPPER}"
fi

if [[ ! -x "${CANONICAL_WRAPPER}" ]]; then
  fail "Canonical wrapper is not executable: ${CANONICAL_WRAPPER}"
fi

# Wave HSDI Phase C / T-C-2 — export shim role hint for parse_wrapper_args merge-on-equal
export CODEX_WRAPPER_SHIM_ROLE="${SHIM_ROLE}"
CODEX_WRAPPER_LOG_PREFIX="${SHIM_PREFIX}" exec "${CANONICAL_WRAPPER}" --role "${SHIM_ROLE}" "$@"
