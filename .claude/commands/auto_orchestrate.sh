#!/usr/bin/env bash
set -euo pipefail

# ディレクトリ設定
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
PROMPT_DIR="$REPO_ROOT/docs/prompts"
# Phase 2: reusable review workflow contracts live under docs/prompts.
# This shell keeps routing, queue/state ownership, and fail-closed guards.
BATCH_REVIEW_TEMPLATE="$PROMPT_DIR/reviewer_batch.md"
TMP_BASE="$REPO_ROOT/.claude/tmp"
QUALITY_GATE="$REPO_ROOT/scripts/quality_gate.sh"
CODEX_WRAPPER_CANONICAL="$REPO_ROOT/scripts/codex-wrapper.sh"
CODEX_WRAPPER="$CODEX_WRAPPER_CANONICAL"  # Canonical runtime wrapper
LIB_DIR="$DIR/lib"
REVIEW_QUEUE_FILE="$REPO_ROOT/.claude/tmp/review_queue.json"
SEMANTIC_REVIEW_QUEUE_SCRIPT="$REPO_ROOT/scripts/semantic-review-queue.sh"
REVIEW_QUEUE_LEASE_SECONDS="${REVIEW_QUEUE_LEASE_SECONDS:-900}"
CONTEXT_CAPSULE_SCRIPT="$LIB_DIR/context_capsule.sh"
SHADOW_VERIFY_SCRIPT="$LIB_DIR/shadow_verify.sh"
TASK_CONTRACT_LIB="$LIB_DIR/task_contract.sh"
BASELINE_FREEZE_LIB="$LIB_DIR/baseline_freeze.sh"
ORCHESTRATION_PACKET_VALIDATOR_SCRIPT="$REPO_ROOT/scripts/validate-orchestration-packet.sh"
SRC_SYNC_FRESHNESS_FILE="$REPO_ROOT/.agent/context/product_surface_sync_freshness.json"
PRODUCT_SURFACE_SYNC_FRESHNESS_FILE="$SRC_SYNC_FRESHNESS_FILE"

# lib 読み込み
source "$LIB_DIR/utils.sh"
source "$LIB_DIR/state.sh"
source "$LIB_DIR/timeout.sh"
source "$LIB_DIR/session.sh"
source "$LIB_DIR/coder.sh"
source "$LIB_DIR/reviewer.sh"
# shellcheck source=./lib/orchestration_packet.sh
source "$LIB_DIR/orchestration_packet.sh"

task_contract_unavailable_reason=""
baseline_freeze_unavailable_reason=""
orchestration_packet_preflight_skip_reason=""

if [[ -f "$LIB_DIR/mcp_fallback.sh" ]]; then
  # shellcheck source=./lib/mcp_fallback.sh
  if ! source "$LIB_DIR/mcp_fallback.sh" 2>/dev/null; then
    log_warn "mcp_fallback.sh の source に失敗: preflight fail-closed contract は内部生成にフォールバック"
  fi
fi

run_context_analysis=false
coordination_context_unavailable=false
coordination_context_unavailable_reason=""
coordination_context_prepared=false

if [[ -f "$LIB_DIR/context_analysis.sh" ]]; then
  # shellcheck source=./lib/context_analysis.sh
  if source "$LIB_DIR/context_analysis.sh" 2>/dev/null; then
    run_context_analysis=true
  else
    coordination_context_unavailable=true
    coordination_context_unavailable_reason="context_analysis.sh の source に失敗"
    log_warn "context_analysis.sh の source に失敗: coordination preflight は fail-closed で停止"
  fi
else
  coordination_context_unavailable=true
  coordination_context_unavailable_reason="context_analysis.sh未配置"
  log_warn "context_analysis.sh未配置: coordination preflight は fail-closed で停止"
fi

if [[ ! -f "$CONTEXT_CAPSULE_SCRIPT" ]]; then
  log_warn "context_capsule.sh未配置: カプセル注入をスキップ"
fi

if [[ ! -f "$SHADOW_VERIFY_SCRIPT" ]]; then
  log_warn "shadow_verify.sh未配置: 機械検証ゲートをスキップしreviewerへ継続"
fi

# グローバル変数
PLAN=""
PHASE=""
REVIEWERS="safety,perf,consistency"
GATE=""
CODER_OUT=""
RUN_CODER=false
CODER_ENGINE="codex"   # --coder-engine: claude|codex（未指定時は codex）
CODER_ENGINE_EXPLICIT=false
MAX_ITERATIONS=5
CODEX_TIMEOUT=7200  # 2時間（秒）
CLAUDE_TIMEOUT=1800 # 30分（秒）
RESUME_STATE=""     # --resume で指定された state.json
CONTINUE_SESSION=false  # --continue-session: 前回セッションを継続
FORK_SESSION=false      # --fork-session: 前回セッションを分岐
SESSION_ID=""           # 現在のセッションID
FIX_UNTIL="all"         # --fix-until: 修正対象レベル（high/medium/low/all）デフォルト: all
LOCK_FILE=""            # ロックファイルパス（acquire_lock で設定）
LOCK_ACQUIRED=false     # ロック取得成功フラグ（release_lock のガード用）
LOCK_OWNER_TOKEN=""     # ロック所有トークン（LK-1）
LOCK_STALE_SECS="${LOCK_STALE_SECS:-3600}"  # stale判定しきい値（秒）
RECOVER_MODE=false      # --recover: stale state をリカバリ
AGENT_STRATEGY="fixed"  # --agent-strategy: fixed(デフォルト) または dynamic
MAX_CODERS=1            # --max-coders: 最大Coderエージェント数（dynamic時）
REVIEWER_STRATEGY="fixed"  # --reviewer-strategy: fixed(デフォルト) または auto

usage() {
  cat <<'USAGE'
Usage: auto_orchestrate.sh --plan PATH --phase PHASE [OPTIONS]
       auto_orchestrate.sh --resume STATE_FILE [OPTIONS]

Options:
  --plan PATH                 プランファイルのパス（新規実行時は必須）
  --phase PHASE               フェーズ名: test, impl など（新規実行時は必須）
  --resume STATE_FILE         state.json から再開（中断した実行を継続）
  --reviewers LIST            レビュワー一覧（デフォルト: safety,perf,consistency）
  --coder-output FILE         Coder出力ファイル（指定しない場合は自動パス）
  --gate levelA|levelB|levelC 品質ゲートのレベル
  --run-coder                 選択した Coder engine でCoderを自動起動
  --coder-engine ENGINE       Coder engine: claude | codex（デフォルト: codex）
  --continue-session          予約済み。non-interactive invariant により fail-closed
  --fork-session              予約済み。non-interactive invariant により fail-closed
  --max-iterations N          レビュー反復の最大回数（デフォルト: 5）
                              Note: N=1は「1回レビューして問題があれば即失敗」を意味する
  --fix-until LEVEL           修正対象レベル: high, medium, low, all（デフォルト: all）
  --codex-timeout SECS        Codexレビューのタイムアウト秒（デフォルト: 7200 = 2時間）
  --claude-timeout SECS       Claude Coderのタイムアウト秒（デフォルト: 1800 = 30分）
  --recover                   Stale state を検出してクリーンアップ（--resume と併用）
  --agent-strategy MODE       エージェント起動戦略: fixed(デフォルト), dynamic
  --max-coders N              最大Coderエージェント数（dynamic時、デフォルト: 1）
  --reviewer-strategy MODE    レビュワー選択戦略: fixed(デフォルト), auto
  --status                    state.json のサマリーを表示
  -h, --help                  ヘルプを表示

Session Options:
  --resume STATE_FILE は orchestration state の再開です。agent session の継続ではありません。
  --continue-session / --fork-session は non-interactive invariant により
  orchestrated/automatic flow では常に fail-closed です。

Compatibility Notes:
  Batch review prompt contract: docs/prompts/reviewer_batch.md
  This shell keeps queue/state routing and fail-closed wrapper/template checks.

Steps:
 1) --run-coder 指定時: 選択した Coder engine でフェーズ出力を生成
 2) 各観点レビュワー(Codex)を並列実行し、指摘を集約
 3) ブロッカー指摘があれば修正→再レビューを反復（最大 max-iterations 回）
 4) --gate 指定時: 品質ゲートを実行

Examples:
  # 新規実行
  ./auto_orchestrate.sh --plan .agent/plan_*.md --phase impl --run-coder --gate levelB

  # 中断後の再開
  ./auto_orchestrate.sh --resume .claude/tmp/<task>/state.json

  # 状態確認
  ./auto_orchestrate.sh --resume .claude/tmp/<task>/state.json --status
USAGE
}

# 注: log_info, log_warn, log_error, die, ensure_cmd は lib/utils.sh から提供
SHOW_STATUS=false

# シグナルハンドリング用変数
CLEANUP_DONE=false

# =====================================================
# Lock Functions (同時実行防止)
# =====================================================

# ISO8601 (UTC) を epoch 秒へ変換（macOS/Linux 両対応）
# Usage: _timestamp_to_epoch <timestamp>
# Returns: epoch seconds, or 0 if parse failed
_timestamp_to_epoch() {
  local ts="${1:-}"
  if [[ -z "$ts" ]]; then
    echo 0
    return 0
  fi

  local date_part="${ts%.*}"  # 小数点以下を除去
  date_part="${date_part%Z}"  # 末尾 Z を除去

  if [[ "$(uname)" == "Darwin" ]]; then
    TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$date_part" +%s 2>/dev/null || echo 0
  else
    date -d "$ts" +%s 2>/dev/null || echo 0
  fi
}

# PID 生存確認
# Usage: _is_pid_alive <pid>
_is_pid_alive() {
  local pid="${1:-}"
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# ロックメタデータパス
# Usage: _lock_meta_file <lock_dir>
_lock_meta_file() {
  local lock_dir="$1"
  echo "$lock_dir/owner.json"
}

# ロック所有メタデータ作成（LK-1）
# Usage: _lock_write_metadata <lock_dir> <owner_token>
_lock_write_metadata() {
  local lock_dir="$1"
  local owner_token="$2"
  local meta_file
  meta_file=$(_lock_meta_file "$lock_dir")
  local now
  now=$(get_timestamp)
  local owner="${USER:-unknown}"
  local host
  host=$(hostname 2>/dev/null || echo "unknown")

  jq -n \
    --arg token "$owner_token" \
    --argjson pid "$$" \
    --arg owner "$owner" \
    --arg host "$host" \
    --arg created_at "$now" \
    --arg updated_at "$now" \
    --arg state_file "${STATE_FILE:-}" \
    '{
      owner_token: $token,
      pid: $pid,
      owner: $owner,
      host: $host,
      created_at: $created_at,
      updated_at: $updated_at,
      state_file: (if ($state_file | length) > 0 then $state_file else null end)
    }' > "$meta_file"
}

# ロック所有者かどうかを判定
# Usage: _lock_is_owned_by_current <lock_dir>
_lock_is_owned_by_current() {
  local lock_dir="$1"
  local meta_file
  meta_file=$(_lock_meta_file "$lock_dir")

  if [[ -z "${LOCK_OWNER_TOKEN:-}" || ! -f "$meta_file" ]]; then
    return 1
  fi

  local token pid
  token=$(jq -r '.owner_token // empty' "$meta_file" 2>/dev/null || true)
  pid=$(jq -r '.pid // empty' "$meta_file" 2>/dev/null || true)

  [[ "$token" == "$LOCK_OWNER_TOKEN" && "$pid" == "$$" ]]
}

# stale lock 判定（LK-1）
# 条件: updated_at がしきい値超過 AND pid 非生存
# Usage: _lock_is_stale <lock_dir> [max_age_secs]
_lock_is_stale() {
  local lock_dir="$1"
  local max_age_secs="${2:-$LOCK_STALE_SECS}"
  local meta_file
  meta_file=$(_lock_meta_file "$lock_dir")

  if [[ ! -f "$meta_file" ]]; then
    # LK-1: time-only 削除禁止のため、メタデータ不在時は自動削除しない
    log_warn "Lock metadata missing: $meta_file (auto cleanup skipped)"
    return 1
  fi

  local lock_pid updated_at
  lock_pid=$(jq -r '.pid // empty' "$meta_file" 2>/dev/null || true)
  updated_at=$(jq -r '.updated_at // empty' "$meta_file" 2>/dev/null || true)

  if _is_pid_alive "$lock_pid"; then
    return 1
  fi

  local updated_epoch now_epoch age_secs
  updated_epoch=$(_timestamp_to_epoch "$updated_at")
  now_epoch=$(date +%s)

  if [[ "$updated_epoch" -eq 0 ]]; then
    log_warn "Lock metadata timestamp is invalid (pid dead): $updated_at"
    return 0
  fi

  age_secs=$((now_epoch - updated_epoch))
  if [[ "$age_secs" -gt "$max_age_secs" ]]; then
    log_warn "Stale lock detected: pid=$lock_pid dead, age=${age_secs}s (max=${max_age_secs}s)"
    return 0
  fi

  return 1
}

# ロック heartbeat 更新（LK-1）
# Usage: refresh_lock
refresh_lock() {
  if [[ "${LOCK_ACQUIRED:-}" != "true" || -z "${LOCK_FILE:-}" ]]; then
    return 0
  fi

  local lock_dir="${LOCK_FILE}.d"
  local meta_file
  meta_file=$(_lock_meta_file "$lock_dir")

  if [[ ! -d "$lock_dir" || ! -f "$meta_file" ]]; then
    return 1
  fi

  if ! _lock_is_owned_by_current "$lock_dir"; then
    log_warn "refresh_lock: ownership mismatch (skip heartbeat)"
    return 1
  fi

  local tmp_file now owner host
  tmp_file=$(create_temp_file "lock_meta")
  now=$(get_timestamp)
  owner="${USER:-unknown}"
  host=$(hostname 2>/dev/null || echo "unknown")

  if jq \
    --arg token "$LOCK_OWNER_TOKEN" \
    --argjson pid "$$" \
    --arg updated_at "$now" \
    --arg owner "$owner" \
    --arg host "$host" \
    --arg state_file "${STATE_FILE:-}" \
    '
      .owner_token = $token
      | .pid = $pid
      | .updated_at = $updated_at
      | .owner = $owner
      | .host = $host
      | .state_file = (if ($state_file | length) > 0 then $state_file else .state_file end)
    ' "$meta_file" > "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$meta_file"
    return 0
  fi

  rm -f "$tmp_file" 2>/dev/null || true
  return 1
}

# ロック取得（LK-1）
# Usage: acquire_lock <task_tmpdir>
# Returns: 0 on success, dies on failure
acquire_lock() {
  local task_tmpdir="$1"
  local lock_file="$task_tmpdir/.lock"
  local lock_dir="${lock_file}.d"

  if mkdir "$lock_dir" 2>/dev/null; then
    LOCK_FILE="$lock_file"
    LOCK_OWNER_TOKEN=$(generate_uuid)
    _lock_write_metadata "$lock_dir" "$LOCK_OWNER_TOKEN" || {
      rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
      die "Failed to initialize lock metadata: $lock_dir"
    }
    LOCK_ACQUIRED=true
    log_debug "Lock acquired (mkdir + metadata): $lock_dir"
    return 0
  fi

  if [[ -d "$lock_dir" ]] && _lock_is_stale "$lock_dir" "$LOCK_STALE_SECS"; then
    log_warn "Removing stale lock directory: $lock_dir"
    rm -rf "$lock_dir" 2>/dev/null || true
    if mkdir "$lock_dir" 2>/dev/null; then
      LOCK_FILE="$lock_file"
      LOCK_OWNER_TOKEN=$(generate_uuid)
      _lock_write_metadata "$lock_dir" "$LOCK_OWNER_TOKEN" || {
        rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
        die "Failed to initialize lock metadata after stale cleanup: $lock_dir"
      }
      LOCK_ACQUIRED=true
      log_debug "Lock acquired after stale cleanup: $lock_dir"
      return 0
    fi
  fi

  die "Another instance is running (lock: $lock_dir). Use --recover --resume STATE_FILE to force cleanup."
}

# ロック解放
# Usage: release_lock
release_lock() {
  if [[ "${LOCK_ACQUIRED:-}" != "true" ]]; then
    return 0
  fi

  if [[ -n "${LOCK_FILE:-}" ]]; then
    local lock_dir="${LOCK_FILE}.d"
    local meta_file
    meta_file=$(_lock_meta_file "$lock_dir")

    if [[ -d "$lock_dir" ]]; then
      if _lock_is_owned_by_current "$lock_dir"; then
        rm -f "$meta_file" 2>/dev/null || true
        rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
        log_debug "Lock released: $lock_dir"
      else
        log_warn "release_lock: ownership mismatch (skip lock removal): $lock_dir"
      fi
    fi
  fi

  LOCK_OWNER_TOKEN=""
  LOCK_ACQUIRED=false
}

# =====================================================
# Recovery Functions (stale state 検出・クリーンアップ)
# =====================================================

# stale state 検出
# Usage: is_state_stale <state_file> [max_age_secs]
# Returns: 0 if stale, 1 if fresh
is_state_stale() {
  local state_file="$1"
  local max_age_secs="${2:-3600}"  # デフォルト1時間

  if [[ ! -f "$state_file" ]]; then
    return 1  # ファイルがなければ stale ではない
  fi

  local updated_at
  updated_at=$(jq -r '.updated_at // empty' "$state_file" 2>/dev/null)

  if [[ -z "$updated_at" ]]; then
    return 0  # updated_at がなければ stale とみなす
  fi

  local now_epoch updated_epoch age_secs
  now_epoch=$(date +%s)
  updated_epoch=$(_timestamp_to_epoch "$updated_at")

  if [[ $updated_epoch -eq 0 ]]; then
    log_warn "Could not parse updated_at timestamp: $updated_at"
    return 0  # パース失敗は stale とみなす
  fi

  age_secs=$((now_epoch - updated_epoch))

  if [[ $age_secs -gt $max_age_secs ]]; then
    log_warn "State is stale: last updated ${age_secs}s ago (max: ${max_age_secs}s)"
    return 0
  fi

  return 1
}

# リカバリ処理
# Usage: recover_stale_state <state_file>
# Security: 対象パスが TMP_BASE 配下であることを検証
recover_stale_state() {
  local state_file="$1"

  # セキュリティ: state_file が TMP_BASE 配下かつ state.json であることを検証
  local abs_state_file abs_tmp_base
  abs_state_file=$(cd "$(dirname "$state_file")" 2>/dev/null && pwd)/$(basename "$state_file")
  abs_tmp_base=$(cd "$TMP_BASE" 2>/dev/null && pwd)

  if [[ ! "$abs_state_file" == "$abs_tmp_base"/* ]]; then
    die "recover_stale_state: state_file must be under TMP_BASE ($TMP_BASE)"
  fi

  if [[ "$(basename "$state_file")" != "state.json" ]]; then
    die "recover_stale_state: state_file must be named 'state.json'"
  fi

  local task_tmpdir
  task_tmpdir=$(dirname "$state_file")

  log_info "Recovering stale state: $state_file"

  # ロックファイル/ディレクトリを強制削除
  local lock_file="$task_tmpdir/.lock"
  local lock_dir="${lock_file}.d"

  if [[ -d "$lock_dir" ]]; then
    rmdir "$lock_dir" 2>/dev/null || rm -rf "$lock_dir" 2>/dev/null || true
    log_info "Removed stale lock directory: $lock_dir"
  fi

  if [[ -f "$lock_file" ]]; then
    rm -f "$lock_file" 2>/dev/null || true
    log_info "Removed stale lock file: $lock_file"
  fi

  # state.json のステータスを recovered に更新
  if [[ -f "$state_file" ]]; then
    local tmp_file
    tmp_file=$(create_temp_file "state_recover")  # macOS 互換
    local now
    now=$(get_timestamp)

    if jq --arg ts "$now" '.status = "recovered" | .recovered_at = $ts' "$state_file" > "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$state_file"
      log_info "State marked as recovered"
    else
      rm -f "$tmp_file" 2>/dev/null || true
      log_warn "Could not update state file"
    fi
  fi

  log_info "Recovery complete. You can now re-run with --resume $state_file"
}

# クリーンアップ関数
cleanup() {
  if [[ "${CLEANUP_DONE:-}" == "true" ]]; then
    return
  fi
  CLEANUP_DONE=true

  log_warn "Signal received, cleaning up..."

  # タスクロックを解放
  release_lock

  # 状態ファイルが初期化されている場合、interrupted 状態を保存
  # Note: ${STATE_FILE:-} で未定義時のエラーを防止（set -u 対策）
  if [[ -n "${STATE_FILE:-}" && -f "$STATE_FILE" ]]; then
    # ロックを解放（もし保持していれば）
    if [[ -n "${STATE_LOCK_FILE:-}" ]]; then
      lock_release "$STATE_LOCK_FILE" 2>/dev/null || true
    fi

    # 状態を interrupted に更新（直接 jq で操作、ロックなし）
    local tmp_file
    tmp_file=$(mktemp)
    local now
    now=$(get_timestamp)
    if jq --arg ts "$now" '.status = "interrupted" | .updated_at = $ts' "$STATE_FILE" > "$tmp_file" 2>/dev/null; then
      mv "$tmp_file" "$STATE_FILE" 2>/dev/null || true
      log_info "State saved as 'interrupted': $STATE_FILE"
    else
      rm -f "$tmp_file" 2>/dev/null || true
    fi
  fi

  log_info "Cleanup completed. You can resume with: --resume $STATE_FILE"
  exit 130  # 標準的なSIGINT終了コード
}

# シグナルトラップ設定
# SIGINT/SIGTERM: 完全クリーンアップ（状態保存 + ロック解放）
# EXIT: ロック解放のみ（die や set -e による中断でもロックを解放）
trap cleanup SIGINT SIGTERM
trap 'release_lock' EXIT

# 注: タイムアウト機能は lib/timeout.sh に移動済み
# timeout_run() を使用してください

# 引数が存在するか確認するヘルパー関数
require_arg() {
  local opt="$1"
  local val="$2"
  if [[ -z "$val" || "$val" == --* ]]; then
    die "Option $opt requires an argument"
  fi
}

resolve_coder_engine_selection() {
  local state_engine="${1:-}"

  if [[ "$CODER_ENGINE_EXPLICIT" == "true" ]]; then
    CODER_ENGINE=$(_coder_resolve_engine "$CODER_ENGINE")
    if [[ -n "$state_engine" ]]; then
      local resolved_state_engine=""
      if resolved_state_engine=$(_coder_resolve_engine "$state_engine" 2>/dev/null); then
        if [[ "$resolved_state_engine" != "$CODER_ENGINE" ]]; then
          log_warn "Overriding persisted coder_engine: $resolved_state_engine -> $CODER_ENGINE"
        fi
      else
        log_warn "Ignoring invalid persisted coder_engine: $state_engine"
      fi
    fi
    return 0
  fi

  if [[ -n "$state_engine" ]]; then
    CODER_ENGINE=$(_coder_resolve_engine "$state_engine")
  else
    CODER_ENGINE=$(_coder_resolve_engine "$CODER_ENGINE")
  fi
}

should_use_legacy_claude_resume_compat() {
  local state_engine="${1:-}"
  local phase="${2:-}"

  if [[ "$CODER_ENGINE_EXPLICIT" == "true" ]]; then
    return 1
  fi

  if [[ -n "$state_engine" ]]; then
    return 1
  fi

  if [[ "$CONTINUE_SESSION" != "true" ]] && [[ "$FORK_SESSION" != "true" ]]; then
    return 1
  fi

  if [[ -z "$phase" ]]; then
    return 1
  fi

  if state_phase_has_engine_metadata "$phase"; then
    return 1
  fi

  [[ -n "$(state_get_last_legacy_session "$phase")" ]]
}

persist_coder_engine_assignment() {
  local engine
  engine=$(_coder_resolve_engine "${1:-$CODER_ENGINE}")

  if [[ -z "${STATE_FILE:-}" ]]; then
    die "State not initialized. Cannot persist coder_engine."
  fi

  state_set_coder_engine "$engine"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --plan)
        [[ $# -ge 2 ]] || die "Option --plan requires an argument"
        require_arg "--plan" "$2"
        PLAN="$2"; shift 2 ;;
      --phase)
        [[ $# -ge 2 ]] || die "Option --phase requires an argument"
        require_arg "--phase" "$2"
        PHASE="$2"; shift 2 ;;
      --resume)
        [[ $# -ge 2 ]] || die "Option --resume requires an argument"
        require_arg "--resume" "$2"
        RESUME_STATE="$2"; shift 2 ;;
      --status) SHOW_STATUS=true; shift ;;
      --recover) RECOVER_MODE=true; shift ;;
      --reviewers)
        [[ $# -ge 2 ]] || die "Option --reviewers requires an argument"
        require_arg "--reviewers" "$2"
        # セキュリティ: 各レビュワー名を検証（パストラバーサル/インジェクション防止）
        IFS=',' read -ra _reviewers <<< "$2"
        for _r in "${_reviewers[@]}"; do
          _validate_identifier "$_r" "reviewer name"
        done
        REVIEWERS="$2"; shift 2 ;;
      --coder-output)
        [[ $# -ge 2 ]] || die "Option --coder-output requires an argument"
        require_arg "--coder-output" "$2"
        CODER_OUT="$2"; shift 2 ;;
      --gate)
        [[ $# -ge 2 ]] || die "Option --gate requires an argument"
        require_arg "--gate" "$2"
        GATE="$2"; shift 2 ;;
      --run-coder) RUN_CODER=true; shift ;;
      --coder-engine)
        [[ $# -ge 2 ]] || die "Option --coder-engine requires an argument"
        require_arg "--coder-engine" "$2"
        CODER_ENGINE=$(_coder_resolve_engine "$2")
        CODER_ENGINE_EXPLICIT=true
        shift 2 ;;
      --continue-session) CONTINUE_SESSION=true; shift ;;
      --fork-session) FORK_SESSION=true; shift ;;
      --max-iterations)
        [[ $# -ge 2 ]] || die "Option --max-iterations requires an argument"
        require_arg "--max-iterations" "$2"
        # 正の整数であることを検証
        if [[ ! "$2" =~ ^[1-9][0-9]*$ ]]; then
          die "--max-iterations must be a positive integer (got: $2)"
        fi
        MAX_ITERATIONS="$2"; shift 2 ;;
      --fix-until)
        [[ $# -ge 2 ]] || die "Option --fix-until requires an argument"
        require_arg "--fix-until" "$2"
        case "$2" in
          high|medium|low|all) FIX_UNTIL="$2" ;;
          *) die "--fix-until must be one of: high, medium, low, all" ;;
        esac
        shift 2 ;;
      --codex-timeout)
        [[ $# -ge 2 ]] || die "Option --codex-timeout requires an argument"
        require_arg "--codex-timeout" "$2"
        # 正の整数であることを検証（上限: 86400秒=24時間）
        if [[ ! "$2" =~ ^[1-9][0-9]*$ ]] || [[ "$2" -gt 86400 ]]; then
          die "--codex-timeout must be a positive integer <= 86400 (got: $2)"
        fi
        CODEX_TIMEOUT="$2"; shift 2 ;;
      --claude-timeout)
        [[ $# -ge 2 ]] || die "Option --claude-timeout requires an argument"
        require_arg "--claude-timeout" "$2"
        # 正の整数であることを検証（上限: 86400秒=24時間）
        if [[ ! "$2" =~ ^[1-9][0-9]*$ ]] || [[ "$2" -gt 86400 ]]; then
          die "--claude-timeout must be a positive integer <= 86400 (got: $2)"
        fi
        CLAUDE_TIMEOUT="$2"; shift 2 ;;
      --agent-strategy)
        [[ $# -ge 2 ]] || die "Option --agent-strategy requires an argument"
        require_arg "--agent-strategy" "$2"
        case "$2" in
          fixed|dynamic) AGENT_STRATEGY="$2" ;;
          *) die "--agent-strategy must be one of: fixed, dynamic" ;;
        esac
        shift 2 ;;
      --max-coders)
        [[ $# -ge 2 ]] || die "Option --max-coders requires an argument"
        require_arg "--max-coders" "$2"
        if [[ ! "$2" =~ ^[1-9][0-9]*$ ]] || [[ "$2" -gt 10 ]]; then
          die "--max-coders must be a positive integer <= 10 (got: $2)"
        fi
        MAX_CODERS="$2"; shift 2 ;;
      --reviewer-strategy)
        [[ $# -ge 2 ]] || die "Option --reviewer-strategy requires an argument"
        require_arg "--reviewer-strategy" "$2"
        case "$2" in
          fixed|auto) REVIEWER_STRATEGY="$2" ;;
          *) die "--reviewer-strategy must be one of: fixed, auto" ;;
        esac
        shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "unknown arg: $1" ;;
    esac
  done

  # 相互排他チェック: --continue-session と --fork-session は同時指定不可
  if [[ "$CONTINUE_SESSION" == "true" ]] && [[ "$FORK_SESSION" == "true" ]]; then
    die "--continue-session and --fork-session are mutually exclusive. Please specify only one."
  fi

  if [[ "$CONTINUE_SESSION" == "true" ]] || [[ "$FORK_SESSION" == "true" ]]; then
    die "Non-interactive invariant: --continue-session/--fork-session are disabled in orchestrated flow. Use --resume STATE_FILE to restart orchestration state, and let the harness start a fresh agent session."
  fi

  # --resume モードの場合、state.json から設定を読み込む
  if [[ -n "$RESUME_STATE" ]]; then
    if [[ ! -f "$RESUME_STATE" ]]; then
      die "State file not found: $RESUME_STATE"
    fi
    state_load "$RESUME_STATE"

    # --status のみ指定時はサマリー表示して終了
    if [[ "$SHOW_STATUS" == "true" ]]; then
      state_show_summary
      exit 0
    fi

    local state_engine=""
    state_engine=$(state_get '.assignments.coder_engine')
    resolve_coder_engine_selection "$state_engine"

    # state.json から PLAN, PHASE を復元
    PLAN=$(state_resolve_plan_path "" "$REPO_ROOT") || {
      die "Failed to resolve plan path from state against repo root: $(state_get '.task.plan_path')"
    }
    # 現在の running フェーズを探す
    local running_phase
    running_phase=$(jq -r '.phases[] | select(.status == "running" or .status == "review" or .status == "fixing") | .name' "$RESUME_STATE" | head -1)
    if [[ -n "$running_phase" ]]; then
      PHASE="$running_phase"
    else
      # running がなければ最後の pending を使う
      PHASE=$(jq -r '.phases[] | select(.status == "pending") | .name' "$RESUME_STATE" | head -1)
    fi

    local legacy_resume_compat=false
    local malformed_session_engine_metadata=false
    if [[ "$CONTINUE_SESSION" == "true" ]] || [[ "$FORK_SESSION" == "true" ]]; then
      if state_phase_has_invalid_engine_metadata "$PHASE"; then
        malformed_session_engine_metadata=true
        log_warn "Malformed session engine metadata detected for phase: $PHASE; legacy Claude compatibility lookup disabled"
      fi
    fi
    if [[ "$malformed_session_engine_metadata" != "true" ]] && should_use_legacy_claude_resume_compat "$state_engine" "$PHASE"; then
      legacy_resume_compat=true
      CODER_ENGINE="claude"
      log_warn "Legacy resume state without coder_engine/session engine metadata detected; defaulting continue/fork compatibility mode to Claude"
    fi

    log_info "Resuming from state: $RESUME_STATE"
    log_info "  Plan: $PLAN"
    log_info "  Phase: $PHASE"
    log_info "  Coder engine: $(_coder_engine_label "$CODER_ENGINE")"

    # セッション継続/分岐オプション処理
    if [[ "$CONTINUE_SESSION" == "true" ]] || [[ "$FORK_SESSION" == "true" ]]; then
      local legacy_session_id=""
      # 選択した engine と同じ family の直近セッションだけを参照する
      SESSION_ID=$(state_get_last_session "$PHASE" "$CODER_ENGINE")
      if [[ -z "$SESSION_ID" ]] && [[ "$CODER_ENGINE" == "claude" ]]; then
        legacy_session_id=$(state_get_last_legacy_session "$PHASE")
        if [[ -n "$legacy_session_id" ]]; then
          SESSION_ID="$legacy_session_id"
          if [[ "$legacy_resume_compat" == "true" ]]; then
            log_warn "Legacy continue/fork compatibility mode active; using phase-only Claude session lookup"
          else
            log_warn "Legacy state without session engine metadata detected; using phase-only Claude session lookup"
          fi
        fi
      fi

      if [[ -n "$SESSION_ID" ]]; then
        log_info "  Previous $(_coder_engine_label "$CODER_ENGINE") session: $SESSION_ID"
        if [[ "$CODER_ENGINE" == "codex" ]]; then
          if [[ "$FORK_SESSION" == "true" ]]; then
            log_warn "Codex coder engine does not support --fork-session in orchestrator mode; a new Codex run will be started"
          else
            log_warn "Codex coder engine does not support --continue-session in orchestrator mode; a new Codex run will be started"
          fi
          CONTINUE_SESSION=false
          FORK_SESSION=false
          SESSION_ID=""
        elif [[ "$FORK_SESSION" == "true" ]]; then
          log_info "  Mode: Fork (creating new branch from previous session)"
        else
          log_info "  Mode: Continue (resuming previous session)"
        fi
      else
        log_warn "No previous $(_coder_engine_label "$CODER_ENGINE") session found for phase: $PHASE"
        log_info "Will start a new session instead"
        CONTINUE_SESSION=false
        FORK_SESSION=false
      fi
    fi
  else
    # --recover モードの場合は --resume が必須（--plan/--phase は不要）
    if [[ "$RECOVER_MODE" == "true" ]]; then
      die "--recover requires --resume to specify the state file"
    fi

    # 新規実行時は --plan と --phase が必須
    [[ -n "$PLAN" ]] || die "--plan is required (or use --resume)"
    [[ -n "$PHASE" ]] || die "--phase is required (or use --resume)"
    [[ -f "$PLAN" ]] || die "plan not found: $PLAN"

    resolve_coder_engine_selection
  fi
}

# Note: _validate_identifier() is defined in lib/utils.sh

# 選択した Coder engine でCoderを起動（セッション対応版）
run_coder() {
  local tmpdir="$1"
  local phase="$2"
  local plan="$3"

  # プロンプトインジェクション防止: phase を検証
  _validate_identifier "$phase" "phase"

  local outfile="$tmpdir/${phase}_coder.md"
  local new_session_id=""
  local parent_session_id=""
  local coder_engine_label
  coder_engine_label=$(_coder_engine_label "$CODER_ENGINE")
  local continue_session="$CONTINUE_SESSION"
  local fork_session="$FORK_SESSION"

  log_info "Running Coder (${coder_engine_label}) for phase: $phase"

  if [[ "$CODER_ENGINE" == "codex" ]] && { [[ "$continue_session" == "true" ]] || [[ "$fork_session" == "true" ]]; }; then
    if [[ "$fork_session" == "true" ]]; then
      log_warn "Codex coder engine does not support --fork-session in orchestrator mode; starting a new Codex run"
    else
      log_warn "Codex coder engine does not support --continue-session in orchestrator mode; starting a new Codex run"
    fi
    continue_session=false
    fork_session=false
  fi

  # セッションモードに応じた実行
  if [[ "$fork_session" == "true" ]] && [[ -n "$SESSION_ID" ]]; then
    # セッション分岐
    log_info "Forking from session: $SESSION_ID"
    local fork_prompt
    fork_prompt=$(coder_build_prompt "$plan" "$phase" "Forked from session: $SESSION_ID")
    parent_session_id="$SESSION_ID"
    new_session_id=$(coder_fork "$SESSION_ID" "$fork_prompt" "$outfile" "$CODER_ENGINE")
  elif [[ "$continue_session" == "true" ]] && [[ -n "$SESSION_ID" ]]; then
    # セッション継続
    log_info "Continuing session: $SESSION_ID"
    local resume_prompt
    resume_prompt=$(coder_build_prompt "$plan" "$phase" "Resuming session: $SESSION_ID")
    if coder_resume "$SESSION_ID" "$resume_prompt" "$outfile" "$CODER_ENGINE"; then
      new_session_id="$SESSION_ID"
    else
      log_warn "Session resume failed, starting new session"
      new_session_id=$(coder_run "$plan" "$phase" "$outfile" "" "$CODER_ENGINE")
    fi
  else
    # 新規セッション
    new_session_id=$(coder_run "$plan" "$phase" "$outfile" "" "$CODER_ENGINE")
  fi

  # output/engine は常に記録し、session_id が取れた場合だけ scratch session も保存する
  coder_record_to_state "$phase" "$new_session_id" "$outfile" "$CODER_ENGINE" "$parent_session_id"

  # セッションIDを更新
  if [[ -n "$new_session_id" ]]; then
    SESSION_ID="$new_session_id"
    log_info "Session recorded: $new_session_id"
  else
    log_warn "Coder session ID was not captured; recorded phase output and engine without session linkage"
  fi

  log_info "Coder output saved: $outfile"
  echo "$outfile"
}

_task_contract_rel_path_for_task() {
  local task="$1"
  local pattern='^[a-zA-Z0-9._-]+$'

  if [[ -z "$task" ]]; then
    log_error "Invalid task artifact path segment: empty"
    return 1
  fi

  if [[ ! "$task" =~ $pattern ]]; then
    log_error "Invalid task artifact path segment: $task"
    return 1
  fi

  case "$task" in
    .|..)
      log_error "Invalid task artifact path segment: $task"
      return 1
      ;;
  esac

  printf '.claude/tmp/%s/task-contract.json\n' "$task"
}

_task_contract_abs_path() {
  local contract_path="$1"

  if [[ "$contract_path" == /* ]]; then
    printf '%s\n' "$contract_path"
  else
    printf '%s/%s\n' "$REPO_ROOT" "$contract_path"
  fi
}

_task_contract_validate_or_fail() {
  local contract_path="$1"
  local phase="$2"
  local message=""

  if task_contract_validate_file "$contract_path"; then
    return 0
  fi

  message="Task contract invalid, unreadable, or incomplete. See: $contract_path"
  state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
  state_save
  die "$message"
}

_task_contract_function_source_matches() {
  local function_name="$1"
  local canonical_task_contract_lib="$2"
  local restore_extdebug=""
  local function_decl=""
  local function_source=""

  restore_extdebug="$(shopt -p extdebug 2>/dev/null || true)"
  shopt -s extdebug
  function_decl="$(declare -F "$function_name" 2>/dev/null || true)"
  if [[ -n "$restore_extdebug" ]]; then
    eval "$restore_extdebug" >/dev/null 2>&1 || true
  else
    shopt -u extdebug >/dev/null 2>&1 || true
  fi

  [[ -n "$function_decl" ]] || return 1
  read -r _ _ function_source <<< "$function_decl"
  [[ -n "$function_source" ]] || return 1

  function_source="$(cd "$(dirname "$function_source")" && pwd -P)/$(basename "$function_source")" || return 1
  [[ "$function_source" == "$canonical_task_contract_lib" ]]
}

_load_task_contract_lib() {
  local canonical_task_contract_lib=""
  local function_name=""
  local needs_source=true

  canonical_task_contract_lib="$(cd "$(dirname "$TASK_CONTRACT_LIB")" && pwd -P)/$(basename "$TASK_CONTRACT_LIB")" || {
    task_contract_unavailable_reason="failed to resolve canonical task contract path: $TASK_CONTRACT_LIB"
    return 1
  }

  if [[ ! -r "$canonical_task_contract_lib" ]]; then
    task_contract_unavailable_reason="missing or unreadable: $canonical_task_contract_lib"
    return 1
  fi

  for function_name in task_contract_emit task_contract_validate_file task_contract_read_id; do
    if ! _task_contract_function_source_matches "$function_name" "$canonical_task_contract_lib"; then
      needs_source=true
      break
    fi
    needs_source=false
  done

  if [[ "$needs_source" == "false" ]]; then
    task_contract_unavailable_reason=""
    return 0
  fi

  unset -f task_contract_emit task_contract_validate_file task_contract_read_id >/dev/null 2>&1 || true

  # shellcheck source=./lib/task_contract.sh
  if ! source "$canonical_task_contract_lib"; then
    task_contract_unavailable_reason="source failed for $canonical_task_contract_lib"
    return 1
  fi

  for function_name in task_contract_emit task_contract_validate_file task_contract_read_id; do
    if ! _task_contract_function_source_matches "$function_name" "$canonical_task_contract_lib"; then
      task_contract_unavailable_reason="required task contract functions are not bound to canonical source: $canonical_task_contract_lib"
      return 1
    fi
  done

  task_contract_unavailable_reason=""
  return 0
}

_prepare_task_contract_for_coder_launch() {
  local tmpdir="$1"
  local phase="$2"
  local plan="$3"
  local task="$4"

  if ! _load_task_contract_lib; then
    message="Task contract library unavailable on orchestrated coder path."
    if [[ -n "${task_contract_unavailable_reason:-}" ]]; then
      message="${message} ${task_contract_unavailable_reason}"
    fi
    state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
    state_save
    die "$message"
  fi

  local task_id=""
  local contract_rel_path=""
  local contract_abs_path=""
  local contract_id=""
  local expected_contract_rel_path=""
  local persisted_contract_path=""
  local persisted_contract_abs_path=""
  local persisted_contract_id=""
  local actual_contract_id=""
  local persisted_artifact_task_id=""
  local message=""

  task_id=$(state_get '.task.id')
  if [[ -z "$task_id" ]]; then
    message="Task contract emission failed: missing state task.id"
    state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
    state_save
    die "$message"
  fi

  if ! expected_contract_rel_path=$(_task_contract_rel_path_for_task "$task"); then
    message="Task contract emission failed: invalid task artifact path segment: $task"
    state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
    state_save
    die "$message"
  fi

  persisted_contract_path=$(state_get_contract_path)
  persisted_contract_id=$(state_get_contract_id)
  if [[ -n "$persisted_contract_path" ]]; then
    if [[ "$persisted_contract_path" != "$expected_contract_rel_path" ]]; then
      message="Task contract persisted path is outside canonical location for this task."
      state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
      state_save
      die "$message"
    fi

    persisted_contract_abs_path="$REPO_ROOT/$persisted_contract_path"
    _task_contract_validate_or_fail "$persisted_contract_abs_path" "$phase"

    actual_contract_id=$(task_contract_read_id "$persisted_contract_abs_path" 2>/dev/null || true)
    if [[ -n "$persisted_contract_id" && -n "$actual_contract_id" && "$persisted_contract_id" != "$actual_contract_id" ]]; then
      message="Task contract id mismatch for persisted path. See: $persisted_contract_path"
      state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
      state_save
      die "$message"
    fi

    persisted_artifact_task_id=$(jq -r '.task_id // empty' "$persisted_contract_abs_path" 2>/dev/null || true)
    if [[ -z "$persisted_artifact_task_id" || "$persisted_artifact_task_id" != "$task_id" ]]; then
      message="Task contract task_id mismatch for persisted artifact."
      state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
      state_save
      die "$message"
    fi
  fi

  contract_rel_path="$expected_contract_rel_path"
  contract_abs_path="$REPO_ROOT/$contract_rel_path"

  if ! contract_id=$(task_contract_emit \
    --plan "$plan" \
    --phase "$phase" \
    --task-id "$task_id" \
    --coder-engine "$CODER_ENGINE" \
    --artifact-destination "$contract_rel_path" \
    --output "$contract_abs_path"); then
    message="Task contract emission failed closed before coder launch. See: $contract_abs_path"
    state_set_error "TASK_CONTRACT_BLOCK" "$message" "$phase"
    state_save
    die "$message"
  fi

  _task_contract_validate_or_fail "$contract_abs_path" "$phase"
  state_set_task_contract "$contract_id" "$contract_rel_path"
  state_save
  log_info "Task contract saved: $contract_rel_path ($contract_id)"
}

# Orchestration packet preflight is owned by lib/orchestration_packet.sh.

# =====================================================
# Coordination Layer Functions (Task 3.3)
# =====================================================

_coordination_resolve_task_id() {
  local fallback="$1"
  local task_id=""

  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    task_id=$(jq -r '.task.id // empty' "$STATE_FILE" 2>/dev/null || true)
  fi

  if [[ -z "$task_id" ]]; then
    task_id=$(printf '%s' "$fallback" | tr -c '[:alnum:]._-' '_')
    task_id="${task_id##[_-]}"
    task_id="${task_id%%[_-]}"
  fi

  if [[ -z "$task_id" ]]; then
    task_id="task_$(date +%Y%m%d_%H%M%S)"
  fi

  _validate_identifier "$task_id" "task_id"
  echo "$task_id"
}

_coordination_collect_changed_files_json() {
  local changed_tmp
  changed_tmp=$(create_temp_file "coord_changed_files")

  (
    cd "$REPO_ROOT"
    {
      git diff --name-only 2>/dev/null || true
      git diff --cached --name-only 2>/dev/null || true
      git ls-files --others --exclude-standard 2>/dev/null || true
    } | sed '/^[[:space:]]*$/d' | sed 's#^\./##' | sort -u
  ) > "$changed_tmp"

  local changed_json='[]'
  if [[ -s "$changed_tmp" ]]; then
    changed_json=$(jq -R . "$changed_tmp" | jq -s 'map(select(length > 0))')
  fi

  rm -f "$changed_tmp" 2>/dev/null || true
  echo "$changed_json"
}

_coordination_current_head_sha() {
  git -C "$REPO_ROOT" rev-parse HEAD 2>/dev/null || true
}

_coordination_normalize_src_files_json() {
  local payload="${1:-[]}"
  jq -cn --argjson files "$payload" '
    if ($files | type) == "array" then
      $files
      | map(
          select(type == "string")
          | sub("^\\./"; "")
          | sub("^[[:space:]]+"; "")
          | sub("[[:space:]]+$"; "")
          | select(length > 0 and startswith("src/"))
        )
      | unique
      | sort
    else
      []
    end
  ' 2>/dev/null || echo '[]'
}

_coordination_collect_changed_src_files_json() {
  _coordination_normalize_src_files_json "$(_coordination_collect_changed_files_json)"
}

_coordination_git_diff_src_files_between_json() {
  local base_ref="${1:-}"
  local head_ref="${2:-}"

  if [[ -z "$base_ref" || -z "$head_ref" || "$base_ref" == "$head_ref" ]]; then
    echo '[]'
    return 0
  fi

  local changed_tmp
  changed_tmp=$(create_temp_file "coord_src_commit_delta")

  (
    cd "$REPO_ROOT"
    git diff --name-only "$base_ref" "$head_ref" -- src 2>/dev/null || true
  ) > "$changed_tmp"

  local changed_json='[]'
  if [[ -s "$changed_tmp" ]]; then
    changed_json=$(jq -R . "$changed_tmp" | jq -cs '
      map(
        select(type == "string")
        | sub("^\\./"; "")
        | sub("^[[:space:]]+"; "")
        | sub("[[:space:]]+$"; "")
        | select(length > 0 and startswith("src/"))
      )
      | unique
      | sort
    ')
  fi

  rm -f "$changed_tmp" 2>/dev/null || true
  printf '%s\n' "$changed_json"
}

_coordination_file_mtime_epoch() {
  local file_path="${1:-}"
  [[ -n "$file_path" ]] || return 1

  if stat -f %m "$file_path" >/dev/null 2>&1; then
    stat -f %m "$file_path" 2>/dev/null
  else
    stat -c %Y "$file_path" 2>/dev/null
  fi
}

_coordination_src_files_newer_than_sync_json() {
  local synced_at="${1:-}"
  local files_json="${2:-[]}"
  local sync_epoch=0
  sync_epoch=$(_timestamp_to_epoch "$synced_at")

  if [[ "$sync_epoch" -le 0 ]]; then
    echo '[]'
    return 0
  fi

  local newer_tmp
  newer_tmp=$(create_temp_file "coord_src_newer_than_sync")
  : > "$newer_tmp"

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    local abs_file="$REPO_ROOT/$rel_file"
    [[ -e "$abs_file" ]] || continue

    local file_epoch=0
    file_epoch=$(_coordination_file_mtime_epoch "$abs_file" 2>/dev/null || echo 0)
    if [[ "$file_epoch" =~ ^[0-9]+$ ]] && [[ "$file_epoch" -gt "$sync_epoch" ]]; then
      printf '%s\n' "$rel_file" >> "$newer_tmp"
    fi
  done < <(jq -r '.[]' <<< "$files_json" 2>/dev/null || true)

  local newer_json='[]'
  if [[ -s "$newer_tmp" ]]; then
    newer_json=$(jq -R . "$newer_tmp" | jq -cs '
      map(select(type == "string" and length > 0))
      | unique
      | sort
    ')
  fi

  rm -f "$newer_tmp" 2>/dev/null || true
  printf '%s\n' "$newer_json"
}

_coordination_missing_src_files_json() {
  local files_json="${1:-[]}"
  local missing_tmp
  missing_tmp=$(create_temp_file "coord_missing_src_files")
  : > "$missing_tmp"

  local rel_file=""
  while IFS= read -r rel_file; do
    [[ -n "$rel_file" ]] || continue
    local abs_file="$REPO_ROOT/$rel_file"
    if [[ ! -e "$abs_file" ]]; then
      printf '%s\n' "$rel_file" >> "$missing_tmp"
    fi
  done < <(jq -r '.[]' <<< "$files_json" 2>/dev/null || true)

  local missing_json='[]'
  if [[ -s "$missing_tmp" ]]; then
    missing_json=$(jq -R . "$missing_tmp" | jq -cs '
      map(select(type == "string" and length > 0))
      | unique
      | sort
    ')
  fi

  rm -f "$missing_tmp" 2>/dev/null || true
  printf '%s\n' "$missing_json"
}

_coordination_src_sync_freshness_status() {
  if declare -F context_src_sync_status >/dev/null 2>&1; then
    context_src_sync_status
    return $?
  fi

  local freshness_file="$SRC_SYNC_FRESHNESS_FILE"
  local repomap_dir="$REPO_ROOT/.agent/context/repomap"
  local current_changed_json='[]'
  current_changed_json=$(_coordination_collect_changed_src_files_json)
  local current_head_sha=""
  current_head_sha=$(_coordination_current_head_sha)
  local current_changed_count=0
  current_changed_count=$(jq 'length' <<< "$current_changed_json" 2>/dev/null || echo "0")

  if [[ ! -f "$freshness_file" ]]; then
    if [[ "$current_changed_count" -eq 0 ]]; then
      jq -nc \
        --arg freshness_file "$freshness_file" \
        --arg repomap_dir "$repomap_dir" \
        --arg current_head_sha "$current_head_sha" \
        --argjson current_changed_src_files "$current_changed_json" \
        '{
          fresh: true,
          summary: "fresh",
          freshness_file: $freshness_file,
          repomap_dir: $repomap_dir,
          current_head_sha: $current_head_sha,
          current_changed_src_files: $current_changed_src_files,
          recorded_changed_src_files: [],
          committed_src_files_since_sync: [],
          deleted_src_files_since_sync: [],
          newer_src_files_since_sync: [],
          reasons: []
        }'
      return 0
    fi

    jq -nc \
      --arg freshness_file "$freshness_file" \
      --arg repomap_dir "$repomap_dir" \
      --arg current_head_sha "$current_head_sha" \
      --argjson current_changed_src_files "$current_changed_json" \
      '{
        fresh: false,
        summary: "freshness artifact missing",
        freshness_file: $freshness_file,
        repomap_dir: $repomap_dir,
        current_head_sha: $current_head_sha,
        current_changed_src_files: $current_changed_src_files,
        recorded_changed_src_files: [],
        committed_src_files_since_sync: [],
        deleted_src_files_since_sync: [],
        newer_src_files_since_sync: [],
        reasons: ["freshness artifact missing"]
      }'
    return 0
  fi

  local freshness_json=""
  freshness_json="$(cat "$freshness_file" 2>/dev/null || true)"
  if ! jq -e '
    type == "object"
    and (.synced_at | type == "string" and length > 0)
    and (.head_sha | type == "string")
    and (.changed_src_files | type == "array")
    and ((.changed_src_files // []) | all(.[]?; type == "string"))
    and (.repomap_dir | type == "string" and length > 0)
  ' >/dev/null 2>&1 <<< "$freshness_json"; then
    jq -nc \
      --arg freshness_file "$freshness_file" \
      --arg repomap_dir "$repomap_dir" \
      --arg current_head_sha "$current_head_sha" \
      --argjson current_changed_src_files "$current_changed_json" \
      '{
        fresh: false,
        summary: "freshness artifact invalid",
        freshness_file: $freshness_file,
        repomap_dir: $repomap_dir,
        current_head_sha: $current_head_sha,
        current_changed_src_files: $current_changed_src_files,
        recorded_changed_src_files: [],
        committed_src_files_since_sync: [],
        deleted_src_files_since_sync: [],
        newer_src_files_since_sync: [],
        reasons: ["freshness artifact invalid"]
      }'
    return 0
  fi

  local synced_at=""
  synced_at="$(jq -r '.synced_at // empty' <<< "$freshness_json" 2>/dev/null || true)"
  local recorded_head_sha=""
  recorded_head_sha="$(jq -r '.head_sha // empty' <<< "$freshness_json" 2>/dev/null || true)"
  local recorded_repomap_dir=""
  recorded_repomap_dir="$(jq -r '.repomap_dir // empty' <<< "$freshness_json" 2>/dev/null || true)"
  local recorded_changed_json='[]'
  recorded_changed_json=$(_coordination_normalize_src_files_json "$(jq -c '.changed_src_files // []' <<< "$freshness_json" 2>/dev/null || echo '[]')")

  local reasons_tmp
  reasons_tmp=$(create_temp_file "coord_src_sync_reasons")
  : > "$reasons_tmp"

  if [[ "$recorded_repomap_dir" != "$repomap_dir" ]]; then
    printf '%s\n' "repomap_dir mismatch" >> "$reasons_tmp"
  fi

  if [[ "$current_changed_json" != "$recorded_changed_json" ]]; then
    printf '%s\n' "changed_src_files drifted after sync" >> "$reasons_tmp"
  fi

  local committed_src_json='[]'
  if [[ -n "$recorded_head_sha" && -n "$current_head_sha" && "$recorded_head_sha" != "$current_head_sha" ]]; then
    if git -C "$REPO_ROOT" rev-parse --verify "${recorded_head_sha}^{commit}" >/dev/null 2>&1 \
      && git -C "$REPO_ROOT" rev-parse --verify "${current_head_sha}^{commit}" >/dev/null 2>&1; then
      committed_src_json=$(_coordination_git_diff_src_files_between_json "$recorded_head_sha" "$current_head_sha")
      if jq -e 'length > 0' >/dev/null 2>&1 <<< "$committed_src_json"; then
        printf '%s\n' "HEAD advanced with committed src/** delta" >> "$reasons_tmp"
      fi
    else
      printf '%s\n' "freshness artifact head_sha is invalid" >> "$reasons_tmp"
    fi
  fi

  local deleted_src_json='[]'
  deleted_src_json=$(_coordination_missing_src_files_json "$current_changed_json")
  if jq -e 'length > 0' >/dev/null 2>&1 <<< "$deleted_src_json"; then
    printf '%s\n' "src/** paths were deleted after last sync" >> "$reasons_tmp"
  fi

  local newer_src_json='[]'
  local sync_epoch=0
  sync_epoch=$(_timestamp_to_epoch "$synced_at")
  if [[ "$sync_epoch" -le 0 ]]; then
    printf '%s\n' "synced_at timestamp is invalid" >> "$reasons_tmp"
  else
    newer_src_json=$(_coordination_src_files_newer_than_sync_json "$synced_at" "$current_changed_json")
    if jq -e 'length > 0' >/dev/null 2>&1 <<< "$newer_src_json"; then
      printf '%s\n' "src/** files changed after last sync" >> "$reasons_tmp"
    fi
  fi

  local reasons_json='[]'
  if [[ -s "$reasons_tmp" ]]; then
    reasons_json=$(jq -R . "$reasons_tmp" | jq -cs '
      map(select(type == "string" and length > 0))
      | unique
    ')
  fi
  rm -f "$reasons_tmp" 2>/dev/null || true

  jq -nc \
    --arg freshness_file "$freshness_file" \
    --arg repomap_dir "$repomap_dir" \
    --arg synced_at "$synced_at" \
    --arg recorded_head_sha "$recorded_head_sha" \
    --arg current_head_sha "$current_head_sha" \
    --argjson current_changed_src_files "$current_changed_json" \
    --argjson recorded_changed_src_files "$recorded_changed_json" \
    --argjson committed_src_files_since_sync "$committed_src_json" \
    --argjson deleted_src_files_since_sync "$deleted_src_json" \
    --argjson newer_src_files_since_sync "$newer_src_json" \
    --argjson reasons "$reasons_json" \
    '{
      fresh: (($reasons | length) == 0),
      summary: (if ($reasons | length) == 0 then "fresh" else ($reasons | join("; ")) end),
      freshness_file: $freshness_file,
      repomap_dir: $repomap_dir,
      synced_at: $synced_at,
      recorded_head_sha: $recorded_head_sha,
      current_head_sha: $current_head_sha,
      current_changed_src_files: $current_changed_src_files,
      recorded_changed_src_files: $recorded_changed_src_files,
      committed_src_files_since_sync: $committed_src_files_since_sync,
      deleted_src_files_since_sync: $deleted_src_files_since_sync,
      newer_src_files_since_sync: $newer_src_files_since_sync,
      reasons: $reasons
    }'
}

_coordination_require_src_sync_freshness() {
  local phase="${1:-}"
  local boundary="${2:-completion}"
  local status_json='{}'

  if ! status_json=$(_coordination_src_sync_freshness_status); then
    status_json=$(jq -nc --arg file "$SRC_SYNC_FRESHNESS_FILE" '
      {
        fresh: false,
        summary: "freshness status check failed",
        freshness_file: $file,
        reasons: ["freshness status check failed"]
      }')
  fi

  if printf '%s\n' "$status_json" | jq -e '.fresh == true' >/dev/null 2>&1; then
    return 0
  fi

  local summary=""
  summary="$(printf '%s\n' "$status_json" | jq -r '.summary // "product-surface freshness stale"' 2>/dev/null || true)"
  local message="product-surface freshness stale before ${boundary}: ${summary}. See: $SRC_SYNC_FRESHNESS_FILE"

  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    state_set_error "SRC_SYNC_FRESHNESS_BLOCK" "$message" "$phase"
    state_save
  fi

  die "$message"
}

# context_analysis 呼び出しラッパー（source失敗時はサブプロセスへフォールバック）
_coordination_context_update_changed_only() {
  if declare -F context_update >/dev/null 2>&1; then
    context_update --changed-only
  else
    bash "$LIB_DIR/context_analysis.sh" update --changed-only
  fi
}

_coordination_context_detect_deletions() {
  if declare -F context_detect_deletions >/dev/null 2>&1; then
    context_detect_deletions
  else
    bash "$LIB_DIR/context_analysis.sh" detect-deletions
  fi
}

_coordination_preflight_check() {
  if declare -F preflight_check >/dev/null 2>&1; then
    preflight_check "$@"
  else
    # preflight_check は CLI サブコマンド未公開のため、サブプロセスで source 実行
    bash -c 'set -euo pipefail; source "$1"; shift; preflight_check "$@"' _ "$LIB_DIR/context_analysis.sh" "$@"
  fi
}

_coordination_preflight_contract_is_valid() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 1

  jq -e '
    type == "object"
    and (
      (.verdict // "") == "PASS"
      or (.verdict // "") == "WARN"
      or (.verdict // "") == "BLOCK"
    )
  ' >/dev/null 2>&1 <<< "$payload"
}

_coordination_resolve_semantic_project_id() {
  local resolver="$REPO_ROOT/scripts/resolve-semantic-project-id.sh"
  local project_id=""
  [[ -x "$resolver" ]] || return 1

  if project_id=$("$resolver" --repo-root "$REPO_ROOT" --print 2>/dev/null); then
    project_id="$(_coordination_normalize_semantic_project_id_value "$project_id")"
    if [[ -n "$project_id" ]]; then
      printf '%s\n' "$project_id"
      return 0
    fi
  fi

  return 1
}

_coordination_normalize_semantic_project_id_value() {
  local project_id="${1:-}"
  printf '%s' "$project_id" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'
}

_coordination_validate_semantic_project_id_value() {
  local project_id="${1:-}"
  local source_label="${2:-coordination authoritative}"
  local reason=""
  project_id="$(_coordination_normalize_semantic_project_id_value "$project_id")"

  if [[ -z "$project_id" ]]; then
    reason="${source_label} semantic project_id is unavailable"
  elif [[ "$project_id" == "agent_base" ]]; then
    reason="${source_label} legacy project_id 'agent_base' is not allowed on authoritative registry mutation paths"
  elif [[ ! "$project_id" =~ ^[A-Za-z0-9_-]{1,64}$ ]]; then
    reason="${source_label} invalid semantic project_id '$project_id'"
  fi

  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason" >&2
    log_error "$reason"
    return 1
  fi

  printf '%s\n' "$project_id"
}

_coordination_require_authoritative_project_id() {
  local project_id=""
  if ! project_id="$(_coordination_resolve_semantic_project_id 2>/dev/null || true)"; then
    :
  fi
  _coordination_validate_semantic_project_id_value "$project_id" "coordination authoritative"
}

_coordination_build_sem_preflight_payload() {
  local task_id="$1"
  local scope_json="${2:-[]}"
  local proposed_components_json="${3:-[]}"
  local deleted_paths_json="${4:-[]}"
  local removed_symbols_json="${5:-[]}"
  local move_candidates_json="${6:-[]}"
  local project_id="${7:-}"

  jq -nc \
    --arg task_id "$task_id" \
    --arg project_id "$project_id" \
    --argjson scope "$scope_json" \
    --argjson proposed_components "$proposed_components_json" \
    --argjson deleted_paths "$deleted_paths_json" \
    --argjson removed_symbols "$removed_symbols_json" \
    --argjson move_candidates "$move_candidates_json" \
    '{
      task_id: $task_id,
      scope: $scope,
      proposed_components: $proposed_components,
      deleted_paths: $deleted_paths,
      removed_symbols: $removed_symbols,
      move_candidates: $move_candidates
    } + (
      if ($project_id | length) > 0 then
        {project_id: $project_id}
      else
        {}
      end
    )'
}

_coordination_compact_failure_reason() {
  local reason="${1:-preflight failure}"
  reason="$(printf '%s' "$reason" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')"
  if [[ ${#reason} -gt 220 ]]; then
    reason="${reason:0:217}..."
  fi
  printf '%s\n' "$reason"
}

_coordination_fail_closed_preflight_json() {
  local task_id="$1"
  local scope_json="${2:-[]}"
  local proposed_components_json="${3:-[]}"
  local deleted_paths_json="${4:-[]}"
  local removed_symbols_json="${5:-[]}"
  local move_candidates_json="${6:-[]}"
  local failure_reason="${7:-preflight failure}"

  local compact_reason=""
  compact_reason=$(_coordination_compact_failure_reason "$failure_reason")

  if declare -F mcp_or_fallback >/dev/null 2>&1; then
    local project_id=""
    project_id="$(_coordination_require_authoritative_project_id 2>/dev/null || true)"

    local fallback_payload=""
    local fallback_json=""
    fallback_payload=$(_coordination_build_sem_preflight_payload \
      "$task_id" \
      "$scope_json" \
      "$proposed_components_json" \
      "$deleted_paths_json" \
      "$removed_symbols_json" \
      "$move_candidates_json" \
      "$project_id")

    if fallback_json=$(mcp_or_fallback "sem.preflight" "$fallback_payload" 2>/dev/null); then
      if _coordination_preflight_contract_is_valid "$fallback_json" \
        && jq -e '.verdict == "BLOCK"' >/dev/null 2>&1 <<< "$fallback_json"; then
        jq -c --arg reason "$compact_reason" '. + {coordination_failure_reason: $reason}' <<< "$fallback_json"
        return 0
      fi
    fi
  fi

  jq -nc \
    --arg reason "$compact_reason" \
    '{
      verdict: "BLOCK",
      conflicts: [
        {
          semantic_id: "sem.preflight",
          reason: ("blocked: " + $reason)
        }
      ],
      delete_impacts_summary: "authority:blocked fallback:disabled reason:preflight_failure",
      capsule: "PREFLIGHT=BLOCK authority=coordination fallback=disabled reason=preflight_failure",
      coordination_failure_reason: $reason
    }'
}

_coordination_context_delta() {
  if declare -F context_delta >/dev/null 2>&1; then
    context_delta "$@"
  else
    bash "$LIB_DIR/context_analysis.sh" delta "$@"
  fi
}

# Layer 1+2 事前準備
# Usage: prepare_coordination_context <tmpdir> <phase> <task_name>
prepare_coordination_context() {
  local tmpdir="$1"
  local phase="$2"
  local task_name="$3"
  local task_id
  task_id=$(_coordination_resolve_task_id "$task_name")

  log_info "Preparing coordination context (task_id=$task_id, phase=$phase)"

  if [[ "$coordination_context_unavailable" == "true" ]]; then
    local preflight_file="$tmpdir/${phase}_coord_preflight.json"
    local preflight_json=""
    preflight_json=$(_coordination_fail_closed_preflight_json \
      "$task_id" \
      '[]' \
      '[]' \
      '[]' \
      '[]' \
      '[]' \
      "$coordination_context_unavailable_reason")
    printf '%s\n' "$preflight_json" > "$preflight_file"
    state_set_error "PREFLIGHT_BLOCK" "Coordination preflight failed closed. See: $preflight_file" "$phase"
    state_save
    die "Coordination preflight failed closed. See: $preflight_file"
  fi

  if [[ "$run_context_analysis" == "true" ]]; then
    local scope_json proposed_components_json deleted_paths_json removed_symbols_json move_candidates_json
    scope_json=$(_coordination_collect_changed_files_json)
    proposed_components_json='[]'
    deleted_paths_json='[]'
    removed_symbols_json='[]'
    move_candidates_json='[]'

    local project_id=""
    local project_id_error_file=""
    project_id_error_file=$(create_temp_file "coord_prepare_project_id_err")
    local preflight_file="$tmpdir/${phase}_coord_preflight.json"
    if ! project_id="$(_coordination_require_authoritative_project_id 2> "$project_id_error_file")"; then
      local failure_reason="authoritative semantic project_id unavailable"
      if [[ -s "$project_id_error_file" ]]; then
        local project_id_error_text=""
        project_id_error_text="$(cat "$project_id_error_file" 2>/dev/null || true)"
        if [[ -n "$project_id_error_text" ]]; then
          failure_reason="$project_id_error_text"
        fi
      fi
      local preflight_json=""
      preflight_json=$(_coordination_fail_closed_preflight_json \
        "$task_id" \
        "$scope_json" \
        "$proposed_components_json" \
        "$deleted_paths_json" \
        "$removed_symbols_json" \
        "$move_candidates_json" \
        "$failure_reason")
      printf '%s\n' "$preflight_json" > "$preflight_file"
      rm -f "$project_id_error_file" 2>/dev/null || true
      state_set_error "PREFLIGHT_BLOCK" "Coordination preflight failed closed before preflight_input artifact due to authoritative project_id block. See: $preflight_file" "$phase"
      state_save
      die "Coordination preflight failed closed before preflight_input artifact due to authoritative project_id block. See: $preflight_file"
    fi
    rm -f "$project_id_error_file" 2>/dev/null || true

    local repomap_json=""
    if repomap_json=$(_coordination_context_update_changed_only 2>/dev/null); then
      printf '%s\n' "$repomap_json" > "$tmpdir/${phase}_coord_repromap.json"
    else
      log_warn "context_update --changed-only failed: continuing with existing RepoMap"
    fi

    local deletions_json=""
    if deletions_json=$(_coordination_context_detect_deletions 2>/dev/null); then
      deleted_paths_json=$(jq -c '.deleted_paths // []' <<< "$deletions_json" 2>/dev/null || echo '[]')
      removed_symbols_json=$(jq -c '.removed_symbols // []' <<< "$deletions_json" 2>/dev/null || echo '[]')
      move_candidates_json=$(jq -c '.move_candidates // []' <<< "$deletions_json" 2>/dev/null || echo '[]')
    fi

    _coordination_require_src_sync_freshness "$phase" "prepare_coordination_context"

    local preflight_input_json=""
    preflight_input_json=$(_coordination_build_sem_preflight_payload \
      "$task_id" \
      "$scope_json" \
      "$proposed_components_json" \
      "$deleted_paths_json" \
      "$removed_symbols_json" \
      "$move_candidates_json" \
      "$project_id")
    printf '%s\n' "$preflight_input_json" > "$tmpdir/${phase}_coord_preflight_input.json"

    local preflight_json=""
    local preflight_error_file="$tmpdir/${phase}_coord_preflight.stderr"
    if preflight_json=$(_coordination_preflight_check "$task_id" "$scope_json" "$proposed_components_json" "$deleted_paths_json" "$removed_symbols_json" "$move_candidates_json" 2> "$preflight_error_file"); then
      if ! _coordination_preflight_contract_is_valid "$preflight_json"; then
        preflight_json=$(_coordination_fail_closed_preflight_json \
          "$task_id" \
          "$scope_json" \
          "$proposed_components_json" \
          "$deleted_paths_json" \
          "$removed_symbols_json" \
          "$move_candidates_json" \
          "preflight_check returned invalid contract")
        printf '%s\n' "$preflight_json" > "$preflight_file"
        state_set_error "PREFLIGHT_BLOCK" "Coordination preflight failed closed due to invalid contract. See: $preflight_file" "$phase"
        state_save
        die "Coordination preflight failed closed due to invalid contract. See: $preflight_file"
      fi

      printf '%s\n' "$preflight_json" > "$preflight_file"

      local verdict
      verdict=$(jq -r '.verdict' <<< "$preflight_json" 2>/dev/null || echo "BLOCK")
      case "$verdict" in
        BLOCK)
          state_set_error "PREFLIGHT_BLOCK" "Coordination preflight blocked. See: $preflight_file" "$phase"
          state_save
          die "Coordination preflight BLOCK. See: $preflight_file"
          ;;
        WARN)
          log_warn "Coordination preflight WARN. See: $preflight_file"
          ;;
        *)
          log_info "Coordination preflight PASS"
          ;;
      esac
    else
      local preflight_rc=$?
      local failure_reason="preflight_check failed (rc=$preflight_rc)"
      if [[ -s "$preflight_error_file" ]]; then
        local preflight_stderr=""
        preflight_stderr="$(cat "$preflight_error_file" 2>/dev/null || true)"
        if [[ -n "$preflight_stderr" ]]; then
          failure_reason="$failure_reason: $preflight_stderr"
        fi
      fi

      preflight_json=$(_coordination_fail_closed_preflight_json \
        "$task_id" \
        "$scope_json" \
        "$proposed_components_json" \
        "$deleted_paths_json" \
        "$removed_symbols_json" \
        "$move_candidates_json" \
        "$failure_reason")
      printf '%s\n' "$preflight_json" > "$preflight_file"
      state_set_error "PREFLIGHT_BLOCK" "Coordination preflight failed closed. See: $preflight_file" "$phase"
      state_save
      die "Coordination preflight failed closed. See: $preflight_file"
    fi
    rm -f "$preflight_error_file" 2>/dev/null || true
  fi

  if [[ -f "$CONTEXT_CAPSULE_SCRIPT" ]]; then
    local capsule_json=""
    if capsule_json=$(bash "$CONTEXT_CAPSULE_SCRIPT" build "$task_id" "coder" --budget 220 2>/dev/null); then
      printf '%s\n' "$capsule_json" > "$tmpdir/${phase}_coord_capsule.json"
    else
      log_warn "capsule_build failed: proceeding without coordination capsule"
    fi
  fi
}

_coordination_registry_delta_contract_is_valid() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 1

  local authoritative_summary_json=""
  authoritative_summary_json="$(_coordination_registry_mutation_summary_json "$payload")" || return 1

  jq -e --argjson authoritative_summary "$authoritative_summary_json" '
    def valid_upsert_status:
      . == "active"
      or . == "inactive"
      or . == "incomplete"
      or . == "buggy"
      or . == "deprecated";
    def valid_mutable_status:
      . == "active"
      or . == "inactive"
      or . == "incomplete"
      or . == "buggy"
      or . == "deprecated";

    type == "object"
    and (.task_id | type == "string")
    and (.phase | type == "string")
    and (
      ((.iteration | type) == "number")
      or ((.iteration | type) == "string")
    )
    and ((.scope // []) | type == "array")
    and ((.changed_files // []) | type == "array")
    and ((.deleted_paths // []) | type == "array")
    and ((.move_candidates // []) | type == "array")
    and (.summary | type == "object")
    and ((.summary.upserts | type) == "number")
    and ((.summary.set_status | type) == "number")
    and ((.summary.deletes | type) == "number")
    and (.summary.upserts == $authoritative_summary.upserts)
    and (.summary.set_status == $authoritative_summary.set_status)
    and (.summary.deletes == $authoritative_summary.deletes)
    and (.mutations | type == "object")
    and ((.mutations.upserts // []) | type == "array")
    and ((.mutations.set_status // []) | type == "array")
    and ((.mutations.deletes // []) | type == "array")
    and (
      (.mutations.upserts // [])
      | all(
          type == "object"
          and (has("project_id") | not)
          and (.semantic_id | type == "string" and length > 0)
          and (.name | type == "string" and length > 0)
          and (.module | type == "string" and length > 0)
          and (.file_path | type == "string" and length > 0)
          and (.kind | type == "string" and length > 0)
          and ((.exports // []) | type == "array")
          and ((.imports // []) | type == "array")
          and (((.status // "active") | type) == "string")
          and (((.status // "active") | ascii_downcase) | valid_upsert_status)
        )
    )
    and (
      (.mutations.set_status // [])
      | all(
          type == "object"
          and (has("project_id") | not)
          and (.semantic_id | type == "string" and length > 0)
          and (.status | type == "string" and ((ascii_downcase) | valid_mutable_status))
        )
    )
    and (
      (.mutations.deletes // [])
      | all(
          type == "object"
          and (has("project_id") | not)
          and (.semantic_id | type == "string" and length > 0)
        )
    )
  ' >/dev/null 2>&1 <<< "$payload"
}

_coordination_registry_delta_payload_has_summary_mismatch() {
  local payload="${1:-}"
  local authoritative_summary_json="${2:-}"
  [[ -n "$payload" && -n "$authoritative_summary_json" ]] || return 1

  jq -e --argjson authoritative_summary "$authoritative_summary_json" '
    type == "object"
    and (.summary | type == "object")
    and ((.summary.upserts | type) == "number")
    and ((.summary.set_status | type) == "number")
    and ((.summary.deletes | type) == "number")
    and (
      (.summary.upserts != $authoritative_summary.upserts)
      or (.summary.set_status != $authoritative_summary.set_status)
      or (.summary.deletes != $authoritative_summary.deletes)
    )
  ' >/dev/null 2>&1 <<< "$payload"
}

_coordination_registry_mutation_summary_json() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || return 1

  jq -c '
    if type != "object" then
      error("coordination registry mutation payload must be an object")
    elif ((.mutations // null) | type) != "object" then
      error("coordination registry mutation payload missing mutations object")
    elif ((.mutations.upserts // []) | type) != "array" then
      error("coordination registry mutation upserts must be an array")
    elif ((.mutations.set_status // []) | type) != "array" then
      error("coordination registry mutation set_status must be an array")
    elif ((.mutations.deletes // []) | type) != "array" then
      error("coordination registry mutation deletes must be an array")
    else
      {
        upserts: ((.mutations.upserts // []) | length),
        set_status: ((.mutations.set_status // []) | length),
        deletes: ((.mutations.deletes // []) | length)
      }
    end
  ' <<< "$payload" 2>/dev/null
}

_coordination_registry_mutation_summary_json_best_effort() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || payload='{}'

  jq -c '
    if type != "object" then
      {upserts: 0, set_status: 0, deletes: 0}
    else
      {
        upserts: (
          if ((.mutations // null) | type) == "object" and ((.mutations.upserts // []) | type) == "array" then
            (.mutations.upserts | length)
          else
            0
          end
        ),
        set_status: (
          if ((.mutations // null) | type) == "object" and ((.mutations.set_status // []) | type) == "array" then
            (.mutations.set_status | length)
          else
            0
          end
        ),
        deletes: (
          if ((.mutations // null) | type) == "object" and ((.mutations.deletes // []) | type) == "array" then
            (.mutations.deletes | length)
          else
            0
          end
        )
      }
    end
  ' <<< "$payload" 2>/dev/null || printf '%s\n' '{"upserts":0,"set_status":0,"deletes":0}'
}

_coordination_write_error_artifact() {
  local output_file="${1:-}"
  local reason="${2:-coordination mutation failed}"
  local tool_name="${3:-}"

  [[ -n "$output_file" ]] || return 0

  jq -nc \
    --arg reason "$reason" \
    --arg tool "$tool_name" \
    '(
      {error:$reason}
      + (if ($tool | length) > 0 then {tool:$tool} else {} end)
    )' > "$output_file" 2>/dev/null || true
}

_coordination_require_json_object_file() {
  local file_path="${1:-}"
  local label="${2:-artifact}"

  if [[ -z "$file_path" || ! -f "$file_path" ]]; then
    local missing_reason="coordination ${label} missing: ${file_path:-<empty>}"
    printf '%s\n' "$missing_reason" >&2
    log_error "$missing_reason"
    return 1
  fi

  if ! jq -e 'type == "object"' "$file_path" >/dev/null 2>&1; then
    local invalid_reason="coordination ${label} invalid JSON object: $file_path"
    printf '%s\n' "$invalid_reason" >&2
    log_error "$invalid_reason"
    return 1
  fi

  return 0
}

_coordination_validate_registry_preflight_input_shape() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || payload='{}'

  local reason=""
  if ! reason=$(jq -r '
    def normalize_path:
      tostring
      | gsub("^\\./"; "")
      | gsub("^[[:space:]]+"; "")
      | gsub("[[:space:]]+$"; "");
    def valid_move_candidate:
      type == "object"
      and ((has("old_path") | not) or (.old_path | type == "string"))
      and ((has("from") | not) or (.from | type == "string"))
      and ((has("new_path") | not) or (.new_path | type == "string"))
      and ((has("to") | not) or (.to | type == "string"))
      and (((.old_path // .from // "") | normalize_path | length) > 0)
      and (((.new_path // .to // "") | normalize_path | length) > 0);

    if type != "object" then
      "coordination preflight_input invalid JSON object"
    elif (has("project_id") | not) then
      "coordination preflight_input missing project_id: required for authoritative registry mutation"
    elif (has("project_id") and (.project_id | type) != "string") then
      "coordination preflight_input invalid project_id: expected string"
    elif (has("scope") and (.scope | type) != "array") then
      "coordination preflight_input invalid scope: expected array"
    elif (has("scope") and any(.scope[]?; type != "string")) then
      "coordination preflight_input invalid scope entries: expected strings"
    elif (has("deleted_paths") and (.deleted_paths | type) != "array") then
      "coordination preflight_input invalid deleted_paths: expected array"
    elif (has("deleted_paths") and any(.deleted_paths[]?; type != "string")) then
      "coordination preflight_input invalid deleted_paths entries: expected strings"
    elif (has("removed_symbols") and (.removed_symbols | type) != "array") then
      "coordination preflight_input invalid removed_symbols: expected array"
    elif (has("removed_symbols") and any(.removed_symbols[]?; type != "string")) then
      "coordination preflight_input invalid removed_symbols entries: expected strings"
    elif (has("move_candidates") and (.move_candidates | type) != "array") then
      "coordination preflight_input invalid move_candidates: expected array"
    elif (has("move_candidates") and any(.move_candidates[]?; valid_move_candidate | not)) then
      "coordination preflight_input invalid move_candidates entries: expected old_path/from and new_path/to non-empty strings"
    else
      empty
    end
  ' <<< "$payload" 2>/dev/null); then
    reason="coordination preflight_input invalid JSON object"
  fi

  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason" >&2
    log_error "$reason"
    return 1
  fi

  local preflight_project_id=""
  preflight_project_id="$(jq -r '.project_id' <<< "$payload" 2>/dev/null || true)"
  _coordination_validate_semantic_project_id_value "$preflight_project_id" "coordination preflight_input" >/dev/null || return 1

  return 0
}

_coordination_validate_registry_delta_input_shape() {
  local payload="${1:-}"
  [[ -n "$payload" ]] || payload='{}'

  local reason=""
  if ! reason=$(jq -r '
    def valid_registry_mutation_status:
      . == "active"
      or . == "inactive"
      or . == "incomplete"
      or . == "buggy"
      or . == "deprecated";
    def valid_changed_symbol:
      . as $entry
      | (($entry.semantic_id? | strings | select(length > 0)) // ($entry.logical_id? | strings | select(length > 0)) // "") as $id
      | (($entry.name? | strings | select(length > 0)) // ($entry.symbol? | strings | select(length > 0)) // "") as $name
      | (($entry.module? | strings | select(length > 0)) // "") as $module
      | (($entry.file_path? | strings | select(length > 0)) // ($entry.file? | strings | select(length > 0)) // ($entry.path? | strings | select(length > 0)) // "") as $file_path
      | (
          ((has("semantic_id") | not) or (.semantic_id | type == "string"))
          and ((has("logical_id") | not) or (.logical_id | type == "string"))
          and ((has("name") | not) or (.name | type == "string"))
          and ((has("symbol") | not) or (.symbol | type == "string"))
          and ((has("module") | not) or (.module | type == "string"))
          and ((has("file_path") | not) or (.file_path | type == "string"))
          and ((has("file") | not) or (.file | type == "string"))
          and ((has("path") | not) or (.path | type == "string"))
          and ($file_path | length > 0)
          and (
            ($id | length > 0)
            or (($module | length > 0) and ($name | length > 0))
          )
          and (
            ($name | length > 0)
            or ($id | contains(":"))
          )
        );

    if type != "object" then
      "coordination delta_input invalid JSON object"
    elif (has("changed_symbols") and (.changed_symbols | type) != "array") then
      "coordination delta_input invalid changed_symbols: expected array"
    elif (has("changed_symbols") and any(.changed_symbols[]?; type != "object")) then
      "coordination delta_input invalid changed_symbols entries: expected objects"
    elif (has("changed_symbols") and any(.changed_symbols[]?; valid_changed_symbol | not)) then
      "coordination delta_input invalid changed_symbols entries: unable to normalize deterministic component"
    elif (
      has("changed_symbols")
      and any(
        .changed_symbols[]?;
        (
          has("status")
          and ((.status | type) != "string" or ((.status | ascii_downcase) | valid_registry_mutation_status | not))
        ) or (
          has("_status")
          and ((._status | type) != "string" or ((._status | ascii_downcase) | valid_registry_mutation_status | not))
        )
      )
    ) then
      "coordination delta_input invalid changed_symbols status: expected active|inactive|incomplete|buggy|deprecated"
    elif (has("changed_files") and (.changed_files | type) != "array") then
      "coordination delta_input invalid changed_files: expected array"
    elif (has("changed_files") and any(.changed_files[]?; type != "string")) then
      "coordination delta_input invalid changed_files entries: expected strings"
    else
      empty
    end
  ' <<< "$payload" 2>/dev/null); then
    reason="coordination delta_input invalid JSON object"
  fi

  if [[ -n "$reason" ]]; then
    printf '%s\n' "$reason" >&2
    log_error "$reason"
    return 1
  fi

  return 0
}

_coordination_refresh_finalize_preflight_input() {
  local base_preflight_file="${1:-}"
  local output_file="${2:-}"

  _coordination_require_json_object_file "$base_preflight_file" "preflight_input" || return 1
  [[ -n "$output_file" ]] || return 1

  local base_preflight_json=""
  base_preflight_json="$(cat "$base_preflight_file" 2>/dev/null)" || return 1
  _coordination_validate_registry_preflight_input_shape "$base_preflight_json" || return 1

  local deletions_json='{}'
  if ! deletions_json=$(_coordination_context_detect_deletions 2>/dev/null); then
    log_error "coordination finalize deletion refresh failed"
    return 1
  fi

  if ! jq -e '
    def normalize_path:
      tostring
      | gsub("^\\./"; "")
      | gsub("^[[:space:]]+"; "")
      | gsub("[[:space:]]+$"; "");
    def valid_move_candidate:
      type == "object"
      and ((has("old_path") | not) or (.old_path | type == "string"))
      and ((has("from") | not) or (.from | type == "string"))
      and ((has("new_path") | not) or (.new_path | type == "string"))
      and ((has("to") | not) or (.to | type == "string"))
      and (((.old_path // .from // "") | normalize_path | length) > 0)
      and (((.new_path // .to // "") | normalize_path | length) > 0);

    type == "object"
    and ((.deleted_paths // []) | type == "array")
    and ((.deleted_paths // []) | all(.[]?; type == "string"))
    and ((.removed_symbols // []) | type == "array")
    and ((.removed_symbols // []) | all(.[]?; type == "string"))
    and ((.move_candidates // []) | type == "array")
    and ((.move_candidates // []) | all(.[]?; valid_move_candidate))
  ' >/dev/null 2>&1 <<< "$deletions_json"; then
    log_error "coordination finalize deletion refresh returned invalid contract"
    return 1
  fi

  jq -nc \
    --slurpfile base "$base_preflight_file" \
    --argjson refresh "$deletions_json" \
    '
      ($base[0] // {}) as $preflight
      | $preflight
      | .deleted_paths = (
          (($preflight.deleted_paths // []) + ($refresh.deleted_paths // []))
          | map(select(type == "string" and length > 0) | gsub("^\\./"; ""))
          | unique
        )
      | .removed_symbols = (
          (($preflight.removed_symbols // []) + ($refresh.removed_symbols // []))
          | map(select(type == "string" and length > 0))
          | unique
        )
      | .move_candidates = (
          (($preflight.move_candidates // []) + ($refresh.move_candidates // []))
          | map(
              select(type == "object")
              | {
                  old_path: ((.old_path // .from // "") | tostring | gsub("^\\./"; "")),
                  new_path: ((.new_path // .to // "") | tostring | gsub("^\\./"; ""))
                }
              | select((.old_path | length) > 0 and (.new_path | length) > 0)
            )
          | unique_by(.old_path + "|" + .new_path)
        )
    ' > "$output_file"
}

_coordination_build_registry_delta_payload() {
  local task_id="$1"
  local phase="$2"
  local iteration="$3"
  local preflight_input_json="${4:-}"
  local delta_json="${5:-}"
  [[ -n "$preflight_input_json" ]] || preflight_input_json='{}'
  [[ -n "$delta_json" ]] || delta_json='{}'

  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$preflight_input_json"; then
    log_error "coordination preflight input invalid JSON object"
    return 1
  fi
  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<< "$delta_json"; then
    log_error "coordination delta input invalid JSON object"
    return 1
  fi
  _coordination_validate_registry_preflight_input_shape "$preflight_input_json" || return 1
  _coordination_validate_registry_delta_input_shape "$delta_json" || return 1

  local preflight_project_id=""
  if jq -e 'has("project_id")' >/dev/null 2>&1 <<< "$preflight_input_json"; then
    preflight_project_id="$(jq -r '.project_id' <<< "$preflight_input_json" 2>/dev/null || true)"
    preflight_project_id="$(_coordination_validate_semantic_project_id_value "$preflight_project_id" "coordination preflight_input")" || return 1
  fi
  local project_id=""
  project_id="$(_coordination_require_authoritative_project_id)" || return 1
  if [[ -n "$preflight_project_id" && "$preflight_project_id" != "$project_id" ]]; then
    local project_id_reason="coordination authoritative project_id mismatch: preflight=$preflight_project_id resolved=$project_id"
    printf '%s\n' "$project_id_reason" >&2
    log_error "$project_id_reason"
    return 1
  fi
  local scope_json='[]'
  if ! scope_json=$(jq -c '(.scope // []) | map(select(type == "string" and length > 0)) | map(gsub("^\\./"; "")) | unique' <<< "$preflight_input_json" 2>/dev/null); then
    scope_json='[]'
  fi

  local deleted_paths_json='[]'
  if ! deleted_paths_json=$(jq -c '(.deleted_paths // []) | map(select(type == "string" and length > 0)) | map(gsub("^\\./"; "")) | unique' <<< "$preflight_input_json" 2>/dev/null); then
    deleted_paths_json='[]'
  fi

  local move_candidates_json='[]'
  if ! move_candidates_json=$(jq -c '
    (.move_candidates // [])
    | map(
        select(type == "object")
        | {
            old_path: ((.old_path // .from // "") | tostring | gsub("^\\./"; "")),
            new_path: ((.new_path // .to // "") | tostring | gsub("^\\./"; ""))
          }
        | select((.old_path | length) > 0 and (.new_path | length) > 0)
      )
    | unique_by(.old_path + "|" + .new_path)
  ' <<< "$preflight_input_json" 2>/dev/null); then
    move_candidates_json='[]'
  fi

  local removed_symbols_json='[]'
  if ! removed_symbols_json=$(jq -c '(.removed_symbols // []) | map(select(type == "string" and length > 0)) | unique' <<< "$preflight_input_json" 2>/dev/null); then
    removed_symbols_json='[]'
  fi

  local changed_files_json='[]'
  if ! changed_files_json=$(jq -c '(.changed_files // []) | map(select(type == "string" and length > 0)) | map(gsub("^\\./"; "")) | unique' <<< "$delta_json" 2>/dev/null); then
    changed_files_json='[]'
  fi

  local normalized_components_json='[]'
  if ! normalized_components_json=$(jq -c '
    (.changed_symbols // [])
    | map(select(type == "object"))
    | map(
        .semantic_id = (
          (.semantic_id // .logical_id // (
            if ((.module // "" | tostring | length) > 0 and (.name // .symbol // "" | tostring | length) > 0) then
              ((.module | tostring) + ":" + ((.name // .symbol) | tostring))
            else
              ""
            end
          )) | tostring
        )
        | .name = ((.name // .symbol // (if (.semantic_id | contains(":")) then ((.semantic_id | split(":"))[1:] | join(":")) else "" end)) | tostring)
        | .module = ((.module // (if (.semantic_id | contains(":")) then ((.semantic_id | split(":"))[0]) else (.file_path // .file // .path // "") end)) | tostring)
        | .file_path = ((.file_path // .file // .path // "") | tostring | gsub("^\\./"; ""))
        | .kind = ((.kind // "unknown") | tostring)
        | .status = (
            ((.status // ._status // "active") | tostring | ascii_downcase) as $status
            | if ($status == "inactive" or $status == "incomplete" or $status == "buggy" or $status == "deprecated") then
                $status
              else
                "active"
              end
          )
        | .inactive_reason = (.inactive_reason // ._inactive_reason // null)
        | .security_level = (.security_level // ._security_level // null)
        | .exports = (if ((.exports // .exported // []) | type) == "array" then (.exports // .exported // []) else [] end)
        | .imports = (if ((.imports // .dependencies // []) | type) == "array" then (.imports // .dependencies // []) else [] end)
        | {semantic_id, name, module, file_path, kind, exports, imports, status, inactive_reason, security_level}
        | select((.semantic_id | length) > 0 and (.name | length) > 0 and (.module | length) > 0 and (.file_path | length) > 0)
      )
    | unique_by(.semantic_id + "|" + .file_path)
  ' <<< "$delta_json" 2>/dev/null); then
    normalized_components_json='[]'
  fi

  local upserts_json='[]'
  if ! upserts_json=$(jq -c 'map(select(.status != "deleted"))' <<< "$normalized_components_json" 2>/dev/null); then
    upserts_json='[]'
  fi

  local status_updates_json='[]'
  if ! status_updates_json=$(jq -c '
    map(
      select(.status != "active" and .status != "deleted")
      | {
          semantic_id,
          status: (
            (.status | tostring | ascii_downcase) as $status
            | if ($status == "inactive" or $status == "incomplete" or $status == "buggy" or $status == "deprecated") then
                $status
              else
                "active"
              end
          ),
          inactive_reason
        }
    )
    | unique_by(.semantic_id + "|" + .status + "|" + ((.inactive_reason // "") | tostring))
  ' <<< "$normalized_components_json" 2>/dev/null); then
    status_updates_json='[]'
  fi

  local deletes_json='[]'
  if ! deletes_json=$(jq -nc \
    --arg removed_json "$removed_symbols_json" \
    --arg components_json "$normalized_components_json" \
    '
      [
        (($removed_json | fromjson)[]? ) as $removed
        | select((((($components_json | fromjson) | map(.semantic_id)) | index($removed)) == null))
        | {
            semantic_id: $removed,
            reason: "removed symbol detected by coordination delta"
          }
      ]
    ' 2>/dev/null); then
    deletes_json='[]'
  fi

  jq -nc \
    --arg task_id "$task_id" \
    --arg phase "$phase" \
    --arg iteration "$iteration" \
    --arg project_id "$project_id" \
    --arg scope_json "$scope_json" \
    --arg changed_files_json "$changed_files_json" \
    --arg deleted_paths_json "$deleted_paths_json" \
    --arg move_candidates_json "$move_candidates_json" \
    --arg upserts_json "$upserts_json" \
    --arg status_updates_json "$status_updates_json" \
    --arg deletes_json "$deletes_json" \
    '{
      task_id: $task_id,
      phase: $phase,
      iteration: ($iteration | tonumber? // $iteration),
      scope: ($scope_json | fromjson),
      changed_files: ($changed_files_json | fromjson),
      deleted_paths: ($deleted_paths_json | fromjson),
      move_candidates: ($move_candidates_json | fromjson),
      mutations: {
        upserts: ($upserts_json | fromjson),
        set_status: ($status_updates_json | fromjson),
        deletes: ($deletes_json | fromjson)
      },
      summary: {
        upserts: (($upserts_json | fromjson) | length),
        set_status: (($status_updates_json | fromjson) | length),
        deletes: (($deletes_json | fromjson) | length)
      }
    } + (
      if ($project_id | length) > 0 then
        {project_id: $project_id}
      else
        {}
      end
    )'
}

_coordination_build_mutator_input() {
  local project_id="${1:-}"
  local field_name="${2:-}"
  local item_json="${3:-}"
  [[ -n "$item_json" ]] || item_json='{}'

  jq -nc \
    --arg project_id "$project_id" \
    --arg field_name "$field_name" \
    --arg item_json "$item_json" \
    '
      ($item_json | fromjson) as $item
      |
      (if ($project_id | length) > 0 then {project_id: $project_id} else {} end)
      + (
        if $field_name == "components" then
          {components: [$item]}
        else
          $item
        end
      )
    '
}

_coordination_collect_apply_results_json() {
  local results_file="${1:-}"

  if [[ -n "$results_file" && -s "$results_file" ]]; then
    jq -s '.' "$results_file" 2>/dev/null
  else
    printf '[]\n'
  fi
}

_coordination_build_apply_artifact_json() {
  local summary_json="${1:-}"
  local applied_json="${2:-}"
  local partial_apply="${3:-false}"
  local failing_tool="${4:-}"
  local error_reason="${5:-}"
  [[ -n "$summary_json" ]] || summary_json='{}'
  [[ -n "$applied_json" ]] || applied_json='[]'

  jq -nc \
    --argjson summary "$summary_json" \
    --argjson applied "$applied_json" \
    --arg partial_apply "$partial_apply" \
    --arg failing_tool "$failing_tool" \
    --arg error_reason "$error_reason" \
    '
      {
        summary: $summary,
        applied: $applied
      }
      + (
        if $partial_apply == "true" then
          {partial_apply: true}
        else
          {}
        end
      )
      + (
        if ($failing_tool | length) > 0 then
          {failing_tool: $failing_tool}
        else
          {}
        end
      )
      + (
        if ($error_reason | length) > 0 then
          {error: $error_reason}
        else
          {}
        end
      )
    '
}

_coordination_commit_apply_artifact() {
  local output_file="${1:-}"
  local artifact_json="${2:-}"

  [[ -n "$output_file" ]] || return 0

  local tmp_file=""
  tmp_file=$(create_temp_file "coord_registry_apply_out")
  if ! printf '%s\n' "$artifact_json" > "$tmp_file"; then
    rm -f "$tmp_file" "$output_file" 2>/dev/null || true
    log_error "coordination registry mutation apply artifact write failed"
    return 1
  fi
  if ! mv "$tmp_file" "$output_file"; then
    rm -f "$tmp_file" "$output_file" 2>/dev/null || true
    log_error "coordination registry mutation apply artifact commit failed"
    return 1
  fi

  return 0
}

_coordination_maybe_commit_partial_apply_artifact() {
  local summary_json="${1:-}"
  local results_file="${2:-}"
  local output_file="${3:-}"
  local failing_tool="${4:-}"
  local error_reason="${5:-}"

  if [[ -z "$results_file" || ! -s "$results_file" ]]; then
    return 0
  fi

  local applied_json=""
  if ! applied_json=$(_coordination_collect_apply_results_json "$results_file"); then
    log_error "coordination registry mutation aggregate invalid during partial-apply recording"
    return 1
  fi

  local artifact_json=""
  if ! artifact_json=$(_coordination_build_apply_artifact_json \
    "$summary_json" \
    "$applied_json" \
    "true" \
    "$failing_tool" \
    "$error_reason"); then
    log_error "coordination registry mutation partial-apply artifact invalid"
    return 1
  fi

  _coordination_commit_apply_artifact "$output_file" "$artifact_json"
}

_coordination_commit_apply_error_artifact() {
  local summary_json="${1:-}"
  local output_file="${2:-}"
  local failing_tool="${3:-}"
  local error_reason="${4:-coordination registry mutation blocked}"

  local artifact_json=""
  if ! artifact_json=$(_coordination_build_apply_artifact_json \
    "$summary_json" \
    '[]' \
    "false" \
    "$failing_tool" \
    "$error_reason"); then
    log_error "coordination registry mutation apply error artifact invalid"
    return 1
  fi

  _coordination_commit_apply_artifact "$output_file" "$artifact_json"
}

_coordination_build_registry_delta_payload_from_files() {
  local task_id="$1"
  local phase="$2"
  local iteration="$3"
  local preflight_file="${4:-}"
  local delta_file="${5:-}"
  _coordination_require_json_object_file "$preflight_file" "preflight_input" || return 1
  _coordination_require_json_object_file "$delta_file" "delta_input" || return 1

  local preflight_input_json=""
  local delta_json=""
  preflight_input_json="$(cat "$preflight_file" 2>/dev/null)" || return 1
  delta_json="$(cat "$delta_file" 2>/dev/null)" || return 1

  _coordination_build_registry_delta_payload \
    "$task_id" \
    "$phase" \
    "$iteration" \
    "$preflight_input_json" \
    "$delta_json"
}

_coordination_apply_registry_delta_payload() {
  local payload_json="${1:-}"
  local apply_output_file="${2:-}"
  local authoritative_summary_json=""

  authoritative_summary_json="$(_coordination_registry_mutation_summary_json_best_effort "$payload_json")"
  if ! _coordination_registry_delta_contract_is_valid "$payload_json"; then
    local apply_error_reason="coordination registry delta payload contract invalid"
    if _coordination_registry_delta_payload_has_summary_mismatch "$payload_json" "$authoritative_summary_json"; then
      apply_error_reason="coordination registry delta payload contract invalid: summary mismatch"
    fi
    _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "contract_guard" "$apply_error_reason" || return 1
    log_error "$apply_error_reason"
    return 1
  fi

  authoritative_summary_json="$(_coordination_registry_mutation_summary_json "$payload_json")" || {
    local summary_failure_reason="coordination registry mutation summary invalid"
    _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "contract_guard" "$summary_failure_reason" || return 1
    log_error "$summary_failure_reason"
    return 1
  }

  if ! declare -F mcp_or_fallback >/dev/null 2>&1; then
    rm -f "$apply_output_file" 2>/dev/null || true
    log_error "coordination registry mutation blocked: mcp_or_fallback unavailable"
    return 1
  fi

  local project_id=""
  project_id="$(_coordination_require_authoritative_project_id)" || {
    local apply_error_reason="coordination authoritative project_id guard blocked registry apply"
    _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "project_id_guard" "$apply_error_reason" || return 1
    return 1
  }
  local payload_project_id=""
  payload_project_id="$(jq -r '.project_id // empty' <<< "$payload_json" 2>/dev/null || true)"
  if [[ -z "$payload_project_id" ]]; then
    local apply_error_reason="coordination registry delta payload missing authoritative project_id"
    _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "project_id_guard" "$apply_error_reason" || return 1
    log_error "$apply_error_reason"
    return 1
  fi
  payload_project_id="$(_coordination_validate_semantic_project_id_value "$payload_project_id" "coordination registry delta payload")" || {
    local apply_error_reason="coordination registry delta payload project_id is invalid"
    _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "project_id_guard" "$apply_error_reason" || return 1
    return 1
  }
  if [[ "$payload_project_id" != "$project_id" ]]; then
    local apply_error_reason="coordination registry delta payload project_id mismatch: payload=$payload_project_id resolved=$project_id"
    _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "project_id_guard" "$apply_error_reason" || return 1
    log_error "$apply_error_reason"
    return 1
  fi
  local results_tmp=""
  results_tmp=$(create_temp_file "coord_registry_apply")

  local tool_name=""
  local field_name=""
  for tool_name in "sem.registry.upsert" "sem.registry.set_status" "sem.registry.delete"; do
    case "$tool_name" in
      "sem.registry.upsert") field_name="upserts" ;;
      "sem.registry.set_status") field_name="set_status" ;;
      "sem.registry.delete") field_name="deletes" ;;
    esac

    local mutator_inputs_file=""
    local input_error_file=""
    mutator_inputs_file=$(create_temp_file "coord_registry_inputs")
    input_error_file=$(create_temp_file "coord_registry_inputs_err")
      if ! jq -c \
      --arg tool "$tool_name" \
      --arg project_id "$project_id" \
      '
        def with_project($obj):
          if ($project_id | length) > 0 then
            (($obj | del(.project_id)) + {project_id: $project_id})
          else
            ($obj | del(.project_id))
          end;

        if $tool == "sem.registry.upsert" then
          (.mutations.upserts[]? | select(type == "object") | with_project({components:[(. | del(.project_id))]}))
        elif $tool == "sem.registry.set_status" then
          (.mutations.set_status[]? | select(type == "object") | with_project((. | del(.project_id))))
        else
          (.mutations.deletes[]? | select(type == "object") | with_project((. | del(.project_id))))
        end
      ' <<< "$payload_json" > "$mutator_inputs_file" 2> "$input_error_file"; then
      local input_failure_reason="coordination registry mutation plan invalid (tool=$tool_name)"
      if [[ -s "$input_error_file" ]]; then
        local input_error_text=""
        input_error_text="$(cat "$input_error_file" 2>/dev/null || true)"
        if [[ -n "$input_error_text" ]]; then
          input_failure_reason="$input_failure_reason: $input_error_text"
        fi
      fi
      if ! _coordination_maybe_commit_partial_apply_artifact "$authoritative_summary_json" "$results_tmp" "$apply_output_file" "$tool_name" "$input_failure_reason"; then
        rm -f "$mutator_inputs_file" "$input_error_file" "$results_tmp" "$apply_output_file" 2>/dev/null || true
        return 1
      fi
      rm -f "$mutator_inputs_file" "$input_error_file" "$results_tmp" 2>/dev/null || true
      log_error "$input_failure_reason"
      return 1
    fi
    rm -f "$input_error_file" 2>/dev/null || true

    local mutator_input=""
    while IFS= read -r mutator_input; do
      [[ -n "$mutator_input" ]] || continue
      local response=""
      local error_file=""
      error_file=$(create_temp_file "coord_registry_apply_err")
      if response=$(mcp_or_fallback "$tool_name" "$mutator_input" 2> "$error_file"); then
        local result_entry=""
        local parse_error_file=""
        parse_error_file=$(create_temp_file "coord_registry_apply_parse_err")
        if ! result_entry=$(jq -nc \
          --arg tool "$tool_name" \
          --arg input_json "$mutator_input" \
          --arg response_json "$response" \
          '
            ($input_json | fromjson) as $input
            | ($response_json | fromjson) as $response
            | {tool:$tool, input:$input, response:$response}
          ' 2> "$parse_error_file"); then
          local parse_failure_reason="coordination registry mutation returned invalid JSON (tool=$tool_name)"
          if [[ -s "$parse_error_file" ]]; then
            local parse_error_text=""
            parse_error_text="$(cat "$parse_error_file" 2>/dev/null || true)"
          if [[ -n "$parse_error_text" ]]; then
            parse_failure_reason="$parse_failure_reason: $parse_error_text"
          fi
        fi
          if [[ -s "$results_tmp" ]]; then
          if ! _coordination_maybe_commit_partial_apply_artifact "$authoritative_summary_json" "$results_tmp" "$apply_output_file" "$tool_name" "$parse_failure_reason"; then
              rm -f "$error_file" "$parse_error_file" "$mutator_inputs_file" "$results_tmp" "$apply_output_file" 2>/dev/null || true
              return 1
            fi
          else
            if ! _coordination_commit_apply_error_artifact "$authoritative_summary_json" "$apply_output_file" "$tool_name" "$parse_failure_reason"; then
              rm -f "$error_file" "$parse_error_file" "$mutator_inputs_file" "$results_tmp" "$apply_output_file" 2>/dev/null || true
              return 1
            fi
          fi
          rm -f "$error_file" "$parse_error_file" "$mutator_inputs_file" "$results_tmp" 2>/dev/null || true
          log_error "$parse_failure_reason"
          return 1
        fi
        rm -f "$parse_error_file" 2>/dev/null || true
        if ! printf '%s\n' "$result_entry" >> "$results_tmp"; then
          local write_failure_reason="coordination registry mutation result write failed (tool=$tool_name)"
          if ! _coordination_maybe_commit_partial_apply_artifact "$authoritative_summary_json" "$results_tmp" "$apply_output_file" "$tool_name" "$write_failure_reason"; then
            rm -f "$error_file" "$mutator_inputs_file" "$results_tmp" "$apply_output_file" 2>/dev/null || true
            return 1
          fi
          rm -f "$error_file" "$mutator_inputs_file" "$results_tmp" 2>/dev/null || true
          log_error "$write_failure_reason"
          return 1
        fi
      else
        local rc=$?
        local failure_reason="coordination registry mutation failed (tool=$tool_name rc=$rc)"
        if [[ -s "$error_file" ]]; then
          local stderr_text=""
          stderr_text="$(cat "$error_file" 2>/dev/null || true)"
        if [[ -n "$stderr_text" ]]; then
            failure_reason="$failure_reason: $stderr_text"
          fi
        fi
        if ! _coordination_maybe_commit_partial_apply_artifact "$authoritative_summary_json" "$results_tmp" "$apply_output_file" "$tool_name" "$failure_reason"; then
          rm -f "$error_file" "$mutator_inputs_file" "$results_tmp" "$apply_output_file" 2>/dev/null || true
          return 1
        fi
        rm -f "$error_file" "$mutator_inputs_file" "$results_tmp" 2>/dev/null || true
        log_error "$failure_reason"
        return 1
      fi
      rm -f "$error_file" 2>/dev/null || true
    done < "$mutator_inputs_file"
    rm -f "$mutator_inputs_file" 2>/dev/null || true
  done

  local aggregate_json='[]'
  if [[ -s "$results_tmp" ]]; then
    if ! aggregate_json=$(_coordination_collect_apply_results_json "$results_tmp"); then
      rm -f "$results_tmp" "$apply_output_file" 2>/dev/null || true
      log_error "coordination registry mutation aggregate invalid"
      return 1
    fi
  fi
  rm -f "$results_tmp" 2>/dev/null || true

  local apply_json=""
  if ! apply_json=$(_coordination_build_apply_artifact_json "$authoritative_summary_json" "$aggregate_json" "false"); then
    rm -f "$apply_output_file" 2>/dev/null || true
    log_error "coordination registry mutation apply artifact invalid"
    return 1
  fi

  if ! _coordination_commit_apply_artifact "$apply_output_file" "$apply_json"; then
    rm -f "$apply_output_file" 2>/dev/null || true
    return 1
  fi

  printf '%s\n' "$apply_json"
}

# Layer 0 後処理（delta更新 + lock延長）
# Usage: finalize_coordination_context <tmpdir> <phase> <iteration>
finalize_coordination_context() {
  local tmpdir="$1"
  local phase="$2"
  local iteration="$3"

  if [[ "$run_context_analysis" == "true" ]]; then
    local delta_json=""
    local registry_delta_file="$tmpdir/${phase}_coord_registry_delta_iter${iteration}.json"
    local delta_error_file=""
    delta_error_file=$(create_temp_file "coord_delta_err")
    if delta_json=$(_coordination_context_delta 2> "$delta_error_file"); then
      rm -f "$delta_error_file" 2>/dev/null || true
      printf '%s\n' "$delta_json" > "$tmpdir/${phase}_coord_delta_iter${iteration}.json"

      local task_id=""
      task_id=$(_coordination_resolve_task_id "$phase")
      local registry_delta_json=""
      local finalize_preflight_file="$tmpdir/${phase}_coord_preflight_input_iter${iteration}.json"
      local finalize_preflight_error_file=""
      finalize_preflight_error_file=$(create_temp_file "coord_finalize_preflight_err")
      if ! _coordination_refresh_finalize_preflight_input \
        "$tmpdir/${phase}_coord_preflight_input.json" \
        "$finalize_preflight_file" 2> "$finalize_preflight_error_file"; then
        local finalize_preflight_reason="Coordination finalize preflight refresh failed closed"
        if [[ -s "$finalize_preflight_error_file" ]]; then
          local finalize_preflight_error_text=""
          finalize_preflight_error_text="$(cat "$finalize_preflight_error_file" 2>/dev/null || true)"
          if [[ -n "$finalize_preflight_error_text" ]]; then
            finalize_preflight_reason="$finalize_preflight_reason: $finalize_preflight_error_text"
          fi
        fi
        rm -f "$finalize_preflight_error_file" "$finalize_preflight_file" 2>/dev/null || true
        _coordination_write_error_artifact "$registry_delta_file" "$finalize_preflight_reason"
        state_set_error "COORDINATION_MUTATION_BLOCK" "Coordination finalize preflight refresh failed closed. See: $registry_delta_file" "$phase"
        state_save
        die "Coordination finalize preflight refresh failed closed. See: $registry_delta_file"
      fi
      rm -f "$finalize_preflight_error_file" 2>/dev/null || true
      local delta_build_error_file=""
      delta_build_error_file=$(create_temp_file "coord_registry_delta_err")
      if ! registry_delta_json=$(_coordination_build_registry_delta_payload_from_files \
        "$task_id" \
        "$phase" \
        "$iteration" \
        "$finalize_preflight_file" \
        "$tmpdir/${phase}_coord_delta_iter${iteration}.json" 2> "$delta_build_error_file"); then
        local build_failure_reason="Coordination registry delta build failed closed"
        if [[ -s "$delta_build_error_file" ]]; then
          local build_error_text=""
          build_error_text="$(cat "$delta_build_error_file" 2>/dev/null || true)"
          if [[ -n "$build_error_text" ]]; then
            build_failure_reason="$build_failure_reason: $build_error_text"
          fi
        fi
        rm -f "$delta_build_error_file" 2>/dev/null || true
        _coordination_write_error_artifact "$registry_delta_file" "$build_failure_reason"
        state_set_error "COORDINATION_MUTATION_BLOCK" "Coordination registry delta build failed closed. See: $registry_delta_file" "$phase"
        state_save
        die "Coordination registry delta build failed closed. See: $registry_delta_file"
      fi
      rm -f "$delta_build_error_file" "$finalize_preflight_file" 2>/dev/null || true
      if ! _coordination_registry_delta_contract_is_valid "$registry_delta_json"; then
        printf '%s\n' "$registry_delta_json" > "$registry_delta_file"
        state_set_error "COORDINATION_MUTATION_BLOCK" "Coordination registry delta contract invalid. See: $registry_delta_file" "$phase"
        state_save
        die "Coordination registry delta contract invalid. See: $registry_delta_file"
      fi

      printf '%s\n' "$registry_delta_json" > "$registry_delta_file"

      local registry_apply_file="$tmpdir/${phase}_coord_registry_apply_iter${iteration}.json"
      if ! _coordination_apply_registry_delta_payload "$registry_delta_json" "$registry_apply_file" >/dev/null; then
        local apply_failure_message="Coordination registry mutation failed closed before apply artifact commit. Intended path: $registry_apply_file"
        if [[ -f "$registry_apply_file" ]]; then
          if jq -e '.partial_apply == true' "$registry_apply_file" >/dev/null 2>&1; then
            apply_failure_message="Coordination registry mutation failed closed after partial apply artifact commit. See: $registry_apply_file"
          else
            apply_failure_message="Coordination registry mutation failed closed after apply error artifact commit. See: $registry_apply_file"
          fi
        fi
        state_set_error "COORDINATION_MUTATION_BLOCK" "$apply_failure_message" "$phase"
        state_save
        die "$apply_failure_message"
      fi
    else
      local delta_failure_reason="Coordination delta generation failed closed (iteration=$iteration)"
      if [[ -s "$delta_error_file" ]]; then
        local delta_error_text=""
        delta_error_text="$(cat "$delta_error_file" 2>/dev/null || true)"
        if [[ -n "$delta_error_text" ]]; then
          delta_failure_reason="$delta_failure_reason: $delta_error_text"
        fi
      fi
      rm -f "$delta_error_file" 2>/dev/null || true
      _coordination_write_error_artifact "$registry_delta_file" "$delta_failure_reason"
      state_set_error "COORDINATION_MUTATION_BLOCK" "Coordination delta generation failed closed. See: $registry_delta_file" "$phase"
      state_save
      die "Coordination delta generation failed closed. See: $registry_delta_file"
    fi
  fi

  if ! refresh_lock; then
    log_debug "Lock heartbeat update skipped/failed (iteration=$iteration)"
  fi
}

# RV-2: reviewer 出力は Code Review Report 契約に揃える
# Usage: validate_review_output_format <reviews_file>
# Returns: 0 if valid, 1 if invalid
_review_report_findings_has_none() {
  local report_file="$1"

  if [[ -z "$report_file" || ! -r "$report_file" ]]; then
    return 1
  fi

  awk '
    /^## Findings[[:space:]]*$/ {
      in_findings = 1
      next
    }
    /^## / {
      in_findings = 0
    }
    in_findings && /^[[:space:]]*-[[:space:]]*(None|No findings)\.?[[:space:]]*$/ {
      found = 1
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$report_file"
}

_review_contract_projection_path() {
  local projection_path="${ORCHESTRATION_POLICY_PROJECTION_PATH:-$REPO_ROOT/.agent/registry/orchestration_policy_projection.json}"
  local canonical_path="$REPO_ROOT/.agent/registry/orchestration_policy_projection.json"
  local projection_dir=""
  local projection_base=""
  local canonical_dir=""
  local canonical_base=""

  if [[ "$projection_path" != /* ]]; then
    projection_path="$REPO_ROOT/$projection_path"
  fi

  projection_base="$(basename "$projection_path")" || return 1
  projection_dir="$(cd -- "$(dirname -- "$projection_path")" && pwd -P)" || return 1
  projection_path="$projection_dir/$projection_base"

  canonical_base="$(basename "$canonical_path")" || return 1
  canonical_dir="$(cd -- "$(dirname -- "$canonical_path")" && pwd -P)" || return 1
  canonical_path="$canonical_dir/$canonical_base"

  if [[ "$projection_path" != "$canonical_path" ]]; then
    return 1
  fi

  [[ -r "$projection_path" ]] || return 1
  jq empty "$projection_path" >/dev/null 2>&1 || return 1
  printf '%s\n' "$projection_path"
}

_review_contract_scalar() {
  local projection_path="$1"
  local query="$2"

  jq -r -e "$query" "$projection_path"
}

_review_contract_regex_escape() {
  printf '%s' "$1" | sed -e 's/[][(){}.^$*+?|\\/]/\\&/g'
}

_review_contract_array_pattern() {
  local projection_path="$1"
  local query="$2"
  local item=""
  local escaped_items=()

  while IFS= read -r item; do
    [[ -n "$item" ]] || continue
    escaped_items+=("$(_review_contract_regex_escape "$item")")
  done < <(jq -r -e "$query[]" "$projection_path")

  [[ "${#escaped_items[@]}" -gt 0 ]] || return 1
  local IFS='|'
  printf '%s\n' "${escaped_items[*]}"
}

_review_contract_array_lines() {
  local projection_path="$1"
  local query="$2"

  jq -r -e "$query | join(\"\u001c\")" "$projection_path"
}

_review_contract_value_allowed() {
  local projection_path="$1"
  local query="$2"
  local candidate="$3"

  jq -e --arg candidate "$candidate" "$query | index(\$candidate) != null" "$projection_path" >/dev/null
}

_review_contract_verdict_next_status() {
  local projection_path="$1"
  local verdict="$2"

  jq -r -e --arg verdict "$verdict" '.reviewer_contract.verdict_outgoing_next_status[$verdict]' "$projection_path"
}

_review_contract_verdict_next_status_pairs() {
  local projection_path="$1"

  jq -r -e '.reviewer_contract.verdict_outgoing_next_status | to_entries | map(.key + "\u001d" + .value) | join("\u001c")' "$projection_path"
}

_review_report_has_forbidden_transport_markers() {
  local report_file="$1"

  [[ -n "$report_file" && -r "$report_file" ]] || return 1

  awk '
    function reset_transport_object() {
      transport_object_open = 0
      transport_object_lines = 0
      transport_key_other_recipients = 0
      transport_key_trigger_turn = 0
      transport_content_has_transport_marker = 0
    }
    function transport_object_has_marker() {
      return transport_key_other_recipients || transport_key_trigger_turn || transport_content_has_transport_marker
    }
    function record_transport_key(line) {
      if (line ~ /"other_recipients"[[:space:]]*:/) transport_key_other_recipients = 1
      if (line ~ /"trigger_turn"[[:space:]]*:/) transport_key_trigger_turn = 1
      if (line ~ /"content"[[:space:]]*:[[:space:]]*"<subagent_notification>/) transport_content_has_transport_marker = 1
    }
    function line_has_transport_object(line, has_harness_field, has_transport_content) {
      has_harness_field = (line ~ /"other_recipients"[[:space:]]*:/) || (line ~ /"trigger_turn"[[:space:]]*:/)
      has_transport_content = (line ~ /"content"[[:space:]]*:[[:space:]]*"<subagent_notification>/)
      return has_harness_field || has_transport_content
    }
    function line_starts_transport_object(line) {
      return (line ~ /^[[:space:]]*\{[[:space:]]*$/) || ((line ~ /\{/) && (line ~ /"author"[[:space:]]*:/ || line ~ /"recipient"[[:space:]]*:/ || line ~ /"content"[[:space:]]*:/ || line ~ /"other_recipients"[[:space:]]*:/ || line ~ /"trigger_turn"[[:space:]]*:/))
    }
    function open_transport_object(line) {
      reset_transport_object()
      transport_object_open = 1
      transport_object_lines = 1
      record_transport_key(line)
    }
    function has_transport_marker(line) {
      if (line ~ /^[[:space:]]*<subagent_notification>[[:space:]]*$/) return 1
      if (line ~ /^[[:space:]]*<\/subagent_notification>[[:space:]]*$/) return 1
      if (line ~ /^[[:space:]]*\[codex-wrapper\] (INFO|WARN|ERROR):/) return 1
      if (line_has_transport_object(line)) return 1
      if (line ~ /^[[:space:]]*"other_recipients"[[:space:]]*:/) return 1
      if (line ~ /^[[:space:]]*"trigger_turn"[[:space:]]*:/) return 1
      if (line ~ /^[[:space:]]*"content"[[:space:]]*:[[:space:]]*"<subagent_notification>/) return 1
      return 0
    }
    BEGIN {
      reset_transport_object()
    }
    has_transport_marker($0) {
      found = 1
      exit 0
    }
    !transport_object_open && line_starts_transport_object($0) {
      open_transport_object($0)
      if (transport_object_has_marker()) {
        found = 1
        exit 0
      }
      if ($0 ~ /\}/ || transport_object_lines >= 16) {
        reset_transport_object()
      }
      next
    }
    transport_object_open {
      transport_object_lines++
      record_transport_key($0)
      if (transport_object_has_marker()) {
        found = 1
        exit 0
      }
      if ($0 ~ /\}/ || transport_object_lines >= 16) {
        reset_transport_object()
      }
    }
    END {
      exit(found ? 0 : 1)
    }
  ' "$report_file"
}

_review_report_expand_artifact_path() {
  local artifact_path="${1:-}"

  case "$artifact_path" in
    "file://localhost"*)
      printf '%s\n' "${artifact_path#file://localhost}"
      ;;
    "file://"*)
      printf '%s\n' "${artifact_path#file://}"
      ;;
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${artifact_path#~/}"
      ;;
    *)
      printf '%s\n' "$artifact_path"
      ;;
  esac
}

_review_report_artifact_pointer_is_remote_url() {
  local artifact_pointer="${1:-}"

  [[ "$artifact_pointer" =~ ^[A-Za-z][A-Za-z0-9+.-]*:// ]] || return 1
  [[ "$artifact_pointer" == file://* ]] && return 1
  return 0
}

_review_report_local_artifact_exists() {
  local artifact_pointer="${1:-}"
  local artifact_base_file="${2:-}"
  local normalized_pointer=""
  local report_dir=""

  [[ -n "$artifact_pointer" && "$artifact_pointer" != "n/a" ]] || return 0
  [[ -n "$artifact_base_file" && -r "$artifact_base_file" ]] || return 1
  _review_report_artifact_pointer_is_remote_url "$artifact_pointer" && return 0

  normalized_pointer="$(_review_report_expand_artifact_path "$artifact_pointer")"
  if [[ -e "$normalized_pointer" ]]; then
    return 0
  fi

  report_dir="$(cd "$(/usr/bin/dirname "$artifact_base_file")" && pwd -P)" || return 1
  [[ "$normalized_pointer" == /* ]] && return 1
  [[ -e "$report_dir/$normalized_pointer" ]]
}

_review_report_required_verification_artifact_exists() {
  local report_file="$1"
  local artifact_base_file="${2:-$report_file}"
  local artifact_pointer=""
  local artifact_integrity=""

  [[ -n "$report_file" && -r "$report_file" ]] || return 1

  artifact_pointer="$(
    awk '
      /^## Required Verification[[:space:]]*$/ { in_required_verification = 1; next }
      /^## / && in_required_verification { exit }
      in_required_verification && /^- artifact pointer:[[:space:]]*/ {
        sub(/^- artifact pointer:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    ' "$report_file"
  )"
  artifact_integrity="$(
    awk '
      /^## Required Verification[[:space:]]*$/ { in_required_verification = 1; next }
      /^## / && in_required_verification { exit }
      in_required_verification && /^- artifact integrity:[[:space:]]*/ {
        sub(/^- artifact integrity:[[:space:]]*/, "", $0)
        print $0
        exit
      }
    ' "$report_file"
  )"
  [[ "$artifact_integrity" == "complete" ]] || return 0
  [[ -n "$artifact_pointer" && "$artifact_pointer" != "n/a" ]] || return 0
  _review_report_local_artifact_exists "$artifact_pointer" "$artifact_base_file"
}

_review_report_final_lgtm_local_artifacts_exist() {
  local report_file="$1"
  local artifact_base_file="${2:-$report_file}"
  local field_name=""
  local artifact_pointer=""

  [[ -n "$report_file" && -r "$report_file" ]] || return 1

  while IFS=$'\t' read -r field_name artifact_pointer; do
    [[ -n "$field_name" ]] || continue
    _review_report_local_artifact_exists "$artifact_pointer" "$artifact_base_file" || return 1
  done < <(
    awk '
      function trim(value) {
        gsub(/^[[:space:]]+/, "", value)
        gsub(/[[:space:]]+$/, "", value)
        return value
      }
      function strip_prefix(line, pattern,    value) {
        value = line
        sub(pattern, "", value)
        return trim(value)
      }
      BEGIN {
        section = ""
        worker_outcome_subsection = ""
      }
      /^## Review Request[[:space:]]*$/ {
        section = "review_request"
        worker_outcome_subsection = ""
        next
      }
      /^## Review Outcome[[:space:]]*$/ {
        section = "review_outcome"
        worker_outcome_subsection = ""
        next
      }
      /^## Required Verification[[:space:]]*$/ {
        section = "required_verification"
        worker_outcome_subsection = ""
        next
      }
      /^## Worker Outcome Payload Reviewed[[:space:]]*$/ {
        section = "worker_outcome_payload_reviewed"
        worker_outcome_subsection = ""
        next
      }
      /^## Evidence Reviewed[[:space:]]*$/ {
        section = "evidence_reviewed"
        worker_outcome_subsection = ""
        next
      }
      /^### DIFF Payload Reviewed[[:space:]]*$/ {
        if (section == "worker_outcome_payload_reviewed") {
          worker_outcome_subsection = "diff"
        }
        next
      }
      /^### NO-CHANGE Payload Reviewed[[:space:]]*$/ {
        if (section == "worker_outcome_payload_reviewed") {
          worker_outcome_subsection = "no_change"
        }
        next
      }
      /^## / {
        section = ""
        worker_outcome_subsection = ""
        next
      }
      section == "review_request" {
        if ($0 ~ /^- incoming request status:[[:space:]]*/) {
          rr_status_value = strip_prefix($0, "^- incoming request status:[[:space:]]*")
        } else if ($0 ~ /^- review request target:[[:space:]]*/) {
          rr_review_target_value = strip_prefix($0, "^- review request target:[[:space:]]*")
        } else if ($0 ~ /^- worker outcome:[[:space:]]*/) {
          rr_worker_outcome_value = strip_prefix($0, "^- worker outcome:[[:space:]]*")
        }
        next
      }
      section == "review_outcome" {
        if ($0 ~ /^- review verdict:[[:space:]]*/) {
          ro_review_verdict_value = strip_prefix($0, "^- review verdict:[[:space:]]*")
        }
        next
      }
      section == "required_verification" {
        if ($0 ~ /^- artifact pointer:[[:space:]]*/) {
          rv_artifact_pointer_value = strip_prefix($0, "^- artifact pointer:[[:space:]]*")
        }
        next
      }
      section == "worker_outcome_payload_reviewed" && worker_outcome_subsection == "diff" {
        if ($0 ~ /^- evidence pointer:[[:space:]]*/) {
          wop_diff_evidence_pointer_value = strip_prefix($0, "^- evidence pointer:[[:space:]]*")
        }
        next
      }
      section == "worker_outcome_payload_reviewed" && worker_outcome_subsection == "no_change" {
        if ($0 ~ /^- search \/ verification evidence:[[:space:]]*/) {
          wop_no_change_evidence_value = strip_prefix($0, "^- search \\/ verification evidence:[[:space:]]*")
        }
        next
      }
      section == "evidence_reviewed" {
        if ($0 ~ /^- artifact:[[:space:]]*/) {
          er_artifact_count++
          er_artifact_values[er_artifact_count] = strip_prefix($0, "^- artifact:[[:space:]]*")
        }
        next
      }
      END {
        if (!(rr_status_value == "pending final review" && rr_review_target_value == "FINAL" && ro_review_verdict_value == "LGTM")) {
          exit 0
        }

        if (rv_artifact_pointer_value != "") {
          print "required_verification_artifact_pointer\t" rv_artifact_pointer_value
        }
        if (rr_worker_outcome_value == "DIFF" && wop_diff_evidence_pointer_value != "") {
          print "worker_outcome_diff_evidence_pointer\t" wop_diff_evidence_pointer_value
        }
        if (rr_worker_outcome_value == "NO-CHANGE" && wop_no_change_evidence_value != "") {
          print "worker_outcome_no_change_evidence\t" wop_no_change_evidence_value
        }
        for (i = 1; i <= er_artifact_count; i++) {
          if (er_artifact_values[i] != "") {
            print "evidence_reviewed_artifact\t" er_artifact_values[i]
          }
        }
      }
    ' "$report_file"
  )
}

_validate_single_review_report() {
  local report_file="$1"
  local artifact_base_file="${2:-$report_file}"
  local projection_path=""
  local canonical_worker_outcome_contract_source=""
  local blocked_worker_outcome_intake_rule_line=""
  local accepted_incoming_request_statuses_pattern=""
  local accepted_review_request_targets_pattern=""
  local accepted_discovery_owners_pattern=""
  local accepted_worker_outcomes_pattern=""
  local accepted_review_verdicts_pattern=""
  local accepted_outgoing_next_statuses_pattern=""
  local accepted_review_verdicts_list=""
  local verdict_next_status_pairs=""
  local lgtm_required_request_target=""
  local lgtm_required_incoming_request_status=""
  local lgtm_required_artifact_integrity=""
  local lgtm_required_required_verification_result=""
  local lgtm_required_tests_result=""
  local lgtm_required_adversarial_result=""
  local lgtm_required_slice_contract_sheet_status=""
  local lgtm_required_class_closure_sheet_status=""
  local lgtm_required_slice_contract_closed_universe_status=""
  local lgtm_required_class_closure_closed_universe_status=""

  if [[ -z "$report_file" || ! -r "$report_file" ]]; then
    return 1
  fi

  if _review_report_has_forbidden_transport_markers "$report_file"; then
    return 1
  fi

  projection_path="$(_review_contract_projection_path)" || return 1
  canonical_worker_outcome_contract_source="$(_review_contract_scalar "$projection_path" '.reviewer_contract.canonical_worker_outcome_contract_source')" || return 1
  blocked_worker_outcome_intake_rule_line="$(_review_contract_scalar "$projection_path" '.reviewer_contract.blocked_worker_outcome_intake_rule_line')" || return 1
  accepted_incoming_request_statuses_pattern="$(_review_contract_array_pattern "$projection_path" '.reviewer_contract.accepted_incoming_request_statuses')" || return 1
  accepted_review_request_targets_pattern="$(_review_contract_array_pattern "$projection_path" '.reviewer_contract.accepted_review_request_targets')" || return 1
  accepted_discovery_owners_pattern="$(_review_contract_array_pattern "$projection_path" '.reviewer_contract.accepted_discovery_owners')" || return 1
  accepted_worker_outcomes_pattern="$(_review_contract_array_pattern "$projection_path" '.reviewer_contract.accepted_worker_outcomes')" || return 1
  accepted_review_verdicts_pattern="$(_review_contract_array_pattern "$projection_path" '.reviewer_contract.accepted_review_verdicts')" || return 1
  accepted_outgoing_next_statuses_pattern="$(_review_contract_array_pattern "$projection_path" '.reviewer_contract.accepted_outgoing_next_statuses')" || return 1
  accepted_review_verdicts_list="$(_review_contract_array_lines "$projection_path" '.reviewer_contract.accepted_review_verdicts')" || return 1
  verdict_next_status_pairs="$(_review_contract_verdict_next_status_pairs "$projection_path")" || return 1
  lgtm_required_request_target="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_request_target')" || return 1
  lgtm_required_incoming_request_status="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_incoming_request_status')" || return 1
  lgtm_required_artifact_integrity="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_artifact_integrity')" || return 1
  lgtm_required_required_verification_result="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_required_verification_result')" || return 1
  lgtm_required_tests_result="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_tests_result')" || return 1
  lgtm_required_adversarial_result="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_adversarial_result')" || return 1
  lgtm_required_slice_contract_sheet_status="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_slice_contract_sheet_status')" || return 1
  lgtm_required_class_closure_sheet_status="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_class_closure_sheet_status')" || return 1
  lgtm_required_slice_contract_closed_universe_status="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_slice_contract_closed_universe_status')" || return 1
  lgtm_required_class_closure_closed_universe_status="$(_review_contract_scalar "$projection_path" '.reviewer_contract.lgtm_gate.required_class_closure_closed_universe_status')" || return 1

  awk \
    -v canonical_worker_outcome_contract_source="$canonical_worker_outcome_contract_source" \
    -v blocked_worker_outcome_intake_rule_line="$blocked_worker_outcome_intake_rule_line" \
    -v accepted_incoming_request_statuses_pattern="$accepted_incoming_request_statuses_pattern" \
    -v accepted_review_request_targets_pattern="$accepted_review_request_targets_pattern" \
    -v accepted_discovery_owners_pattern="$accepted_discovery_owners_pattern" \
    -v accepted_worker_outcomes_pattern="$accepted_worker_outcomes_pattern" \
    -v accepted_review_verdicts_pattern="$accepted_review_verdicts_pattern" \
    -v accepted_outgoing_next_statuses_pattern="$accepted_outgoing_next_statuses_pattern" \
    -v accepted_review_verdicts_list="$accepted_review_verdicts_list" \
    -v verdict_next_status_pairs="$verdict_next_status_pairs" \
    -v lgtm_required_request_target="$lgtm_required_request_target" \
    -v lgtm_required_incoming_request_status="$lgtm_required_incoming_request_status" \
    -v lgtm_required_artifact_integrity="$lgtm_required_artifact_integrity" \
    -v lgtm_required_required_verification_result="$lgtm_required_required_verification_result" \
    -v lgtm_required_tests_result="$lgtm_required_tests_result" \
    -v lgtm_required_adversarial_result="$lgtm_required_adversarial_result" \
    -v lgtm_required_slice_contract_sheet_status="$lgtm_required_slice_contract_sheet_status" \
    -v lgtm_required_class_closure_sheet_status="$lgtm_required_class_closure_sheet_status" \
    -v lgtm_required_slice_contract_closed_universe_status="$lgtm_required_slice_contract_closed_universe_status" \
    -v lgtm_required_class_closure_closed_universe_status="$lgtm_required_class_closure_closed_universe_status" \
    '
    function trim(value) {
      gsub(/^[[:space:]]+/, "", value)
      gsub(/[[:space:]]+$/, "", value)
      return value
    }
    function strip_prefix(line, pattern,    value) {
      value = line
      sub(pattern, "", value)
      return trim(value)
    }
    function load_projected_verdict_contract(    i, item_count, pair_count, pair_parts, record_sep, unit_sep, verdict_items, status_pairs) {
      record_sep = sprintf("%c", 28)
      unit_sep = sprintf("%c", 29)

      item_count = split(accepted_review_verdicts_list, verdict_items, record_sep)
      for (i = 1; i <= item_count; i++) {
        if (verdict_items[i] != "") {
          projected_verdict_required[verdict_items[i]] = 1
          projected_verdict_required_count++
        }
      }

      pair_count = split(verdict_next_status_pairs, status_pairs, record_sep)
      for (i = 1; i <= pair_count; i++) {
        if (status_pairs[i] != "") {
          split(status_pairs[i], pair_parts, unit_sep)
          if (pair_parts[1] != "" && pair_parts[2] != "") {
            projected_next_status[pair_parts[1]] = pair_parts[2]
          }
        }
      }
    }
    BEGIN {
      section = ""
      first_content_seen = 0
      load_projected_verdict_contract()
    }
    {
      if (!first_content_seen && $0 ~ /[^[:space:]]/) {
        first_content_seen = 1
        if ($0 !~ /^# Code Review Report[[:space:]]*$/) {
          exit 1
        }
      }
    }
    /^# Code Review Report[[:space:]]*$/ {
      has_report = 1
      next
    }
    /^## Review Request[[:space:]]*$/ {
      has_review_request = 1
      section = "review_request"
      next
    }
    /^## Review Outcome[[:space:]]*$/ {
      has_review_outcome = 1
      section = "review_outcome"
      next
    }
    /^## Slice Contract[[:space:]]*$/ {
      has_slice_contract = 1
      section = "slice_contract"
      next
    }
    /^## Loop Budget Ledger[[:space:]]*$/ {
      has_loop_budget_ledger = 1
      section = "loop_budget_ledger"
      next
    }
    /^## Summary[[:space:]]*$/ {
      has_summary = 1
      section = "summary"
      next
    }
    /^## Findings[[:space:]]*$/ {
      has_findings = 1
      section = "findings"
      next
    }
    /^## Tests[[:space:]]*$/ {
      has_tests = 1
      section = "tests"
      next
    }
    /^## Review Scope[[:space:]]*$/ {
      has_review_scope = 1
      section = "review_scope"
      next
    }
    /^## Class Closure Sheet[[:space:]]*$/ {
      has_class_closure_sheet = 1
      section = "class_closure_sheet"
      next
    }
    /^## Adversarial Pre-Closure Pass[[:space:]]*$/ {
      has_adversarial_pre_closure_pass = 1
      section = "adversarial_pre_closure_pass"
      next
    }
    /^## Required Verification[[:space:]]*$/ {
      has_required_verification = 1
      section = "required_verification"
      worker_outcome_subsection = ""
      next
    }
    /^## Worker Outcome Payload Reviewed[[:space:]]*$/ {
      has_worker_outcome_payload_reviewed = 1
      section = "worker_outcome_payload_reviewed"
      worker_outcome_subsection = ""
      next
    }
    /^## Evidence Reviewed[[:space:]]*$/ {
      has_evidence_reviewed = 1
      section = "evidence_reviewed"
      worker_outcome_subsection = ""
      next
    }
    /^## Unverified Areas[[:space:]]*$/ {
      has_unverified_areas = 1
      section = "unverified_areas"
      next
    }
    /^## Open Questions[[:space:]]*$/ {
      has_open_questions = 1
      section = "open_questions"
      next
    }
    /^## Verdict[[:space:]]*$/ {
      has_verdict = 1
      section = "verdict"
      worker_outcome_subsection = ""
      next
    }
    /^### DIFF Payload Reviewed[[:space:]]*$/ {
      if (section == "worker_outcome_payload_reviewed") {
        has_diff_payload_reviewed = 1
        worker_outcome_subsection = "diff"
      }
      next
    }
    /^### NO-CHANGE Payload Reviewed[[:space:]]*$/ {
      if (section == "worker_outcome_payload_reviewed") {
        has_no_change_payload_reviewed = 1
        worker_outcome_subsection = "no_change"
      }
      next
    }
    /^## / {
      section = ""
      worker_outcome_subsection = ""
      next
    }
    {
      if (section == "review_request") {
        if ($0 ~ ("^- incoming request status:[[:space:]]*(" accepted_incoming_request_statuses_pattern ")[[:space:]]*$")) {
          rr_status = 1
          rr_status_value = strip_prefix($0, "^- incoming request status:[[:space:]]*")
        } else if ($0 ~ /^- task id:[[:space:]]*[^[:space:]].*$/) {
          rr_task_id = 1
          rr_task_id_value = strip_prefix($0, "^- task id:[[:space:]]*")
        } else if ($0 ~ /^- task lineage ledger entry:[[:space:]]*[^[:space:]].*$/) {
          rr_task_lineage = 1
          rr_task_lineage_value = strip_prefix($0, "^- task lineage ledger entry:[[:space:]]*")
        } else if ($0 ~ /^- prior task id:[[:space:]]*[^[:space:]].*$/) {
          rr_prior_task_id = 1
          rr_prior_task_id_value = strip_prefix($0, "^- prior task id:[[:space:]]*")
        } else if ($0 ~ /^- slice id:[[:space:]]*[^[:space:]].*$/) {
          rr_slice_id = 1
          rr_slice_id_value = strip_prefix($0, "^- slice id:[[:space:]]*")
        } else if ($0 ~ /^- prior slice id:[[:space:]]*[^[:space:]].*$/) {
          rr_prior_slice_id = 1
          rr_prior_slice_id_value = strip_prefix($0, "^- prior slice id:[[:space:]]*")
        } else if ($0 ~ ("^- review request target:[[:space:]]*(" accepted_review_request_targets_pattern ")[[:space:]]*$")) {
          rr_review_target = 1
          rr_review_target_value = strip_prefix($0, "^- review request target:[[:space:]]*")
        } else if ($0 ~ ("^- discovery owner:[[:space:]]*(" accepted_discovery_owners_pattern ")[[:space:]]*$")) {
          rr_discovery_owner = 1
          rr_discovery_owner_value = strip_prefix($0, "^- discovery owner:[[:space:]]*")
        } else if ($0 ~ /^- bug class candidate:[[:space:]]*[^[:space:]].*$/) {
          rr_bug_class_candidate = 1
          rr_bug_class_candidate_value = strip_prefix($0, "^- bug class candidate:[[:space:]]*")
        } else if ($0 ~ ("^- worker outcome:[[:space:]]*(" accepted_worker_outcomes_pattern ")[[:space:]]*$")) {
          rr_worker_outcome = 1
          rr_worker_outcome_value = strip_prefix($0, "^- worker outcome:[[:space:]]*")
        } else if ($0 ~ /^- request objective:[[:space:]]*[^[:space:]].*$/) {
          rr_request_objective = 1
        } else if ($0 ~ /^- invalid intake route:[[:space:]]*[^[:space:]].*$/) {
          rr_invalid_intake_route = 1
        }
      } else if (section == "review_outcome") {
        if ($0 ~ ("^- review verdict:[[:space:]]*(" accepted_review_verdicts_pattern ")[[:space:]]*$")) {
          ro_review_verdict = 1
          ro_review_verdict_value = strip_prefix($0, "^- review verdict:[[:space:]]*")
        } else if ($0 ~ ("^- outgoing next status:[[:space:]]*(" accepted_outgoing_next_statuses_pattern ")[[:space:]]*$")) {
          ro_next_status = 1
          ro_next_status_value = strip_prefix($0, "^- outgoing next status:[[:space:]]*")
        } else if ($0 ~ /^- next action:[[:space:]]*[^[:space:]].*$/) {
          ro_next_action = 1
        }
      } else if (section == "slice_contract") {
        if ($0 ~ /^- task id:[[:space:]]*[^[:space:]].*$/) {
          sc_task_id = 1
          sc_task_id_value = strip_prefix($0, "^- task id:[[:space:]]*")
        } else if ($0 ~ /^- task lineage ledger entry:[[:space:]]*[^[:space:]].*$/) {
          sc_task_lineage = 1
          sc_task_lineage_value = strip_prefix($0, "^- task lineage ledger entry:[[:space:]]*")
        } else if ($0 ~ /^- prior task id:[[:space:]]*[^[:space:]].*$/) {
          sc_prior_task_id = 1
          sc_prior_task_id_value = strip_prefix($0, "^- prior task id:[[:space:]]*")
        } else if ($0 ~ /^- slice id:[[:space:]]*[^[:space:]].*$/) {
          sc_slice_id = 1
          sc_slice_id_value = strip_prefix($0, "^- slice id:[[:space:]]*")
        } else if ($0 ~ /^- prior slice id:[[:space:]]*[^[:space:]].*$/) {
          sc_prior_slice_id = 1
          sc_prior_slice_id_value = strip_prefix($0, "^- prior slice id:[[:space:]]*")
        } else if ($0 ~ ("^- review request target:[[:space:]]*(" accepted_review_request_targets_pattern ")[[:space:]]*$")) {
          sc_review_target = 1
          sc_review_target_value = strip_prefix($0, "^- review request target:[[:space:]]*")
        } else if ($0 ~ ("^- discovery owner:[[:space:]]*(" accepted_discovery_owners_pattern ")[[:space:]]*$")) {
          sc_discovery_owner = 1
          sc_discovery_owner_value = strip_prefix($0, "^- discovery owner:[[:space:]]*")
        } else if ($0 ~ /^- bug class candidate:[[:space:]]*[^[:space:]].*$/) {
          sc_bug_class_candidate = 1
          sc_bug_class_candidate_value = strip_prefix($0, "^- bug class candidate:[[:space:]]*")
        } else if ($0 ~ /^- change surface:[[:space:]]*[^[:space:]].*$/) {
          sc_change_surface = 1
        } else if ($0 ~ /^- in-scope:[[:space:]]*[^[:space:]].*$/) {
          sc_in_scope = 1
        } else if ($0 ~ /^- out-of-scope:[[:space:]]*[^[:space:]].*$/) {
          sc_out_of_scope = 1
        } else if ($0 ~ /^- required checks:[[:space:]]*[^[:space:]].*$/) {
          sc_required_checks = 1
        } else if ($0 ~ /^- evidence destination:[[:space:]]*[^[:space:]].*$/) {
          sc_evidence_destination = 1
        } else if ($0 ~ /^- completion boundary:[[:space:]]*[^[:space:]].*$/) {
          sc_completion_boundary = 1
        } else if ($0 ~ /^- class closure sheet:[[:space:]]*[^[:space:]].*$/) {
          sc_class_closure_sheet = 1
        } else if ($0 ~ /^- sheet status:[[:space:]]*(OPEN|CLOSED|RESET|n\/a)[[:space:]]*$/) {
          sc_sheet_status = 1
          sc_sheet_status_value = strip_prefix($0, "^- sheet status:[[:space:]]*")
        } else if ($0 ~ /^- owned sink universe:[[:space:]]*[^[:space:]].*$/) {
          sc_owned_sink_universe = 1
        } else if ($0 ~ /^- closed universe status:[[:space:]]*(YES|NO|n\/a)[[:space:]]*$/) {
          sc_closed_universe_status = 1
          sc_closed_universe_status_value = strip_prefix($0, "^- closed universe status:[[:space:]]*")
        } else if ($0 ~ /^- closed universe basis:[[:space:]]*[^[:space:]].*$/) {
          sc_closed_universe_basis = 1
        } else if ($0 ~ /^- scope delta since last review:[[:space:]]*[^[:space:]].*$/) {
          sc_scope_delta = 1
        } else if ($0 ~ /^- re-slice delta type:[[:space:]]*[^[:space:]].*$/) {
          sc_reslice_delta_type = 1
        } else if ($0 ~ /^- re-slice delta summary:[[:space:]]*[^[:space:]].*$/) {
          sc_reslice_delta_summary = 1
        } else if ($0 ~ /^- delta evidence:[[:space:]]*[^[:space:]].*$/) {
          sc_delta_evidence = 1
        }
      } else if (section == "loop_budget_ledger") {
        if ($0 ~ /^- fix-review loops used:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_fix_review_loops = 1
        } else if ($0 ~ /^- closure resets used:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_closure_resets = 1
        } else if ($0 ~ /^- reviewer-found same-class finding count:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_same_class_findings = 1
        } else if ($0 ~ /^- re-slice count for task:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_reslice_count = 1
        } else if ($0 ~ /^- cumulative reviewer requests for task:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_cumulative_requests = 1
        } else if ($0 ~ /^- cumulative late same-class findings for task:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_cumulative_late_findings = 1
        } else if ($0 ~ /^- cumulative closure resets for task:[[:space:]]*[0-9]+\/[0-9]+([[:space:]]*\(BLOCK\))?[[:space:]]*$/) {
          lbl_cumulative_closure_resets = 1
        } else if ($0 ~ /^- task-level stall-or-wall-time budget:[[:space:]]*[^[:space:]].*$/) {
          lbl_stall_budget = 1
        } else if ($0 ~ /^- task-level stall-or-wall-time budget status:[[:space:]]*(within-budget|exhausted)[[:space:]]*$/) {
          lbl_stall_budget_status = 1
        }
      } else if (section == "summary" && $0 ~ /[^[:space:]]/) {
        summary_has_content = 1
      } else if (section == "findings") {
        if ($0 ~ /^[[:space:]]*###[[:space:]]+\[(High|Medium|Low)\][[:space:]]+/) {
          findings_has_severity = 1
        }
        if ($0 ~ /^[[:space:]]*-[[:space:]]*(None|No findings)\.?[[:space:]]*$/) {
          findings_has_none = 1
        }
      } else if (section == "tests") {
        if ($0 ~ /^- \*\*実施:\*\*[[:space:]]*(YES|NO)[[:space:]]*$/) {
          tests_ran = 1
        } else if ($0 ~ /^- \*\*結果:\*\*[[:space:]]*(PASS|FAIL)[[:space:]]*$/) {
          tests_result = 1
          tests_result_value = strip_prefix($0, "^- \\*\\*結果:\\*\\*[[:space:]]*")
        } else if ($0 ~ /^- \*\*結果:\*\*[[:space:]]*NOT RUN[[:space:]]*$/) {
          tests_result_not_run = 1
        } else if ($0 ~ /^- \*\*未実施の理由:\*\*[[:space:]]*[^[:space:]].*$/) {
          tests_not_run_reason = 1
        }
      } else if (section == "review_scope") {
        if ($0 ~ /^- change surface:[[:space:]]*[^[:space:]].*$/) {
          rs_change_surface = 1
        } else if ($0 ~ /^- in-scope:[[:space:]]*[^[:space:]].*$/) {
          rs_in_scope = 1
        } else if ($0 ~ /^- out-of-scope:[[:space:]]*[^[:space:]].*$/) {
          rs_out_of_scope = 1
        } else if ($0 ~ /^- 対象 hunk \/ ownership:[[:space:]]*[^[:space:]].*$/) {
          rs_target_hunk = 1
        } else if ($0 ~ /^- evidence destination:[[:space:]]*[^[:space:]].*$/) {
          rs_evidence_destination = 1
        } else if ($0 ~ /^- completion boundary:[[:space:]]*[^[:space:]].*$/) {
          rs_completion_boundary = 1
        }
      } else if (section == "class_closure_sheet") {
        if ($0 ~ /^- bug class:[[:space:]]*[^[:space:]].*$/) {
          ccs_bug_class = 1
        } else if ($0 ~ /^- task id:[[:space:]]*[^[:space:]].*$/) {
          ccs_task_id = 1
          ccs_task_id_value = strip_prefix($0, "^- task id:[[:space:]]*")
        } else if ($0 ~ /^- task lineage ledger entry:[[:space:]]*[^[:space:]].*$/) {
          ccs_task_lineage = 1
          ccs_task_lineage_value = strip_prefix($0, "^- task lineage ledger entry:[[:space:]]*")
        } else if ($0 ~ /^- prior task id:[[:space:]]*[^[:space:]].*$/) {
          ccs_prior_task_id = 1
          ccs_prior_task_id_value = strip_prefix($0, "^- prior task id:[[:space:]]*")
        } else if ($0 ~ /^- slice id:[[:space:]]*[^[:space:]].*$/) {
          ccs_slice_id = 1
          ccs_slice_id_value = strip_prefix($0, "^- slice id:[[:space:]]*")
        } else if ($0 ~ /^- change surface:[[:space:]]*[^[:space:]].*$/) {
          ccs_change_surface = 1
        } else if ($0 ~ /^- owned sink universe:[[:space:]]*[^[:space:]].*$/) {
          ccs_owned_sink_universe = 1
        } else if ($0 ~ /^- closed universe basis:[[:space:]]*[^[:space:]].*$/) {
          ccs_closed_universe_basis = 1
        } else if ($0 ~ /^- closed universe status:[[:space:]]*(YES|NO|n\/a)[[:space:]]*$/) {
          ccs_closed_universe_status = 1
          ccs_closed_universe_status_value = strip_prefix($0, "^- closed universe status:[[:space:]]*")
        } else if ($0 ~ /^- search method \/ exact commands:[[:space:]]*[^[:space:]].*$/) {
          ccs_search_method = 1
        } else if ($0 ~ /^- sheet status:[[:space:]]*(OPEN|CLOSED|RESET|n\/a)[[:space:]]*$/) {
          ccs_sheet_status = 1
          ccs_sheet_status_value = strip_prefix($0, "^- sheet status:[[:space:]]*")
        } else if ($0 ~ /^- last reset trigger:[[:space:]]*[^[:space:]].*$/) {
          ccs_last_reset_trigger = 1
        } else if ($0 ~ /^- remaining issues:[[:space:]]*[^[:space:]].*$/) {
          ccs_remaining_issues = 1
        } else if ($0 ~ /^- basis:[[:space:]]*[^[:space:]].*$/) {
          ccs_basis = 1
        } else if ($0 ~ /^- timestamp:[[:space:]]*[^[:space:]].*$/) {
          ccs_timestamp = 1
        } else if ($0 ~ /^- target scope:[[:space:]]*[^[:space:]].*$/) {
          ccs_target_scope = 1
        }
      } else if (section == "adversarial_pre_closure_pass") {
        if ($0 ~ /^- executed at:[[:space:]]*[^[:space:]].*$/) {
          apcp_executed_at = 1
        } else if ($0 ~ ("^- reviewer request target:[[:space:]]*(" accepted_review_request_targets_pattern ")[[:space:]]*$")) {
          apcp_review_target = 1
          apcp_review_target_value = strip_prefix($0, "^- reviewer request target:[[:space:]]*")
        } else if ($0 ~ /^- search commands:[[:space:]]*[^[:space:]].*$/) {
          apcp_search_commands = 1
        } else if ($0 ~ /^- opposite hypothesis checked:[[:space:]]*[^[:space:]].*$/) {
          apcp_opposite_hypothesis = 1
        } else if ($0 ~ /^- untouched owned surfaces checked:[[:space:]]*[^[:space:]].*$/) {
          apcp_untouched_surfaces = 1
        } else if ($0 ~ /^- boundary \/ fallback \/ alias paths checked:[[:space:]]*[^[:space:]].*$/) {
          apcp_boundary_paths = 1
        } else if ($0 ~ /^- new same-class sinks found:[[:space:]]*(YES|NO)[[:space:]]*$/) {
          apcp_new_same_class_sinks = 1
        } else if ($0 ~ /^- result:[[:space:]]*(PASS|RESET)[[:space:]]*$/) {
          apcp_result = 1
          apcp_result_value = strip_prefix($0, "^- result:[[:space:]]*")
        } else if ($0 ~ /^- result:[[:space:]]*NOT RUN[[:space:]]*$/) {
          apcp_result_not_run = 1
        }
      } else if (section == "required_verification") {
        if ($0 ~ /^- command:[[:space:]]*[^[:space:]].*$/) {
          rv_command = 1
        } else if ($0 ~ /^- result:[[:space:]]*(PASS|FAIL)[[:space:]]*$/) {
          rv_result = 1
          rv_result_value = strip_prefix($0, "^- result:[[:space:]]*")
        } else if ($0 ~ /^- result:[[:space:]]*NOT RUN[[:space:]]*$/) {
          rv_result_not_run = 1
        } else if ($0 ~ /^- covered scope:[[:space:]]*[^[:space:]].*$/) {
          rv_covered_scope = 1
        } else if ($0 ~ /^- artifact pointer:[[:space:]]*[^[:space:]].*$/) {
          rv_artifact_pointer = 1
        } else if ($0 ~ /^- no-artifact reason:[[:space:]]*[^[:space:]].*$/) {
          rv_no_artifact_reason = 1
        } else if ($0 ~ /^- artifact integrity:[[:space:]]*(complete|MISSING)[[:space:]]*$/) {
          rv_artifact_integrity = 1
          rv_artifact_integrity_value = strip_prefix($0, "^- artifact integrity:[[:space:]]*")
        }
      } else if (section == "worker_outcome_payload_reviewed") {
        if ($0 ~ /^- contract source:[[:space:]]*[^[:space:]].*$/) {
          wop_contract_source = 1
          wop_contract_source_value = strip_prefix($0, "^- contract source:[[:space:]]*")
        } else if (trim($0) == blocked_worker_outcome_intake_rule_line) {
          wop_intake_rule = 1
        } else if (worker_outcome_subsection == "diff") {
          if ($0 ~ /^- changed files:[[:space:]]*[^[:space:]].*$/) {
            wop_diff_changed_files = 1
          } else if ($0 ~ /^- evidence pointer:[[:space:]]*[^[:space:]].*$/) {
            wop_diff_evidence_pointer = 1
          } else if ($0 ~ /^- next action consistency:[[:space:]]*[^[:space:]].*$/) {
            wop_diff_next_action_consistency = 1
          }
        } else if (worker_outcome_subsection == "no_change") {
          if ($0 ~ /^- searched surface:[[:space:]]*[^[:space:]].*$/) {
            wop_no_change_searched_surface = 1
          } else if ($0 ~ /^- no-diff reason:[[:space:]]*[^[:space:]].*$/) {
            wop_no_change_reason = 1
          } else if ($0 ~ /^- search \/ verification evidence:[[:space:]]*[^[:space:]].*$/) {
            wop_no_change_evidence = 1
          } else if ($0 ~ /^- last-reviewed baseline:[[:space:]]*[^[:space:]].*$/) {
            wop_no_change_last_baseline = 1
          } else if ($0 ~ /^- closed-universe claim:[[:space:]]*(YES|NO|n\/a)[[:space:]]*$/) {
            wop_no_change_closed_universe_claim = 1
          }
        }
      } else if (section == "evidence_reviewed") {
        if ($0 ~ /^- diff:[[:space:]]*[^[:space:]].*$/) {
          er_diff = 1
        } else if ($0 ~ /^- change surface declaration:[[:space:]]*[^[:space:]].*$/) {
          er_change_surface_declaration = 1
        } else if ($0 ~ /^- scope declaration:[[:space:]]*[^[:space:]].*$/) {
          er_scope_declaration = 1
        } else if ($0 ~ /^- verification result:[[:space:]]*[^[:space:]].*$/) {
          er_verification_result = 1
        } else if ($0 ~ /^- evidence destination:[[:space:]]*[^[:space:]].*$/) {
          er_evidence_destination = 1
        } else if ($0 ~ /^- artifact:[[:space:]]*[^[:space:]].*$/) {
          er_artifact = 1
        }
      } else if (section == "unverified_areas") {
        if ($0 ~ /[^[:space:]]/) {
          unverified_areas_has_content = 1
        }
      } else if (section == "open_questions") {
        if ($0 ~ /[^[:space:]]/) {
          open_questions_has_content = 1
        }
      } else if (section == "verdict") {
        if ($0 ~ ("^[[:space:]]*-[[:space:]]*\\[[ xX]\\][[:space:]]*(" accepted_review_verdicts_pattern ")([[:space:]]|$)")) {
          verdict_label = strip_prefix($0, "^[[:space:]]*-[[:space:]]*\\[[ xX]\\][[:space:]]*")
          sub(/[[:space:]]+-[[:space:]].*$/, "", verdict_label)
          verdict_label = trim(verdict_label)
          projected_verdict_seen[verdict_label] = 1
        }
        if ($0 ~ ("^[[:space:]]*-[[:space:]]*\\[[xX]\\][[:space:]]*(" accepted_review_verdicts_pattern ")([[:space:]]|$)")) {
          verdict_selection_count++
          selected_verdict = strip_prefix($0, "^[[:space:]]*-[[:space:]]*\\[[xX]\\][[:space:]]*")
          sub(/[[:space:]]+-[[:space:]].*$/, "", selected_verdict)
          selected_verdict = trim(selected_verdict)
        }
      }
    }
    END {
      if (!(has_report && has_review_request && has_review_outcome && has_slice_contract && has_loop_budget_ledger && has_summary && has_findings && has_tests && has_review_scope && has_class_closure_sheet && has_adversarial_pre_closure_pass && has_required_verification && has_worker_outcome_payload_reviewed && has_evidence_reviewed && has_unverified_areas && has_open_questions && has_verdict)) {
        exit 1
      }
      if (!(rr_status && rr_task_id && rr_task_lineage && rr_prior_task_id && rr_slice_id && rr_prior_slice_id && rr_review_target && rr_discovery_owner && rr_bug_class_candidate && rr_worker_outcome && rr_request_objective && rr_invalid_intake_route)) {
        exit 1
      }
      if (!(ro_review_verdict && ro_next_status && ro_next_action)) {
        exit 1
      }
      if (!(sc_task_id && sc_task_lineage && sc_prior_task_id && sc_slice_id && sc_prior_slice_id && sc_review_target && sc_discovery_owner && sc_bug_class_candidate && sc_change_surface && sc_in_scope && sc_out_of_scope && sc_required_checks && sc_evidence_destination && sc_completion_boundary && sc_class_closure_sheet && sc_sheet_status && sc_owned_sink_universe && sc_closed_universe_status && sc_closed_universe_basis && sc_scope_delta && sc_reslice_delta_type && sc_reslice_delta_summary && sc_delta_evidence)) {
        exit 1
      }
      if (!(lbl_fix_review_loops && lbl_closure_resets && lbl_same_class_findings && lbl_reslice_count && lbl_cumulative_requests && lbl_cumulative_late_findings && lbl_cumulative_closure_resets && lbl_stall_budget && lbl_stall_budget_status)) {
        exit 1
      }
      if (!summary_has_content) {
        exit 1
      }
      if (!(findings_has_severity || findings_has_none)) {
        exit 1
      }
      if (!(tests_ran && tests_result) || tests_result_not_run) {
        exit 1
      }
      if (!(rs_change_surface && rs_in_scope && rs_out_of_scope && rs_target_hunk && rs_evidence_destination && rs_completion_boundary)) {
        exit 1
      }
      if (!(ccs_bug_class && ccs_task_id && ccs_task_lineage && ccs_prior_task_id && ccs_slice_id && ccs_change_surface && ccs_owned_sink_universe && ccs_closed_universe_basis && ccs_closed_universe_status && ccs_search_method && ccs_sheet_status && ccs_last_reset_trigger && ccs_remaining_issues && ccs_basis && ccs_timestamp && ccs_target_scope)) {
        exit 1
      }
      if (!(apcp_executed_at && apcp_review_target && apcp_search_commands && apcp_opposite_hypothesis && apcp_untouched_surfaces && apcp_boundary_paths && apcp_new_same_class_sinks && apcp_result) || apcp_result_not_run) {
        exit 1
      }
      if (!(rv_command && rv_result && rv_covered_scope && (rv_artifact_pointer || rv_no_artifact_reason) && rv_artifact_integrity) || rv_result_not_run) {
        exit 1
      }
      if (!(wop_contract_source && wop_intake_rule)) {
        exit 1
      }
      if (wop_contract_source_value != canonical_worker_outcome_contract_source) {
        exit 1
      }
      if (rr_worker_outcome_value == "DIFF") {
        if (!(has_diff_payload_reviewed && wop_diff_changed_files && wop_diff_evidence_pointer && wop_diff_next_action_consistency)) {
          exit 1
        }
      } else if (rr_worker_outcome_value == "NO-CHANGE") {
        if (!(has_no_change_payload_reviewed && wop_no_change_searched_surface && wop_no_change_reason && wop_no_change_evidence && wop_no_change_last_baseline && wop_no_change_closed_universe_claim)) {
          exit 1
        }
      } else {
        exit 1
      }
      if (!(er_diff && er_change_surface_declaration && er_scope_declaration && er_verification_result && er_evidence_destination && er_artifact)) {
        exit 1
      }
      if (!(unverified_areas_has_content && open_questions_has_content)) {
        exit 1
      }
      if (projected_verdict_required_count < 1) {
        exit 1
      }
      for (projected_verdict in projected_verdict_required) {
        if (!projected_verdict_seen[projected_verdict]) {
          exit 1
        }
        if (!(projected_verdict in projected_next_status) || projected_next_status[projected_verdict] == "") {
          exit 1
        }
      }
      if (verdict_selection_count != 1 || selected_verdict == "" || selected_verdict != ro_review_verdict_value) {
        exit 1
      }
      if (rr_task_id_value != sc_task_id_value || rr_task_id_value != ccs_task_id_value) {
        exit 1
      }
      if (rr_task_lineage_value != sc_task_lineage_value || rr_task_lineage_value != ccs_task_lineage_value) {
        exit 1
      }
      if (rr_prior_task_id_value != sc_prior_task_id_value || rr_prior_task_id_value != ccs_prior_task_id_value) {
        exit 1
      }
      if (rr_slice_id_value != sc_slice_id_value || rr_slice_id_value != ccs_slice_id_value) {
        exit 1
      }
      if (rr_prior_slice_id_value != sc_prior_slice_id_value) {
        exit 1
      }
      if (rr_review_target_value != sc_review_target_value || rr_review_target_value != apcp_review_target_value) {
        exit 1
      }
      if (rr_discovery_owner_value != sc_discovery_owner_value) {
        exit 1
      }
      if (rr_bug_class_candidate_value != sc_bug_class_candidate_value) {
        exit 1
      }
      if ((rr_status_value == lgtm_required_incoming_request_status && rr_review_target_value != lgtm_required_request_target) || (rr_review_target_value == lgtm_required_request_target && rr_status_value != lgtm_required_incoming_request_status)) {
        exit 1
      }

      if (!(selected_verdict in projected_next_status)) {
        exit 1
      }
      expected_next_status = projected_next_status[selected_verdict]
      if (expected_next_status == "" || ro_next_status_value != expected_next_status) {
        exit 1
      }
      if (rv_artifact_integrity_value == "MISSING" && selected_verdict != "BLOCK") {
        exit 1
      }
      if (rv_result_value == "FAIL" && selected_verdict != "BLOCK") {
        exit 1
      }
      if (selected_verdict == "LGTM") {
        if (!(rr_review_target_value == lgtm_required_request_target && rr_status_value == lgtm_required_incoming_request_status)) {
          exit 1
        }
        if (!(rv_result_value == lgtm_required_required_verification_result && rv_artifact_integrity_value == lgtm_required_artifact_integrity && tests_result_value == lgtm_required_tests_result && apcp_result_value == lgtm_required_adversarial_result)) {
          exit 1
        }
        if (!(rv_artifact_pointer && rv_artifact_pointer_value != "n/a")) {
          exit 1
        }
        if (!(sc_sheet_status_value == lgtm_required_slice_contract_sheet_status && ccs_sheet_status_value == lgtm_required_class_closure_sheet_status && sc_closed_universe_status_value == lgtm_required_slice_contract_closed_universe_status && ccs_closed_universe_status_value == lgtm_required_class_closure_closed_universe_status)) {
          exit 1
        }
      }
    }
  ' "$report_file" || return 1

  _review_report_required_verification_artifact_exists "$report_file" "$artifact_base_file" || return 1
  _review_report_final_lgtm_local_artifacts_exist "$report_file" "$artifact_base_file"
}

_validate_aggregated_review_output_format() {
  local reviews_file="$1"
  local current_section=""
  local saw_section=false
  local line=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^##[[:space:]]+.+_review_.+\.md[[:space:]]*$ ]]; then
      if [[ "$saw_section" == "true" && -n "$current_section" ]]; then
        _validate_single_review_report "$current_section" "$reviews_file" || {
          /bin/rm -f "$current_section" 2>/dev/null || true
          return 1
        }
        /bin/rm -f "$current_section" 2>/dev/null || true
      fi

      current_section=$(create_temp_file "review_section")
      : > "$current_section"
      saw_section=true
      continue
    fi

    if [[ "$saw_section" == "true" && -n "$current_section" ]]; then
      printf '%s\n' "$line" >> "$current_section"
    elif [[ -n "${line//[[:space:]]/}" ]]; then
      return 1
    fi
  done < "$reviews_file"

  if [[ "$saw_section" != "true" || -z "$current_section" ]]; then
    return 1
  fi

  _validate_single_review_report "$current_section" "$reviews_file"
  local ret=$?
  /bin/rm -f "$current_section" 2>/dev/null || true
  return $ret
}

validate_review_output_format() {
  local reviews_file="$1"

  if [[ -z "$reviews_file" || ! -r "$reviews_file" ]]; then
    return 1
  fi

  if grep -qE '^##[[:space:]]+.+_review_.+\.md[[:space:]]*$' "$reviews_file" 2>/dev/null; then
    _validate_aggregated_review_output_format "$reviews_file"
    return $?
  fi

  _validate_single_review_report "$reviews_file"
}

_extract_review_report_verdict() {
  local report_file="$1"
  local projection_path=""

  if [[ -z "$report_file" || ! -r "$report_file" ]]; then
    return 1
  fi

  projection_path="$(_review_contract_projection_path)" || return 1

  local in_verdict=false
  local selected_count=0
  local selected_verdict=""
  local line=""
  local candidate=""
  local in_review_outcome=false
  local review_outcome_verdict=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"

    if [[ "$line" =~ ^##[[:space:]]+Review[[:space:]]+Outcome[[:space:]]*$ ]]; then
      in_review_outcome=true
      in_verdict=false
      continue
    fi

    if [[ "$line" =~ ^##[[:space:]]+Verdict[[:space:]]*$ ]]; then
      in_verdict=true
      in_review_outcome=false
      continue
    fi

    if [[ "$line" =~ ^##[[:space:]] ]]; then
      in_verdict=false
      in_review_outcome=false
      continue
    fi

    if [[ "$in_review_outcome" == "true" ]] && [[ "$line" =~ ^-[[:space:]]review[[:space:]]verdict:[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
      candidate="${BASH_REMATCH[1]}"
      if _review_contract_value_allowed "$projection_path" '.reviewer_contract.accepted_review_verdicts' "$candidate"; then
        review_outcome_verdict="$candidate"
      fi
      continue
    fi

    if [[ "$in_verdict" == "true" ]] && [[ "$line" =~ ^[[:space:]]*-[[:space:]]*\[[xX]\][[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
      candidate="${BASH_REMATCH[1]}"
      candidate="${candidate%% - *}"
      if _review_contract_value_allowed "$projection_path" '.reviewer_contract.accepted_review_verdicts' "$candidate"; then
        selected_count=$((selected_count + 1))
        selected_verdict="$candidate"
      fi
    fi
  done < "$report_file"

  if [[ "$selected_count" -eq 1 && -n "$selected_verdict" && -n "$review_outcome_verdict" && "$selected_verdict" == "$review_outcome_verdict" ]]; then
    printf '%s\n' "$selected_verdict"
    return 0
  fi

  return 1
}

# Shadow Verifyゲート（Layer 3）
# Usage: run_shadow_verify_gate <tmpdir> <phase> <iteration>
# Returns: 0 if pass/skip, 1 if failed (stdout: fix用レビュー擬似ファイルパス)
run_shadow_verify_gate() {
  local tmpdir="$1"
  local phase="$2"
  local iteration="$3"

  if [[ ! -f "$SHADOW_VERIFY_SCRIPT" ]]; then
    return 0
  fi

  local result_json=""
  local shadow_exit=0
  result_json=$(bash "$SHADOW_VERIFY_SCRIPT" run --phase "$phase" --iter "$iteration" --workdir "$REPO_ROOT" --gate "$GATE" --state-file "$STATE_FILE") || shadow_exit=$?

  if [[ -z "$result_json" ]]; then
    result_json=$(jq -n \
      --arg status "fail" \
      --arg phase "$phase" \
      --argjson iteration "$iteration" \
      --arg reason "shadow_verify_no_output" \
      '{status:$status, phase:$phase, iteration:$iteration, reason:$reason}')
  fi

  local shadow_json_file="$tmpdir/${phase}_shadow_verify_iter${iteration}.json"
  printf '%s\n' "$result_json" > "$shadow_json_file"

  local status
  status=$(jq -r '.status // "fail"' <<< "$result_json" 2>/dev/null || echo "fail")

  if [[ "$shadow_exit" -eq 0 && "$status" == "pass" ]]; then
    log_info "Shadow Verify passed (iteration=$iteration)"
    return 0
  fi

  local diagnostics details reason
  diagnostics=$(jq -r '.diagnostics // empty' <<< "$result_json" 2>/dev/null || true)
  details=$(jq -r '.details // empty' <<< "$result_json" 2>/dev/null || true)
  reason=$(jq -r '.reason // "shadow_verify_failed"' <<< "$result_json" 2>/dev/null || echo "shadow_verify_failed")

  local feedback_file="$tmpdir/${phase}_shadow_verify_iter${iteration}_reviews.md"
  {
    printf "[High] Shadow Verify: Mechanical verification failed\n"
    printf "  File: shadow_verify\n"
    printf "  Line: n/a\n"
    printf "  Issue: shadow_verify_run failed before reviewer execution (iteration=%s, reason=%s).\n" "$iteration" "$reason"
    printf "  Suggestion: Fix lint/typecheck/test/quality-gate failures and rerun.\n"
    if [[ -n "$diagnostics" ]]; then
      printf "  Diagnostics: %s\n" "$diagnostics"
    fi

    if [[ -n "$diagnostics" && -f "$diagnostics" ]]; then
      printf "  Diagnostics artifact: %s\n" "$diagnostics"
    elif [[ -n "$details" && -f "$details" ]]; then
      printf "  Details artifact: %s\n" "$details"
    fi
  } > "$feedback_file"

  state_set_error "SHADOW_VERIFY_FAILED" "Shadow Verify failed (iter=$iteration). See: $feedback_file" "$phase"
  state_save

  log_warn "Shadow Verify failed (iteration=$iteration). Fix required before reviewer."
  printf '%s\n' "$feedback_file"
  return 1
}

# レビュー結果からブロッカー（High重大度）を検出
has_blockers() {
  local reviews_file="$1"
  if [[ ! -f "$reviews_file" ]]; then
    return 1
  fi
  # [High] タグを検索
  grep -qi '\[High\]' "$reviews_file" 2>/dev/null
}

# レビュー結果から指定レベルまでの問題を検出
# Usage: has_issues <reviews_file> <level>
# level: high, medium, low, all
# Returns: 0 if issues found, 1 if no issues found
# Note: dies if file doesn't exist (that's an error, not "no issues")
has_issues() {
  local reviews_file="$1"
  local level="${2:-high}"

  if [[ -z "$reviews_file" ]]; then
    die "has_issues: reviews_file is required"
  fi

  if [[ ! -f "$reviews_file" ]]; then
    die "has_issues: reviews file not found: $reviews_file"
  fi

  if [[ ! -r "$reviews_file" ]]; then
    die "has_issues: cannot read reviews file: $reviews_file"
  fi

  local ret=1  # デフォルト: 問題なし
  case "$level" in
    high)
      grep -qi '\[High\]' "$reviews_file" 2>/dev/null && ret=0
      ;;
    medium)
      grep -qiE '\[High\]|\[Medium\]' "$reviews_file" 2>/dev/null && ret=0
      ;;
    low|all)
      grep -qiE '\[High\]|\[Medium\]|\[Low\]' "$reviews_file" 2>/dev/null && ret=0
      ;;
    *)
      log_warn "has_issues: unknown level: $level, defaulting to high"
      grep -qi '\[High\]' "$reviews_file" 2>/dev/null && ret=0
      ;;
  esac

  # タグフォーマット警告（戻り値に影響しない）
  if [[ $ret -ne 0 ]]; then
    if ! grep -qiE '\[High\]|\[Medium\]|\[Low\]' "$reviews_file" 2>/dev/null \
      && ! _review_report_findings_has_none "$reviews_file" 2>/dev/null \
      && ! grep -q '^# Code Review Report[[:space:]]*$' "$reviews_file" 2>/dev/null; then
      log_warn "has_issues: Review file may have non-standard format. Expected Code Review Report contract."
    fi
  fi

  return $ret
}

# 重大度別カウントを取得してログ出力
# Usage: show_issue_counts <reviews_file>
show_issue_counts() {
  local reviews_file="$1"

  if [[ ! -f "$reviews_file" ]]; then
    return
  fi

  local high_count medium_count low_count
  if _populate_review_severity_counts "$reviews_file" high_count medium_count low_count; then
    log_info "Issue counts: [High]=$high_count [Medium]=$medium_count [Low]=$low_count"
    return
  fi

  log_warn "Issue counts suppressed because reviewer output failed validation: $reviews_file"
  log_info "Issue counts: [High]=0 [Medium]=0 [Low]=0"
}

count_review_severity_matches() {
  local pattern="$1"
  local reviews_file="$2"
  local count

  if [[ -z "$reviews_file" || ! -r "$reviews_file" ]]; then
    printf '0\n'
    return 0
  fi

  if ! _review_severity_counts_source_is_countable "$reviews_file"; then
    printf '0\n'
    return 0
  fi

  count=$(grep -ci "$pattern" "$reviews_file" 2>/dev/null || true)
  [[ "$count" =~ ^[0-9]+$ ]] || count=0
  printf '%s\n' "$count"
}

_shadow_verify_feedback_extract_iteration() {
  local reviews_file="$1"
  local base_name=""

  if [[ -z "$reviews_file" ]]; then
    return 1
  fi

  base_name=$(basename "$reviews_file")
  if [[ "$base_name" =~ ^.+_shadow_verify_iter([0-9]+)_reviews\.md$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
    return 0
  fi

  return 1
}

_shadow_verify_feedback_has_canonical_shape() {
  local reviews_file="$1"

  if [[ -z "$reviews_file" || ! -r "$reviews_file" ]]; then
    return 1
  fi

  _shadow_verify_feedback_extract_iteration "$reviews_file" >/dev/null 2>&1 || return 1
  grep -Fxq '[High] Shadow Verify: Mechanical verification failed' "$reviews_file" 2>/dev/null || return 1
  grep -Eq '^  File: shadow_verify$' "$reviews_file" 2>/dev/null || return 1
  grep -Eq '^  Line: n/a$' "$reviews_file" 2>/dev/null || return 1
  grep -Eq '^  Issue: shadow_verify_run failed before reviewer execution \(iteration=[0-9]+, reason=.*\)\.$' "$reviews_file" 2>/dev/null || return 1
  grep -Eq '^  Suggestion: Fix lint/typecheck/test/quality-gate failures and rerun\.$' "$reviews_file" 2>/dev/null || return 1
}

_shadow_verify_feedback_is_valid_source() {
  local tmpdir="$1"
  local phase="$2"
  local reviews_file="$3"
  local expected_iteration="${4:-}"
  local detected_iteration=""
  local expected_base_name=""
  local shadow_json_file=""

  if ! _shadow_verify_feedback_has_canonical_shape "$reviews_file"; then
    return 1
  fi

  detected_iteration=$(_shadow_verify_feedback_extract_iteration "$reviews_file") || return 1

  if [[ "$expected_iteration" =~ ^[0-9]+$ ]] && [[ "$detected_iteration" != "$expected_iteration" ]]; then
    return 1
  fi

  expected_base_name="${phase}_shadow_verify_iter${detected_iteration}_reviews.md"
  if [[ "$(basename "$reviews_file")" != "$expected_base_name" ]]; then
    return 1
  fi

  shadow_json_file="$tmpdir/${phase}_shadow_verify_iter${detected_iteration}.json"
  [[ -f "$shadow_json_file" ]]
}

_review_severity_counts_source_is_countable() {
  local reviews_file="$1"

  if [[ -z "$reviews_file" || ! -r "$reviews_file" ]]; then
    return 1
  fi

  if validate_review_output_format "$reviews_file"; then
    return 0
  fi

  _shadow_verify_feedback_has_canonical_shape "$reviews_file"
}

_populate_review_severity_counts() {
  local reviews_file="$1"
  local high_var_name="$2"
  local medium_var_name="$3"
  local low_var_name="$4"
  local computed_high_count=0
  local computed_medium_count=0
  local computed_low_count=0

  if _review_severity_counts_source_is_countable "$reviews_file"; then
    computed_high_count=$(grep -ci '\[High\]' "$reviews_file" 2>/dev/null || true)
    computed_medium_count=$(grep -ci '\[Medium\]' "$reviews_file" 2>/dev/null || true)
    computed_low_count=$(grep -ci '\[Low\]' "$reviews_file" 2>/dev/null || true)
  else
    printf -v "$high_var_name" '%s' "$computed_high_count"
    printf -v "$medium_var_name" '%s' "$computed_medium_count"
    printf -v "$low_var_name" '%s' "$computed_low_count"
    return 1
  fi

  [[ "$computed_high_count" =~ ^[0-9]+$ ]] || computed_high_count=0
  [[ "$computed_medium_count" =~ ^[0-9]+$ ]] || computed_medium_count=0
  [[ "$computed_low_count" =~ ^[0-9]+$ ]] || computed_low_count=0

  printf -v "$high_var_name" '%s' "$computed_high_count"
  printf -v "$medium_var_name" '%s' "$computed_medium_count"
  printf -v "$low_var_name" '%s' "$computed_low_count"
}

_sanitize_shadow_verify_scalar() {
  local value="${1:-}"

  value=$(printf '%s' "$value" | tr '\r\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ $//')
  if [[ -z "$value" ]]; then
    return 0
  fi

  if printf '%s\n' "$value" | grep -qE '<subagent_notification>|</subagent_notification>|"author"[[:space:]]*:|"recipient"[[:space:]]*:|"other_recipients"[[:space:]]*:|"trigger_turn"[[:space:]]*:'; then
    printf '%s\n' '[redacted: transport markers removed]'
    return 0
  fi

  printf '%s\n' "$value"
}

_render_shadow_verify_feedback_for_escalation() {
  local tmpdir="$1"
  local phase="$2"
  local reviews_file="$3"
  local iteration="${4:-}"
  local shadow_iteration="$iteration"
  local shadow_json_file=""
  local reason="shadow_verify_failed"
  local diagnostics_path=""
  local details_path=""
  local artifact_path=""
  local shadow_meta=""

  if [[ ! "$shadow_iteration" =~ ^[0-9]+$ ]]; then
    shadow_iteration=$(_shadow_verify_feedback_extract_iteration "$reviews_file" 2>/dev/null || true)
  fi

  if [[ "$shadow_iteration" =~ ^[0-9]+$ ]]; then
    shadow_json_file="$tmpdir/${phase}_shadow_verify_iter${shadow_iteration}.json"
  fi

  if [[ -n "$shadow_json_file" && -f "$shadow_json_file" ]]; then
    reason=$(jq -r '.reason // "shadow_verify_failed"' "$shadow_json_file" 2>/dev/null || echo "shadow_verify_failed")
    diagnostics_path=$(jq -r '.diagnostics // empty' "$shadow_json_file" 2>/dev/null || true)
    details_path=$(jq -r '.details // empty' "$shadow_json_file" 2>/dev/null || true)
    shadow_meta=$(_reviewer_collect_shadow_verify_section "$tmpdir" "$phase" "${phase}_iter${shadow_iteration}" 2>/dev/null || true)
  fi

  reason=$(_sanitize_shadow_verify_scalar "$reason")
  shadow_meta=$(_sanitize_shadow_verify_scalar "$shadow_meta")

  if [[ -n "$diagnostics_path" && -f "$diagnostics_path" ]]; then
    artifact_path="$diagnostics_path"
  elif [[ -n "$details_path" && -f "$details_path" ]]; then
    artifact_path="$details_path"
  fi

  printf "[High] Shadow Verify: Mechanical verification failed\n"
  printf -- "- relay mode: sanitized shadow-verify feedback\n"
  printf -- "- source artifact: %s\n" "$reviews_file"
  printf -- "- issue: shadow_verify_run failed before reviewer execution (iteration=%s, reason=%s).\n" "${shadow_iteration:-n/a}" "${reason:-shadow_verify_failed}"
  printf -- "- suggestion: Fix lint/typecheck/test/quality-gate failures and rerun.\n"
  if [[ -n "$artifact_path" ]]; then
    printf -- "- diagnostics artifact: %s\n" "$artifact_path"
  fi
  if [[ -n "$shadow_meta" ]]; then
    printf -- "- shadow verify meta: %s\n" "$shadow_meta"
  fi
}

# エスカレーションレポート生成
# Usage: generate_escalation_report <tmpdir> <phase> <reviews_file> <iteration>
# Returns: レポートファイルパス
generate_escalation_report() {
  local tmpdir="$1"
  local phase="$2"
  local reviews_file="$3"
  local iteration="$4"
  local timestamp
  timestamp=$(date -u +"%Y%m%dT%H%M%SZ")  # ファイル名用

  local report_file="$tmpdir/${phase}_escalation_report_${timestamp}.md"

  # Issue counts 事前計算
  local high_count=0 medium_count=0 low_count=0
  local source_kind="invalid-reviewer-payload"
  local severity_counts_status="suppressed (invalid reviewer payload)"
  if [[ -n "$reviews_file" && -r "$reviews_file" ]] && validate_review_output_format "$reviews_file"; then
    source_kind="reviewer-output"
    severity_counts_status="trusted reviewer output"
  elif _shadow_verify_feedback_is_valid_source "$tmpdir" "$phase" "$reviews_file" "$iteration"; then
    source_kind="shadow-verify"
    severity_counts_status="sanitized shadow-verify feedback"
  fi

  if [[ "$source_kind" != "invalid-reviewer-payload" ]]; then
    if ! _populate_review_severity_counts "$reviews_file" high_count medium_count low_count; then
      high_count=0
      medium_count=0
      low_count=0
    fi
  fi

  {
    printf "# Escalation Report\n\n"
    printf "## Quick Summary\n"
    printf "| Severity | Count |\n"
    printf "|----------|-------|\n"
    printf "| [High]   | %d    |\n" "$high_count"
    printf "| [Medium] | %d    |\n" "$medium_count"
    printf "| [Low]    | %d    |\n\n" "$low_count"
    printf "## Context\n"
    printf -- "- **Phase**: %s\n" "$phase"
    printf -- "- **Iterations Attempted**: %s / %s\n" "$iteration" "$MAX_ITERATIONS"
    printf -- "- **Timestamp**: %s\n" "$(get_timestamp)"
    printf -- "- **Status**: FAILED - Issues remain after maximum iterations\n\n"
    printf -- "- **Severity Count Source**: %s\n\n" "$severity_counts_status"
    printf "## State Information\n"
    printf -- "- **State File**: %s\n" "$STATE_FILE"
    printf -- "- **Plan File**: %s\n" "$PLAN"
    printf -- "- **Coder Output**: %s\n\n" "${CODER_OUT:-N/A}"
    printf "## Git Status\n"
    printf '```\n'
    git status --porcelain 2>/dev/null || printf "(git status unavailable)\n"
    printf '```\n\n'
    printf "## Git Diff Summary\n"
    printf '```\n'
    git diff --stat HEAD 2>/dev/null || printf "(git diff unavailable)\n"
    printf '```\n\n'
    printf "## Remaining Issues\n"
    if [[ -f "$reviews_file" && -r "$reviews_file" ]]; then
      if [[ "$source_kind" == "reviewer-output" ]]; then
        cat "$reviews_file"
      elif [[ "$source_kind" == "shadow-verify" ]]; then
        _render_shadow_verify_feedback_for_escalation "$tmpdir" "$phase" "$reviews_file" "$iteration"
      else
        printf -- "- relay mode: suppressed invalid reviewer payload\n"
        printf -- "- source artifact: %s\n" "$reviews_file"
        printf -- "- reason: reviewer output failed the active review-report contract; inspect the artifact directly instead of relaying raw payload content here.\n"
      fi
    else
      printf "(Reviews file not readable: %s)\n" "$reviews_file"
    fi
    printf "\n## Recommendation\n"
    printf "Human intervention required. Possible causes:\n"
    printf "1. Structural/architectural issues that cannot be auto-fixed\n"
    printf "2. Conflicting requirements\n"
    printf "3. Issues outside the scope of automated fixes\n"
  } > "$report_file"

  log_info "Escalation report generated: $report_file"
  echo "$report_file"
}

# 修正要求プロンプトを生成してCoderに再投入（セッション対応版）
run_fix_iteration() {
  local tmpdir="$1"
  local phase="$2"
  local plan="$3"
  local reviews="$4"
  local iteration="$5"
  local outfile="$tmpdir/${phase}_coder_fix${iteration}.md"

  log_info "Running fix iteration $iteration (fix-until: $FIX_UNTIL)..."

  local new_session_id=""

  # coder.sh の関数を使用してセッション継続で修正実行（7番目のパラメータにFIX_UNTILを追加）
  new_session_id=$(coder_run_fix "$plan" "$phase" "$reviews" "$iteration" "$outfile" "$SESSION_ID" "$FIX_UNTIL" "$CODER_ENGINE")

  # output/engine は常に記録し、session_id が取れた場合だけ scratch session も保存する
  coder_record_to_state "$phase" "$new_session_id" "$outfile" "$CODER_ENGINE"

  # セッションIDを更新
  if [[ -n "$new_session_id" ]]; then
    SESSION_ID="$new_session_id"
    log_info "Fix session recorded: $new_session_id (iteration: $iteration)"
  else
    log_warn "Fix session ID was not captured; recorded phase output and engine without session linkage"
  fi

  log_info "Fix output saved: $outfile"
  echo "$outfile"
}

# レビュワー実行（reviewer.sh の関数を使用、state.json に記録）
# Usage: run_reviewers <tmpdir> <phase> <coder_out> [suffix] [iteration]
# Returns: aggregated reviews file path (stdout), exit 1 on complete failure
run_reviewers() {
  local tmpdir="$1"
  local phase="$2"
  local coder_out="$3"
  local suffix="${4:-}"
  local iteration="${5:-1}"

  log_info "Running reviewers: $REVIEWERS (fix-until: $FIX_UNTIL)"

  # reviewer.sh の reviewer_run_all() を使用
  # task_tmpdir を渡してセッション継続を有効化
  local agg_file
  local reviewer_exit=0
  agg_file=$(reviewer_run_all "$REVIEWERS" "$coder_out" "$tmpdir" "$phase" "$suffix" "$CODEX_TIMEOUT" "$tmpdir") || reviewer_exit=$?

  # 全レビュワー失敗時はエラー
  if [[ $reviewer_exit -ne 0 ]]; then
    log_error "All reviewers failed. Cannot proceed with review cycle."
    state_set_error "REVIEWER_FAILED" "All reviewers failed" "$phase"
    state_save
    return 1
  fi

  # 集約ファイルの存在確認
  if [[ -z "$agg_file" || ! -f "$agg_file" ]]; then
    log_error "Aggregated reviews file not found: $agg_file"
    state_set_error "REVIEWER_FAILED" "Aggregated reviews file not found" "$phase"
    state_save
    return 1
  fi

  # RV-2: レビュー出力フォーマット強制（fail-closed）
  if ! validate_review_output_format "$agg_file"; then
    local invalid_msg
    invalid_msg="Invalid reviewer output format. Expected Code Review Report contract (see docs/roles/reviewer.md)"
    log_error "$invalid_msg"
    state_set_error "REVIEW_FORMAT_INVALID" "$invalid_msg (file: $agg_file)" "$phase"
    state_save
    return 1
  fi

  # 重大度別カウントを表示
  show_issue_counts "$agg_file"

  # state.json に記録（reviewer_record_to_stateはstateを変更するが保存しない）
  reviewer_record_to_state "$phase" "$iteration" "$agg_file"
  state_save  # 一括保存

  echo "$agg_file"
}

main() {
  parse_args "$@"

  # --recover モードの処理（他の処理より先に実行）
  if [[ "$RECOVER_MODE" == "true" ]]; then
    if [[ -z "$RESUME_STATE" ]]; then
      die "--recover requires --resume to specify the state file"
    fi

    if [[ ! -f "$RESUME_STATE" ]]; then
      die "State file not found: $RESUME_STATE"
    fi

    recover_stale_state "$RESUME_STATE"
    exit 0
  fi

  # 通常実行時: stale チェック（--resume 指定時のみ）
  if [[ -n "$RESUME_STATE" && -f "$RESUME_STATE" ]]; then
    if is_state_stale "$RESUME_STATE"; then
      die "State file appears stale (not updated for over 1 hour). Use --recover --resume STATE_FILE to cleanup, or delete the state file manually."
    fi
  fi

  local task
  task="$(basename "$PLAN")"
  task="${task%.*}"
  local tmpdir="$TMP_BASE/$task"
  mkdir -p "$tmpdir"

  # ロック取得（同時実行防止）
  acquire_lock "$tmpdir"

  # State 初期化（新規実行時のみ）
  if [[ -z "$RESUME_STATE" ]]; then
    state_init "$PLAN" "$task" "$tmpdir"
    state_upsert_phase "$PHASE" "$MAX_ITERATIONS"
  fi

  persist_coder_engine_assignment "$CODER_ENGINE"

  # 全体ステータスを running に
  state_set '.status' '"running"'
  state_set_phase_status "$PHASE" "running"
  state_save

  if [[ -z "$CODER_OUT" ]]; then
    CODER_OUT="$tmpdir/${PHASE}_coder.md"
  fi

  # --run-coder が指定されている場合はCoderを起動
  if [[ "$RUN_CODER" == "true" ]] && [[ ! -f "$CODER_OUT" ]]; then
    _prepare_task_contract_for_coder_launch "$tmpdir" "$PHASE" "$PLAN" "$task"
    _prepare_orchestration_packet_for_coder_launch "$tmpdir" "$PHASE" "$PLAN"

    # Layer統合: Coder実行前に協調コンテキストを準備
    prepare_coordination_context "$tmpdir" "$PHASE" "$task"
    coordination_context_prepared=true

    # 動的エージェント戦略（--agent-strategy dynamic の場合）
    if [[ "$AGENT_STRATEGY" == "dynamic" ]]; then
      log_info "Using dynamic agent strategy..."
      local recommended_coders
      recommended_coders=$(coder_log_strategy "$PLAN" "$MAX_CODERS")

      # Note: 現時点では単一Coderのみサポート
      # 将来の拡張で複数Coderの並列実行をサポート予定
      if [[ $recommended_coders -gt 1 ]]; then
        log_info "Multiple coders recommended ($recommended_coders), but currently using single coder"
        log_info "Parallel coder execution will be available in a future release"
      fi
    fi

    CODER_OUT=$(run_coder "$tmpdir" "$PHASE" "$PLAN")
    # 注: セッション情報は run_coder() 内で coder_record_to_state() により記録済み
    state_save

    # Coder完了後にバッチレビューを実行（キューに蓄積された変更をレビュー）
    if command -v codex >/dev/null 2>&1; then
      local batch_review_result
      batch_review_result=$(run_batch_review "$tmpdir" "$PHASE")
      if [[ -n "$batch_review_result" ]] && [[ -f "$batch_review_result" ]]; then
        log_info "Batch review saved: $batch_review_result"
        # バッチレビュー結果にブロッカーがあればログ出力
        if has_blockers "$batch_review_result"; then
          log_warn "Batch review found blockers. See: $batch_review_result"
        fi
      fi
    fi
  fi

  if [[ ! -f "$CODER_OUT" ]]; then
    cat <<EOF
[HINT] Coder 出力が見つかりません: $CODER_OUT
次のいずれかを実行してください:
  1) --run-coder オプションを追加して自動起動
  2) 選択した Coder engine ($(_coder_engine_label "$CODER_ENGINE")) に以下を渡し、結果を手動保存:
     - プロンプト: docs/prompts/coder_phase_${PHASE}.md
     - 保存先: $CODER_OUT
EOF
    state_set '.status' '"paused"'
    state_save
    exit 0
  fi

  if [[ "$coordination_context_prepared" != "true" ]]; then
    prepare_coordination_context "$tmpdir" "$PHASE" "$task"
    coordination_context_prepared=true
  fi

  # Run reviewers
  if ! command -v codex >/dev/null 2>&1; then
    log_warn "codex CLI が見つかりません。レビュー反復をスキップします。"
  else
    local current_coder_out="$CODER_OUT"
    local iteration=0
    local reviews_file
    local phase_idx
    phase_idx=$(state_find_phase "$PHASE")

    log_info "Fix-until level: $FIX_UNTIL (will iterate until no [$FIX_UNTIL] or higher issues remain)"

    # =====================================================
    # レビュー完了保証ループ
    # =====================================================
    # 保証事項:
    #   1. 各イテレーションは必ずレビューで開始
    #   2. 問題がなければ即座にSUCCESS終了
    #   3. 最大イテレーション到達時は最終レビュー後にFAIL
    #   4. 修正は1〜(MAX-1)回目のイテレーション後にのみ実行
    #
    # フロー例 (MAX_ITERATIONS=5):
    #   iter 1: レビュー → 問題あり → 修正
    #   iter 2: レビュー → 問題あり → 修正
    #   iter 3: レビュー → 問題あり → 修正
    #   iter 4: レビュー → 問題あり → 修正
    #   iter 5: レビュー → 問題あり → ESCALATION (FAIL)
    #         or レビュー → 問題なし → SUCCESS
    # =====================================================
    while [[ $iteration -lt $MAX_ITERATIONS ]]; do
      iteration=$((iteration + 1))
      log_info "=== Review Iteration $iteration / $MAX_ITERATIONS (fix-until: $FIX_UNTIL) ==="

      # イテレーション番号を state に記録
      state_set ".phases[$phase_idx].iteration" "$iteration"
      state_set_phase_status "$PHASE" "review"
      state_save

      local suffix=""
      [[ $iteration -gt 1 ]] && suffix="_iter${iteration}"

      # Shadow Verify ゲート（coder -> shadow_verify -> reviewer）
      local shadow_feedback_file=""
      local shadow_verify_exit=0
      shadow_feedback_file=$(run_shadow_verify_gate "$tmpdir" "$PHASE" "$iteration") || shadow_verify_exit=$?
      if [[ $shadow_verify_exit -ne 0 ]]; then
        finalize_coordination_context "$tmpdir" "$PHASE" "$iteration"

        if [[ $iteration -ge $MAX_ITERATIONS ]]; then
          log_error "=============================================="
          log_error "ESCALATION: Max iterations ($MAX_ITERATIONS) reached"
          log_error "Shadow Verify failed repeatedly before reviewer stage"
          log_error "=============================================="

          local shadow_escalation_report
          shadow_escalation_report=$(generate_escalation_report "$tmpdir" "$PHASE" "$shadow_feedback_file" "$iteration")

          state_set_phase_status "$PHASE" "escalated"
          state_set_error "ESCALATION" "Shadow Verify failed repeatedly (report: $shadow_escalation_report)" "$PHASE"
          state_set ".phases[$(state_find_phase "$PHASE")].escalation_report" "\"$shadow_escalation_report\""
          state_set '.status' '"failed"'
          state_save
          break
        fi

        if [[ "$RUN_CODER" == "true" ]]; then
          state_set_phase_status "$PHASE" "fixing"
          state_save

          log_info "Shadow Verify failed. Running fix iteration before reviewer..."
          current_coder_out=$(run_fix_iteration "$tmpdir" "$PHASE" "$PLAN" "$shadow_feedback_file" "$iteration")

          # fix iteration後も次ループ先頭で Shadow Verify を再通過してから reviewer へ進む
          local shadow_fix_batch_review
          shadow_fix_batch_review=$(run_batch_review "$tmpdir" "$PHASE")
          if [[ -n "$shadow_fix_batch_review" ]] && [[ -f "$shadow_fix_batch_review" ]]; then
            log_info "Fix batch review saved: $shadow_fix_batch_review"
          fi
          continue
        else
          log_info "Shadow Verify failed. Manual fix required before reviewer."
          log_info "Shadow diagnostics review: $shadow_feedback_file"
          state_set '.status' '"paused"'
          state_save
          break
        fi
      fi

      # 動的レビュワー選択（--reviewer-strategy auto の場合）
      if [[ "$REVIEWER_STRATEGY" == "auto" ]]; then
        log_info "Using dynamic reviewer selection..."
        REVIEWERS=$(reviewer_select_dynamic "$current_coder_out")
        log_info "Selected reviewers: $REVIEWERS"
      fi

      # イテレーション番号を run_reviewers に渡す
      local run_reviewers_exit=0
      reviews_file=$(run_reviewers "$tmpdir" "$PHASE" "$current_coder_out" "$suffix" "$iteration") || run_reviewers_exit=$?

      # レビュワー実行失敗時はループ終了
      if [[ $run_reviewers_exit -ne 0 ]]; then
        log_error "Reviewers failed. Exiting review cycle."
        finalize_coordination_context "$tmpdir" "$PHASE" "$iteration"
        state_set_phase_status "$PHASE" "failed"
        state_save
        break
      fi

      # Layer統合: reviewer_run_all 後に coordination context を確定
      finalize_coordination_context "$tmpdir" "$PHASE" "$iteration"

      # 指定レベルまでの問題がなくなったかチェック
      if ! has_issues "$reviews_file" "$FIX_UNTIL"; then
        log_info "No issues found at level [$FIX_UNTIL] or higher. Review cycle complete."
        _coordination_require_src_sync_freshness "$PHASE" "phase completed"
        state_set_phase_status "$PHASE" "completed"
        state_save
        break
      fi

      if [[ $iteration -ge $MAX_ITERATIONS ]]; then
        log_error "=============================================="
        log_error "ESCALATION: Max iterations ($MAX_ITERATIONS) reached"
        log_error "Issues remain at level [$FIX_UNTIL]"
        log_error "=============================================="

        # エスカレーションレポート生成
        local escalation_report
        escalation_report=$(generate_escalation_report "$tmpdir" "$PHASE" "$reviews_file" "$iteration")

        log_error ""
        log_error ">>> HUMAN INTERVENTION REQUIRED <<<"
        log_error "Escalation report: $escalation_report"
        show_issue_counts "$reviews_file"

        # ステータス更新
        state_set_phase_status "$PHASE" "escalated"
        state_set_error "ESCALATION" "Human intervention required (report: $escalation_report)" "$PHASE"
        state_set ".phases[$(state_find_phase "$PHASE")].escalation_report" "\"$escalation_report\""
        state_set '.status' '"failed"'
        state_save
        break
      fi

      # 修正要求を Coder に再投入
      if [[ "$RUN_CODER" == "true" ]]; then
        state_set_phase_status "$PHASE" "fixing"
        state_save

        log_info "Issues found. Running fix iteration..."
        current_coder_out=$(run_fix_iteration "$tmpdir" "$PHASE" "$PLAN" "$reviews_file" "$iteration")

        # 修正後にバッチレビューを実行
        local fix_batch_review
        fix_batch_review=$(run_batch_review "$tmpdir" "$PHASE")
        if [[ -n "$fix_batch_review" ]] && [[ -f "$fix_batch_review" ]]; then
          log_info "Fix batch review saved: $fix_batch_review"
        fi
      else
        log_info "Issues detected at level [$FIX_UNTIL]. Manual fix required."
        log_info "Reviews: $reviews_file"
        state_set '.status' '"paused"'
        state_save
        break
      fi
    done
  fi

  # Quality gate
  if [[ -n "$GATE" ]]; then
    state_set '.quality_gate.level' "\"$GATE\""
    state_set '.quality_gate.status' '"running"'
    state_save
    if [[ -x "$QUALITY_GATE" ]]; then
      log_info "Running quality gate: $GATE"
      if "$QUALITY_GATE" --level "$GATE"; then
        state_set '.quality_gate.status' '"passed"'
      else
        state_set '.quality_gate.status' '"failed"'
      fi
    else
      log_warn "quality_gate.sh not executable or missing: $QUALITY_GATE"
      state_set '.quality_gate.status' '"skipped"'
    fi
    state_save
  fi

  # 完了ステータス設定（paused の場合は上書きしない）
  local current_status
  current_status=$(state_get '.status')
  if [[ "$current_status" != "paused" ]]; then
    local final_status="completed"
    local phase_status
    phase_status=$(state_get ".phases[$(state_find_phase "$PHASE")].status")

    # failed AND escalated を確認
    if [[ "$phase_status" == "failed" || "$phase_status" == "escalated" ]]; then
      final_status="failed"
    fi

    if [[ "$final_status" == "completed" ]]; then
      _coordination_require_src_sync_freshness "$PHASE" "final completed status"
    fi

    state_set '.status' "\"$final_status\""
    state_save
  fi

  # ロック解放（正常終了時）
  release_lock

  log_info "=== Orchestration Complete ==="
  log_info "Outputs in: $tmpdir"
  log_info "State file: $STATE_FILE"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
