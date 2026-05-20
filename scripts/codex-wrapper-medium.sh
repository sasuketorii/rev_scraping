#!/usr/bin/env bash
#
# codex-wrapper-medium.sh - Compatibility shim for the canonical Codex wrapper
#
# 目的:
#   移行期間の互換性のため残す。runtime truth は scripts/codex-wrapper.sh の
#   role=standard に集約する。
#
set -euo pipefail

readonly SHIM_PREFIX="codex-wrapper-medium"
readonly SHIM_ROLE="standard"
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

CODEX_WRAPPER_LOG_PREFIX="${SHIM_PREFIX}" exec "${CANONICAL_WRAPPER}" --role "${SHIM_ROLE}" "$@"
