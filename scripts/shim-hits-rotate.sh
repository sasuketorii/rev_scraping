#!/usr/bin/env bash
# scripts/shim-hits-rotate.sh
#
# ~/.rev_harness/shim-hits.log のログローテーション。
# サイズが --max-size を超えたら .1 -> .2 ... -> .N までシフトし、
# .N を超えた古いファイルは削除する。
#
# 使い方:
#   shim-hits-rotate.sh [--max-size <bytes>] [--keep <N>] [--log <path>]
#
# 環境変数:
#   REV_HARNESS_SHIM_HITS_LOG   ローテーション対象 (default: ~/.rev_harness/shim-hits.log)
#   REV_HARNESS_CANONICAL_ROOT  canonical-guard 用 (vendoring 防御)
#
# 互換: bash 3.x (macOS), Linux/macOS の stat 差異を吸収。
#
# cron 例 (毎週日曜 03:00):
#   0 3 * * 0 /Users/<you>/dev/rev_harness/scripts/shim-hits-rotate.sh >/dev/null 2>&1

set -euo pipefail

# vendoring 防御: canonical root 配下からの実行のみ許可
_self_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=scripts/_canonical-guard.sh
source "$_self_dir/_canonical-guard.sh"
rev_harness_assert_canonical_root "shim-hits-rotate.sh"

MAX_SIZE=$((10 * 1024 * 1024))  # 10MB default
KEEP=5
LOG_FILE="${REV_HARNESS_SHIM_HITS_LOG:-$HOME/.rev_harness/shim-hits.log}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-size)
      MAX_SIZE="$2"; shift 2 ;;
    --keep)
      KEEP="$2"; shift 2 ;;
    --log)
      LOG_FILE="$2"; shift 2 ;;
    -h|--help)
      sed -n '2,20p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "[shim-hits-rotate] unknown arg: $1" >&2
      exit 64 ;;
  esac
done

# ログが存在しなければ no-op
if [[ ! -f "$LOG_FILE" ]]; then
  exit 0
fi

# サイズ取得 (macOS: stat -f%z, Linux: stat -c%s)
file_size() {
  local f="$1"
  if stat -f%z "$f" >/dev/null 2>&1; then
    stat -f%z "$f"
  else
    stat -c%s "$f"
  fi
}

current_size=$(file_size "$LOG_FILE")
if [[ "$current_size" -le "$MAX_SIZE" ]]; then
  exit 0
fi

# 古いものから削除し、シフトしていく
# .N -> 削除、 .N-1 -> .N、 ... 、 .1 -> .2、 log -> .1
i="$KEEP"
if [[ -f "${LOG_FILE}.${i}" ]]; then
  rm -f "${LOG_FILE}.${i}"
fi

while [[ "$i" -gt 1 ]]; do
  prev=$((i - 1))
  if [[ -f "${LOG_FILE}.${prev}" ]]; then
    mv "${LOG_FILE}.${prev}" "${LOG_FILE}.${i}"
  fi
  i="$prev"
done

mv "$LOG_FILE" "${LOG_FILE}.1"
# 後続書込が append できるよう空ファイルを再作成
: > "$LOG_FILE"

echo "[shim-hits-rotate] rotated ${LOG_FILE} (size=${current_size}, max=${MAX_SIZE}, keep=${KEEP})"
