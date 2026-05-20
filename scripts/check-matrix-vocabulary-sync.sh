#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
vocabulary_path="${MATRIX_VOCABULARY_PATH:-$repo_root/docs/manual/matrix-vocabulary.json}"
matrix_path="${MATRIX_PROSE_PATH:-$repo_root/docs/manual/verification-truth-matrix.md}"

if command -v sha256sum >/dev/null 2>&1; then
  actual_hash="$(jq -S -c . "$vocabulary_path" | sha256sum | awk '{print $1}')"
else
  actual_hash="$(jq -S -c . "$vocabulary_path" | shasum -a 256 | awk '{print $1}')"
fi

marker_count="$(grep -Ec '^vocabulary-rev: [0-9a-f]{64}$' "$matrix_path" || true)"
if [ "$marker_count" -ne 1 ]; then
  echo "FAIL matrix vocabulary marker count: expected 1, got $marker_count" >&2
  exit 1
fi

expected_hash="$(grep -E '^vocabulary-rev: [0-9a-f]{64}$' "$matrix_path" | awk '{print $2}')"

if [ "$actual_hash" = "$expected_hash" ]; then
  echo "PASS matrix vocabulary hash matches: $actual_hash"
  exit 0
fi

echo "FAIL matrix vocabulary hash mismatch" >&2
echo "  expected marker: $expected_hash" >&2
echo "  actual json:      $actual_hash" >&2
exit 1
