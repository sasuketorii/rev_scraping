#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir" || true' EXIT

vocabulary="$tmp_dir/matrix-vocabulary.json"
matrix="$tmp_dir/verification-truth-matrix.md"

cp "$repo_root/docs/manual/matrix-vocabulary.json" "$vocabulary"

cat >"$matrix" <<'MARKDOWN'
# Verification / Truth Matrix

vocabulary-rev: 0000000000000000000000000000000000000000000000000000000000000000
MARKDOWN

if MATRIX_VOCABULARY_PATH="$vocabulary" MATRIX_PROSE_PATH="$matrix" "$repo_root/scripts/check-matrix-vocabulary-sync.sh" >/dev/null 2>&1; then
  echo "expected mismatched marker to fail" >&2
  exit 1
fi

if command -v sha256sum >/dev/null 2>&1; then
  hash="$(jq -S -c . "$vocabulary" | sha256sum | awk '{print $1}')"
else
  hash="$(jq -S -c . "$vocabulary" | shasum -a 256 | awk '{print $1}')"
fi

cat >"$matrix" <<MARKDOWN
# Verification / Truth Matrix

vocabulary-rev: $hash
MARKDOWN

MATRIX_VOCABULARY_PATH="$vocabulary" MATRIX_PROSE_PATH="$matrix" "$repo_root/scripts/check-matrix-vocabulary-sync.sh" >/dev/null
echo PASS
exit 0
