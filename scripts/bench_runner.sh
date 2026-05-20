#!/usr/bin/env bash
# Phase 5 benchmark runner with relative ratio assertions.
#
# Usage:
#   scripts/bench_runner.sh
#
# Writes Criterion logs and aggregate JSON under .claude/tmp/frontier-push.
# Assertions:
#   V18: p95(fts5) <= p95(legacy-like) / 10
#   V19: p95(now) <= p95(baseline) / 2
#   V20: cold p95 < 5s, warm p95 < 1s

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ART_DIR="$ROOT_DIR/.claude/tmp/frontier-push"
mkdir -p "$ART_DIR"

require_jq() {
  if ! command -v jq >/dev/null 2>&1; then
    echo "[bench] jq is required for Phase 5 benchmark assertions" >&2
    exit 2
  fi
}

assert_le() {
  local lhs="$1"
  local rhs="$2"
  local label="$3"
  jq -en --argjson lhs "$lhs" --argjson rhs "$rhs" '$lhs <= $rhs' >/dev/null || {
    echo "[bench] assertion failed: $label ($lhs > $rhs)" >&2
    exit 1
  }
}

assert_lt() {
  local lhs="$1"
  local rhs="$2"
  local label="$3"
  jq -en --argjson lhs "$lhs" --argjson rhs "$rhs" '$lhs < $rhs' >/dev/null || {
    echo "[bench] assertion failed: $label ($lhs >= $rhs)" >&2
    exit 1
  }
}

require_jq

cd "$ROOT_DIR/harness-rust"

echo "[bench] search_fts5..."
REVHARNESS_BENCH_ART_DIR="$ART_DIR" cargo bench --bench search_fts5 -- --save-baseline phase5_search | tee "$ART_DIR/bench_search.txt"
SEARCH_JSON="$ART_DIR/bench_search.json"
FTS5_P95="$(jq -r '.fts5.p95_ns' "$SEARCH_JSON")"
LEGACY_P95="$(jq -r '.legacy_like.p95_ns' "$SEARCH_JSON")"
assert_le "$FTS5_P95" "$(jq -n --argjson v "$LEGACY_P95" '$v / 10')" "V18 p95(fts5) <= p95(legacy-like) / 10"
echo "[bench] V18 ok: fts5_p95_ns=$FTS5_P95 legacy_like_p95_ns=$LEGACY_P95"

echo "[bench] context_top_k..."
REVHARNESS_BENCH_ART_DIR="$ART_DIR" cargo bench --bench context_top_k -- --save-baseline phase5_topk | tee "$ART_DIR/bench_topk.txt"
TOPK_JSON="$ART_DIR/bench_topk.json"
TOPK_P95="$(jq -r '.now.p95_ns' "$TOPK_JSON")"
TOPK_BASELINE_P95="$(jq -r '.baseline.p95_ns' "$TOPK_JSON")"
assert_le "$TOPK_P95" "$(jq -n --argjson v "$TOPK_BASELINE_P95" '$v / 2')" "V19 p95(now) <= p95(baseline) / 2"
echo "[bench] V19 ok: now_p95_ns=$TOPK_P95 baseline_p95_ns=$TOPK_BASELINE_P95"

echo "[bench] index_files..."
REVHARNESS_BENCH_ART_DIR="$ART_DIR" cargo bench --bench index_files -- --save-baseline phase5_index | tee "$ART_DIR/bench_index.txt"
INDEX_JSON="$ART_DIR/bench_index.json"
COLD_P95="$(jq -r '.cold.p95_ns' "$INDEX_JSON")"
WARM_P95="$(jq -r '.warm.p95_ns' "$INDEX_JSON")"
assert_lt "$COLD_P95" 5000000000 "V20 cold p95 < 5s"
assert_lt "$WARM_P95" 1000000000 "V20 warm p95 < 1s"
echo "[bench] V20 ok: cold_p95_ns=$COLD_P95 warm_p95_ns=$WARM_P95"

jq -n \
  --slurpfile search "$SEARCH_JSON" \
  --slurpfile topk "$TOPK_JSON" \
  --slurpfile index "$INDEX_JSON" \
  '{search: $search[0], top_k: $topk[0], index: $index[0]}' \
  > "$ART_DIR/bench_aggregate.json"

echo "[bench] done. aggregate: $ART_DIR/bench_aggregate.json"
