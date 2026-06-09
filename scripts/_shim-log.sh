#!/usr/bin/env bash
# scripts/_shim-log.sh
#
# shim 共通ライブラリ。scripts/claude-wrapper.sh から `source` される。
# 役割:
#   - shim ヒットを ~/.rev_harness/shim-hits.log に JSONL で append
#   - sha256 ハッシュ計算 (macOS shasum / Linux sha256sum 両対応)
#   - PII (prompt 本文・生 argv) は一切記録しない (ハッシュのみ)
#   - 書込失敗は fail-open: stderr に警告出して継続
#
# 関連: docs/shim-spec.md (JSONL schema)
# Plan: docs/plans/2026-06-agent-sdk-migration/plan-v3-final.md (PR-A)

# 二重 source ガード
if [[ -n "${_REV_SHIM_LOG_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
_REV_SHIM_LOG_LOADED=1

_shim_log_warn() {
  echo "[shim-log] WARN: $*" >&2
}

# sha256 を 16進64文字で返す (stdin -> stdout)
_shim_sha256() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum | awk '{print $1}'
  else
    # 最後の手段: ハッシュ不能ならゼロ埋め (fail-open)
    printf '%064d' 0
  fi
}

# ISO8601 UTC タイムスタンプ
_shim_now_iso8601() {
  # macOS / Linux 両対応
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# 親プロセスの実行ファイルパスを取得 (macOS / Linux 両対応)
_shim_parent_exe() {
  local ppid="${PPID:-0}"
  if [[ "$ppid" == "0" ]]; then
    echo "unknown"
    return 0
  fi
  # ps での取得を試みる (macOS/Linux 両方で動く)
  local exe
  exe="$(ps -o comm= -p "$ppid" 2>/dev/null || true)"
  if [[ -z "$exe" ]]; then
    exe="unknown"
  fi
  printf '%s' "$exe"
}

# shim_log_hit <rewrite_target> [argv...]
#   rewrite_target: 移行先候補識別子 (例: "task-tool")
#   argv: 全引数。連結して sha256 を取りハッシュのみ記録
shim_log_hit() {
  local rewrite_target="${1:-unknown}"
  shift || true

  local log_file log_dir
  if [[ -n "${REV_HARNESS_SHIM_HITS_LOG:-}" ]]; then
    log_file="$REV_HARNESS_SHIM_HITS_LOG"
    log_dir="$(dirname "$log_file")"
  else
    log_dir="${HOME}/.rev_harness"
    log_file="${log_dir}/shim-hits.log"
  fi

  # ディレクトリ作成 (失敗時は fail-open)
  if ! mkdir -p "$log_dir" 2>/dev/null; then
    local _safe_dir="${log_dir/#${HOME}/\~}"
    _shim_log_warn "log dir 作成失敗: ${_safe_dir} (continue)"
    return 0
  fi

  local ts pid ppid parent_exe caller_hash argv_hash argv_joined
  ts="$(_shim_now_iso8601)"
  pid="$$"
  ppid="${PPID:-0}"
  parent_exe="$(_shim_parent_exe)"
  caller_hash="$(printf '%s\n' "${ppid}:${parent_exe}" | _shim_sha256)"
  # 全 argv を NUL ではなく ASCII 制御文字で連結 (bash 3.x 互換)
  argv_joined=""
  local a
  for a in "$@"; do
    argv_joined+="${a}"$'\x1f'
  done
  argv_hash="$(printf '%s' "$argv_joined" | _shim_sha256)"

  # オプショナル: REV_HARNESS_SHIM_JOB_ID が set されていれば job_id を付与
  # (backward compatible: 未 set なら従来通り 6 フィールド)
  local job_id_part=""
  if [[ -n "${REV_HARNESS_SHIM_JOB_ID:-}" ]]; then
    local jid_escaped
    jid_escaped=$(printf '%s' "$REV_HARNESS_SHIM_JOB_ID" \
      | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')
    job_id_part=",\"job_id\":\"${jid_escaped}\""
  fi

  # JSON 1行 (manual エンコード: 値はハッシュ・整数・固定文字列のみで安全)
  local line
  line=$(printf '{"ts":"%s","caller_hash":"%s","pid":%d,"ppid":%d,"rewrite_target":"%s","argv_hash":"%s"%s}\n' \
    "$ts" "$caller_hash" "$pid" "$ppid" "$rewrite_target" "$argv_hash" "$job_id_part")

  if ! printf '%s\n' "$line" 2>/dev/null >> "$log_file"; then
    local _safe_file="${log_file/#${HOME}/\~}"
    _shim_log_warn "log 書込失敗: ${_safe_file} (continue)"
    return 0
  fi

  return 0
}
