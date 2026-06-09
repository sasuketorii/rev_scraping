#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
  REPO_ROOT="$ROOT"
else
  REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi

REFERENCE_FILE="$REPO_ROOT/test/golden/semantic-mcp/tier1-reference.sha256"
GOLDEN_FILE="$REPO_ROOT/test/golden/semantic-mcp/tier1-capsule-sample.txt"
GOLDEN_SHA_FILE="$REPO_ROOT/test/golden/semantic-mcp/tier1-capsule-sample.sha256"
CAPSULE_FILE="$REPO_ROOT/harness-rust/crates/semantic-mcp/src/capsule.rs"
DB_FILE="$REPO_ROOT/harness-rust/crates/semantic-mcp/src/db.rs"
METRICS_FILE="$REPO_ROOT/.agent/metrics/tier1_scope_guard.jsonl"

QUIESCE="${REVHARNESS_PARALLEL_QUIESCE:-}"
if [[ "$QUIESCE" != "1" ]]; then
  echo "tier1-scope-guard: REVHARNESS_PARALLEL_QUIESCE=1 is required" >&2
  exit 1
fi

if command -v shasum >/dev/null 2>&1; then
  sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
  }
elif command -v sha256sum >/dev/null 2>&1; then
  sha256_file() {
    sha256sum "$1" | awk '{print $1}'
  }
else
  echo "tier1-scope-guard: missing shasum or sha256sum" >&2
  exit 1
fi

fail() {
  echo "tier1-scope-guard: $*" >&2
  echo "Tier 1 paths must not change; if intentional, update reference SHA explicitly" >&2
  exit 1
}

iso_utc() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

emit_scope_metric() {
  local result="$1" path="${2:-}" expected="${3:-}" got="${4:-}" paths="[]"
  mkdir -p "$(dirname "$METRICS_FILE")"
  [[ -n "$path" ]] && paths="[\"$path\"]"
  printf '{"ts":"%s","event":"tier1_scope_guard","result":"%s","drifted_path":%s,"expected_sha":"%s","got_sha":"%s"}\n' \
    "$(iso_utc)" "$result" "$paths" "$expected" "$got" >> "$METRICS_FILE"
}

require_file() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    fail "required file missing: ${path#$REPO_ROOT/}"
  fi
}

reference_sha_for() {
  local label="$1"
  local matches
  matches="$(awk -v label="$label" '$2 == label { print $1 }' "$REFERENCE_FILE")"
  if [[ -z "$matches" ]]; then
    fail "reference SHA missing for $label in ${REFERENCE_FILE#$REPO_ROOT/}"
  fi
  if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != "1" ]]; then
    fail "reference SHA is ambiguous for $label in ${REFERENCE_FILE#$REPO_ROOT/}"
  fi
  printf '%s' "$matches"
}

expected_golden_sha() {
  local matches
  matches="$(awk '$2 == "tier1-capsule-sample.txt" { print $1 }' "$GOLDEN_SHA_FILE")"
  if [[ -z "$matches" ]]; then
    matches="$(awk 'NF == 1 { print $1 }' "$GOLDEN_SHA_FILE")"
  fi
  if [[ -z "$matches" ]]; then
    fail "golden SHA missing in ${GOLDEN_SHA_FILE#$REPO_ROOT/}"
  fi
  if [[ "$(printf '%s\n' "$matches" | wc -l | tr -d ' ')" != "1" ]]; then
    fail "golden SHA is ambiguous in ${GOLDEN_SHA_FILE#$REPO_ROOT/}"
  fi
  printf '%s' "$matches"
}

check_hex_sha() {
  local sha="$1"
  local source="$2"
  if ! [[ "$sha" =~ ^[0-9a-f]{64}$ ]]; then
    fail "invalid SHA-256 in $source: $sha"
  fi
}

check_reference_target() {
  local label="$1"
  local path="$2"
  local expected actual
  expected="$(reference_sha_for "$label")"
  check_hex_sha "$expected" "$label reference"
  actual="$(sha256_file "$path")"
  if [[ "$actual" != "$expected" ]]; then
    emit_scope_metric "drift" "${path#$REPO_ROOT/}" "$expected" "$actual"
    fail "$label drifted: expected $expected actual $actual"
  fi
}

check_golden() {
  local expected actual
  expected="$(expected_golden_sha)"
  check_hex_sha "$expected" "tier1-capsule-sample.sha256"
  actual="$(sha256_file "$GOLDEN_FILE")"
  if [[ "$actual" != "$expected" ]]; then
    emit_scope_metric "drift" "${GOLDEN_FILE#$REPO_ROOT/}" "$expected" "$actual"
    fail "tier1-capsule-sample.txt drifted: expected $expected actual $actual"
  fi
}

main() {
  require_file "$REFERENCE_FILE"
  require_file "$GOLDEN_FILE"
  require_file "$GOLDEN_SHA_FILE"
  require_file "$CAPSULE_FILE"
  require_file "$DB_FILE"

  check_reference_target "capsule.rs" "$CAPSULE_FILE"
  check_reference_target "db.rs" "$DB_FILE"
  check_golden
  emit_scope_metric "ok"
}

main "$@"
