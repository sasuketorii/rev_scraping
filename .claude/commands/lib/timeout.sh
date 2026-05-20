#!/usr/bin/env bash
# timeout.sh - タイムアウト管理
# エージェント自動化システム用
#
# 依存: utils.sh, state.sh が先に読み込まれていること

# デフォルトタイムアウト設定
TIMEOUT_DEFAULT="${TIMEOUT_DEFAULT:-1800}"           # 30分
TIMEOUT_HEARTBEAT_INTERVAL="${TIMEOUT_HEARTBEAT_INTERVAL:-60}"  # 1分

# プロセスグループ終了（TERM → KILL 二段階）
# Usage: timeout_kill_group <pgid> [grace_secs]
# Returns: 0 on success
timeout_kill_group() {
  local pgid="$1"
  local grace_secs="${2:-2}"

  # Validate grace_secs is numeric
  if [[ ! "$grace_secs" =~ ^[0-9]+$ ]]; then
    grace_secs=2
  fi

  if [[ -z "$pgid" ]]; then
    log_warn "timeout_kill_group: pgid is required"
    return 1
  fi

  # PGIDが有効な数値かチェック
  if ! [[ "$pgid" =~ ^[0-9]+$ ]]; then
    log_warn "timeout_kill_group: invalid pgid: $pgid"
    return 1
  fi

  log_debug "Killing process group: $pgid"

  # 1. まず TERM シグナルで graceful shutdown を試みる
  kill -TERM -- -"$pgid" 2>/dev/null || true

  # 2. 少し待機（graceful shutdown の猶予）
  sleep "$grace_secs"

  # 3. プロセスグループ内にまだプロセスが生きていれば KILL で強制終了
  if kill -0 -- -"$pgid" 2>/dev/null; then
    log_debug "Process group still alive, sending KILL"
    kill -KILL -- -"$pgid" 2>/dev/null || true
  fi

  return 0
}

# タイムアウト付きコマンド実行（macOS/Linux対応、プロセスグループ完全対応）
# Usage: timeout_run <timeout_secs> COMMAND [ARGS...]
# Returns: command exit code, or 124 on timeout
# Note: 10分ごとに進捗ログを出力
timeout_run() {
  local timeout_secs="$1"
  shift
  local cmd=("$@")
  local pid
  local pgid
  local exit_code

  if [[ -z "$timeout_secs" || ! "$timeout_secs" =~ ^[0-9]+$ ]]; then
    log_error "timeout_run: invalid timeout_secs: $timeout_secs"
    return 1
  fi

  if [[ ${#cmd[@]} -eq 0 ]]; then
    log_error "timeout_run: no command specified"
    return 1
  fi

  # 新しいプロセスグループでコマンドを実行
  # setsid が利用可能ならそれを使用、なければ perl で代替（macOS対応）
  # フォールバック: 両方失敗時は通常実行（プロセスグループ制御は制限される）
  if command -v setsid >/dev/null 2>&1; then
    setsid "${cmd[@]}" &
    pid=$!
    pgid=$pid  # setsid 実行時は PID = PGID
  elif command -v perl >/dev/null 2>&1; then
    # macOS: perl を使って setsid 相当の処理
    # perl は macOS に標準搭載
    # セキュリティ注意: cmd 配列は -- 以降に渡され、perl の @ARGV 経由で exec される
    # シェルメタ文字は perl の exec がリスト形式で処理するため、シェル展開は発生しない
    perl -e '
      use POSIX qw(setsid);
      setsid() or die "setsid: $!";
      exec @ARGV or die "exec: $!";
    ' -- "${cmd[@]}" &
    pid=$!
    pgid=$pid
  else
    # setsid も perl も利用不可（極めて稀なケース）
    # 警告を出力し、通常のバックグラウンド実行にフォールバック
    # 注意: プロセスグループ終了が正常に機能しない可能性あり
    log_warn "setsid/perl unavailable: process group control may be limited"
    "${cmd[@]}" &
    pid=$!
    pgid=$pid  # 同一プロセスグループだが、-PGID での kill は動作しない可能性
  fi

  # タイムアウト監視（1秒ごとにチェック）
  local elapsed=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $elapsed -ge $timeout_secs ]]; then
      log_warn "Timeout after ${timeout_secs}s, killing process group $pgid"
      timeout_kill_group "$pgid"
      wait "$pid" 2>/dev/null || true
      return 124  # timeout の標準終了コード
    fi
    sleep 1
    elapsed=$((elapsed + 1))
    # 10分ごとに進捗表示
    if [[ $((elapsed % 600)) -eq 0 ]]; then
      log_info "Still running... ${elapsed}s / ${timeout_secs}s"
    fi
  done

  wait "$pid"
  exit_code=$?
  return $exit_code
}

# ハートビート付きタイムアウト実行
# 定期的に state.json を更新しながらコマンドを実行
# Usage: timeout_run_with_heartbeat <timeout_secs> <heartbeat_interval_secs> COMMAND [ARGS...]
# Returns: command exit code, or 124 on timeout
# Note: heartbeat_interval_secs ごとに state.json の updated_at を更新
timeout_run_with_heartbeat() {
  local timeout_secs="$1"
  local heartbeat_interval="${2:-$TIMEOUT_HEARTBEAT_INTERVAL}"
  shift 2
  local cmd=("$@")
  local pid
  local pgid
  local exit_code

  if [[ -z "$timeout_secs" || ! "$timeout_secs" =~ ^[0-9]+$ ]]; then
    log_error "timeout_run_with_heartbeat: invalid timeout_secs: $timeout_secs"
    return 1
  fi

  if [[ ${#cmd[@]} -eq 0 ]]; then
    log_error "timeout_run_with_heartbeat: no command specified"
    return 1
  fi

  # state.json が初期化されているか確認
  local has_state=false
  if [[ -n "${STATE_FILE:-}" && -f "${STATE_FILE:-}" ]]; then
    has_state=true
  fi

  # 新しいプロセスグループでコマンドを実行
  # setsid が利用可能ならそれを使用、なければ perl で代替（macOS対応）
  # フォールバック: 両方失敗時は通常実行（プロセスグループ制御は制限される）
  if command -v setsid >/dev/null 2>&1; then
    setsid "${cmd[@]}" &
    pid=$!
    pgid=$pid
  elif command -v perl >/dev/null 2>&1; then
    # セキュリティ注意: cmd 配列は -- 以降に渡され、perl の @ARGV 経由で exec される
    # シェルメタ文字は perl の exec がリスト形式で処理するため、シェル展開は発生しない
    perl -e '
      use POSIX qw(setsid);
      setsid() or die "setsid: $!";
      exec @ARGV or die "exec: $!";
    ' -- "${cmd[@]}" &
    pid=$!
    pgid=$pid
  else
    # setsid も perl も利用不可（極めて稀なケース）
    log_warn "setsid/perl unavailable: process group control may be limited"
    "${cmd[@]}" &
    pid=$!
    pgid=$pid
  fi

  # タイムアウト監視（1秒ごとにチェック、ハートビート間隔で state 更新）
  local elapsed=0
  local last_heartbeat=0
  while kill -0 "$pid" 2>/dev/null; do
    if [[ $elapsed -ge $timeout_secs ]]; then
      log_warn "Timeout after ${timeout_secs}s (with heartbeat), killing process group $pgid"
      timeout_kill_group "$pgid"
      wait "$pid" 2>/dev/null || true
      return 124
    fi

    # ハートビート: state.json を更新
    if [[ "$has_state" == "true" ]]; then
      local since_heartbeat=$((elapsed - last_heartbeat))
      if [[ $since_heartbeat -ge $heartbeat_interval ]]; then
        _heartbeat_update
        last_heartbeat=$elapsed
      fi
    fi

    sleep 1
    elapsed=$((elapsed + 1))

    # 10分ごとに進捗表示
    if [[ $((elapsed % 600)) -eq 0 ]]; then
      log_info "Still running (heartbeat mode)... ${elapsed}s / ${timeout_secs}s"
    fi
  done

  wait "$pid"
  exit_code=$?
  return $exit_code
}

# ハートビート更新（内部関数）
# WARNING: この関数はロックなしで state.json を更新する。
# 設計判断: ロック取得中にハートビートが止まることを避けるため意図的にロックなし。
# 競合リスク: state_set/state_save が同時実行された場合、片方の変更が失われる可能性がある。
# 許容理由: updated_at のみの更新であり、他フィールドは変更しない。
#           最悪ケースでもハートビート更新が消えるだけで、データ整合性は維持される。
_heartbeat_update() {
  if [[ -z "${STATE_FILE:-}" || ! -f "${STATE_FILE:-}" ]]; then
    return 0
  fi

  local now
  now=$(get_timestamp)
  local tmp_file
  tmp_file=$(create_temp_file "heartbeat")

  # ロックなしで updated_at のみ更新（上記警告参照）
  if jq --arg ts "$now" '.updated_at = $ts' "$STATE_FILE" > "$tmp_file" 2>/dev/null; then
    mv "$tmp_file" "$STATE_FILE" 2>/dev/null || rm -f "$tmp_file"
    log_debug "Heartbeat: state updated at $now"
  else
    rm -f "$tmp_file" 2>/dev/null || true
  fi
}

# タイムアウトチェック（経過時間ベース）
# Usage: timeout_check <start_timestamp> <timeout_secs>
# Returns: 0 if timed out, 1 if not
timeout_check() {
  local start_ts="$1"
  local timeout_secs="$2"

  if [[ -z "$start_ts" || -z "$timeout_secs" ]]; then
    return 1
  fi

  local now
  now=$(get_timestamp)
  local elapsed
  elapsed=$(date_diff_secs "$start_ts" "$now") || return 1

  if [[ $elapsed -ge $timeout_secs ]]; then
    return 0
  else
    return 1
  fi
}

# 残り時間取得
# Usage: timeout_remaining <start_timestamp> <timeout_secs>
# Returns: remaining seconds (stdout), or empty if calculation fails
timeout_remaining() {
  local start_ts="$1"
  local timeout_secs="$2"

  if [[ -z "$start_ts" || -z "$timeout_secs" ]]; then
    echo ""
    return 1
  fi

  local now
  now=$(get_timestamp)
  local elapsed
  elapsed=$(date_diff_secs "$start_ts" "$now") || { echo ""; return 1; }

  local remaining=$((timeout_secs - elapsed))
  if [[ $remaining -lt 0 ]]; then
    remaining=0
  fi

  echo "$remaining"
}

# Note: timeout_run_parallel は未使用のため削除 (YAGNI)
# 必要になった場合は git history から復元可能
