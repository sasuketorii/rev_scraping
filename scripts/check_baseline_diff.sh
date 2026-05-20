#!/usr/bin/env bash
# scripts/check_baseline_diff.sh
# v1.2.0 P0 baseline-diff guard (minimal). P11 will extend.
set -euo pipefail

BASELINE_DIR="${BASELINE_DIR:-.agent/baseline/v1.1.0}"
if [ ! -d "$BASELINE_DIR" ]; then
  echo "FAIL: baseline dir $BASELINE_DIR missing" >&2
  exit 2
fi

fail=0
check_sha256() {
  local snapshot="$1" current="$2"
  if [ ! -f "$current" ]; then
    # absence is fine if baseline is sentinel-only
    return 0
  fi
  local expected actual
  expected="$(awk '{print $1}' "${snapshot}.sha256" 2>/dev/null || true)"
  if [ -z "$expected" ]; then return 0; fi
  actual="$(shasum -a 256 "$current" | awk '{print $1}')"
  if [ "$expected" != "$actual" ]; then
    echo "DRIFT: $current sha256 differs from baseline" >&2
    fail=1
  fi
}

check_sha256 "$BASELINE_DIR/policy_schema.toml"    "templates/policy.toml"
# authorized_targets.toml: presence-tolerant (sentinel in v1.1.0)
if [ -f "templates/authorized_targets.toml" ]; then
  check_sha256 "$BASELINE_DIR/authorized_schema.toml" "templates/authorized_targets.toml"
fi

# Tool count check (best-effort, only if jq available)
if command -v jq >/dev/null 2>&1 && [ -f "$BASELINE_DIR/tools_list.json" ]; then
  expected_n="$(jq '.tools | length' "$BASELINE_DIR/tools_list.json" 2>/dev/null || echo 0)"
  echo "INFO: baseline tools count = $expected_n"
fi

# Package count
if command -v jq >/dev/null 2>&1 && [ -f "$BASELINE_DIR/cargo_metadata.json" ]; then
  expected_pkgs="$(jq '.packages | length' "$BASELINE_DIR/cargo_metadata.json")"
  echo "INFO: baseline workspace packages = $expected_pkgs"
fi

if [ "$fail" -ne 0 ]; then
  echo "BASELINE DIFF DETECTED - see messages above" >&2
  exit 1
fi
echo "OK: baseline check passed"
