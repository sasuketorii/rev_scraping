#!/usr/bin/env bash
#
# codex-job.sh - Asynchronous job manager for codex-wrapper.sh
#
# Subcommands: start | status | wait | result | gc
#
# 目的:
#   codex-wrapper.sh を非同期に起動し、ジョブ ID を介して状態 / ログ /
#   exit code を後から取得可能にする。長時間ジョブを fire-and-forget で
#   発火し、ポーリングで結果を取得するワークフローを支える。
#
# Layout:
#   ${REV_HARNESS_RUN_DIR:-$HOME/.rev_harness}/jobs/<job-id>/
#     cmd          - 実行コマンドライン (debug/audit)
#     pid          - バックグラウンド PID
#     log          - stdout + stderr マージ
#     exit_code    - 完了時に書かれる exit code (presence == completed)
#     status.json  - { state, started_at, ended_at, exit_code, job_id, role, pid }
#
# 互換性: macOS bash 3.x (associative array 不使用)
# 関連: docs/plans/2026-05-reporting-reliability/plan-v4-final.md (PR#1)

set -euo pipefail

# 0.0.6 PR-A: 起動時に umask 077 で job artifact が他ユーザー読み取り不可に。
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR

# Vendoring 防止 guard
# shellcheck source=scripts/_canonical-guard.sh
source "${SCRIPT_DIR}/_canonical-guard.sh"
rev_harness_assert_canonical_root codex-job

# Shim log (既存互換)
# shellcheck source=scripts/_shim-log.sh
source "${SCRIPT_DIR}/_shim-log.sh"

readonly RUN_DIR="${REV_HARNESS_RUN_DIR:-${HOME}/.rev_harness}"
readonly JOBS_DIR="${RUN_DIR}/jobs"
readonly DEFAULT_WAIT_TIMEOUT=900
readonly DEFAULT_GC_TTL_DAYS=7
readonly POLL_INTERVAL=2
# 0.0.6 PR-A: gc --ttl 上限 (1 年)。これ以上は誤入力扱い。
readonly GC_TTL_MAX_DAYS=365
# 0.0.6 PR-A: job-id 形式制約 (16〜32 桁 hex)。現実装は 18 桁 hex。
readonly JOB_ID_REGEX='^[0-9a-f]{16,32}$'

# Exit codes
readonly EX_OK=0
readonly EX_USAGE=64
readonly EX_TIMEOUT=124

log_err() {
  echo "[codex-job] ERROR: $*" >&2
}

log_warn() {
  echo "[codex-job] WARN: $*" >&2
}

# ---- helpers ----------------------------------------------------------------

# ULID 風 job-id: 10 進 timestamp(秒) を 10桁hex + RANDOM 2 回を 6桁hex × 2
# = 22 文字。macOS bash 3.x 互換、外部依存なし。
gen_job_id() {
  local ts r1 r2
  ts=$(date -u +%s)
  r1=$RANDOM
  r2=$RANDOM
  printf '%010x%04x%04x\n' "$ts" "$r1" "$r2"
}

iso8601_now() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

# JSON 文字列の minimal エスケープ (バックスラッシュとダブルクォートのみ)
# 値は role 名や job-id など、制御文字を含まない前提
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

# atomic write: tmp に書いて mv
atomic_write() {
  local target="$1"
  local content="$2"
  local tmp="${target}.tmp.$$"
  printf '%s' "$content" > "$tmp"
  mv -f "$tmp" "$target"
}

# 0.0.6 PR-A: job-id を検証して run dir 配下の正規 path を返す。
# 違反は EX_USAGE で終了する。エコーは canonical job_dir。
resolve_job_dir() {
  local job_id="$1"
  if [[ -z "$job_id" ]]; then
    log_err "missing job-id"
    return $EX_USAGE
  fi
  if [[ ! "$job_id" =~ $JOB_ID_REGEX ]]; then
    log_err "invalid job-id format: ${job_id}"
    return $EX_USAGE
  fi
  # JOBS_DIR は内部生成 path のみで、外部入力は $job_id だけ。
  # 念のため `..` や `/` の混入は regex で既に排除済み。
  printf '%s/%s' "$JOBS_DIR" "$job_id"
}

# status.json を書き出す
# args: job_dir state role pid started_at ended_at exit_code
write_status() {
  local job_dir="$1"
  local state="$2"
  local role="$3"
  local pid="$4"
  local started_at="$5"
  local ended_at="$6"
  local exit_code="$7"
  local job_id
  job_id=$(basename "$job_dir")

  local ended_field exit_field
  if [[ -z "$ended_at" ]]; then
    ended_field='null'
  else
    ended_field=$(printf '"%s"' "$(json_escape "$ended_at")")
  fi
  if [[ -z "$exit_code" ]]; then
    exit_field='null'
  else
    exit_field="$exit_code"
  fi

  local json
  json=$(printf '{"job_id":"%s","state":"%s","role":"%s","pid":%d,"started_at":"%s","ended_at":%s,"exit_code":%s}\n' \
    "$(json_escape "$job_id")" \
    "$(json_escape "$state")" \
    "$(json_escape "$role")" \
    "$pid" \
    "$(json_escape "$started_at")" \
    "$ended_field" \
    "$exit_field")
  atomic_write "${job_dir}/status.json" "$json"
  # 0.0.6 PR-A: status.json の権限を 600 に固定。
  chmod 600 "${job_dir}/status.json" 2>/dev/null || true
}

# status.json から特定 key の値を抽出する。
# 文字列値はクォートを剥がして返し、数値・null はそのまま返す。
# 一行 JSON を前提 (本ファイルが書く JSON は常に 1 行)。
json_get() {
  local file="$1"
  local key="$2"
  awk -v key="\"${key}\"" '
    {
      # 検索開始位置
      idx = index($0, key)
      if (idx == 0) next
      rest = substr($0, idx + length(key))
      # コロンとスペースをスキップ
      sub(/^[ \t]*:[ \t]*/, "", rest)
      if (substr(rest, 1, 1) == "\"") {
        # 文字列値
        v = substr(rest, 2)
        # 終端の " (エスケープ未対応 — 本スクリプトは制御文字を書かないので OK)
        end = index(v, "\"")
        if (end > 0) v = substr(v, 1, end - 1)
        print v
      } else {
        # 数値 or null or true/false
        v = rest
        sub(/[,}].*/, "", v)
        gsub(/[ \t\r\n]/, "", v)
        print v
      }
      exit
    }
  ' "$file"
}

# PID が生きているかチェック (kill -0)
pid_alive() {
  local pid="$1"
  if [[ -z "$pid" || "$pid" == "0" ]]; then
    return 1
  fi
  kill -0 "$pid" 2>/dev/null
}

# job_dir の現在状態を再計算 (running か completed か) し status.json を更新
# 0.0.6 PR-A: PID 再利用回避のため、まず exit_code ファイル存在を確認してから
# pid_alive を見る。exit_code が書かれていれば子は完了済 (PID が他プロセスに
# 再利用されていても running と誤判定しない)。
refresh_status() {
  local job_dir="$1"
  if [[ ! -f "${job_dir}/status.json" ]]; then
    return 1
  fi
  local state pid role started_at
  state=$(json_get "${job_dir}/status.json" state)
  pid=$(json_get "${job_dir}/status.json" pid)
  role=$(json_get "${job_dir}/status.json" role)
  started_at=$(json_get "${job_dir}/status.json" started_at)
  [[ -z "$pid" || "$pid" == "null" ]] && pid=0

  if [[ "$state" != "running" ]]; then
    return 0
  fi

  # 完了優先: exit_code が書かれていれば pid に依らず完了扱い
  if [[ -f "${job_dir}/exit_code" ]]; then
    local exit_code ended_at new_state
    exit_code=$(cat "${job_dir}/exit_code")
    ended_at=$(iso8601_now)
    if [[ "$exit_code" == "0" ]]; then
      new_state="completed"
    else
      new_state="failed"
    fi
    write_status "$job_dir" "$new_state" "$role" "$pid" "$started_at" "$ended_at" "$exit_code"
    return 0
  fi

  # exit_code 未書込で、かつ pid が生きていれば本当に running
  if pid_alive "$pid"; then
    return 0
  fi

  # exit_code 不在 + pid 死亡 = 異常終了 (子が exit_code を書く前に死んだ)
  local ended_at
  ended_at=$(iso8601_now)
  write_status "$job_dir" "failed" "$role" "$pid" "$started_at" "$ended_at" "1"
}

# ---- subcommands ------------------------------------------------------------

cmd_start() {
  local role="standard"
  local prompt=""
  local prompt_from_stdin=true
  local keep_prompt=false
  local positional=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role)
        role="${2:?--role requires a value}"
        shift 2
        ;;
      --keep-prompt)
        # 0.0.6 PR-A: 完了時に prompt 本文を残す。デフォルトは削除。
        keep_prompt=true
        shift
        ;;
      -h|--help)
        usage; return 0
        ;;
      --)
        shift; break
        ;;
      -*)
        log_err "unknown option: $1"
        return $EX_USAGE
        ;;
      *)
        positional+=("$1"); shift
        ;;
    esac
  done

  if [[ ${#positional[@]} -gt 0 ]]; then
    prompt="${positional[*]}"
    prompt_from_stdin=false
  fi

  mkdir -p "$JOBS_DIR"
  chmod 700 "$JOBS_DIR" 2>/dev/null || true
  local job_id job_dir
  # 衝突回避ループ (max 5 回)
  local _i
  for _i in 1 2 3 4 5; do
    job_id=$(gen_job_id)
    job_dir="${JOBS_DIR}/${job_id}"
    if mkdir "$job_dir" 2>/dev/null; then
      break
    fi
    job_id=""
  done
  if [[ -z "$job_id" ]]; then
    log_err "failed to allocate unique job_id"
    return 1
  fi
  # 0.0.6 PR-A: job_dir は 700 で他ユーザー不可侵に。
  chmod 700 "$job_dir" 2>/dev/null || true

  # prompt を tmp に書き出す (stdin / 引数いずれも)
  local prompt_file="${job_dir}/prompt"
  if $prompt_from_stdin; then
    cat > "$prompt_file"
  else
    printf '%s' "$prompt" > "$prompt_file"
  fi
  chmod 600 "$prompt_file" 2>/dev/null || true

  # 実行コマンドラインを記録
  local wrapper="${SCRIPT_DIR}/codex-wrapper.sh"
  local cmd_line="${wrapper} --role ${role} --stdin"
  printf '%s\n' "$cmd_line" > "${job_dir}/cmd"
  chmod 600 "${job_dir}/cmd" 2>/dev/null || true

  local started_at
  started_at=$(iso8601_now)

  # 既存 shim log と互換 (PII なし)。job_id は環境変数経由で渡すことで
  # shim-hits.log の各エントリに job_id フィールドを紐付ける (PR#2 part 1)。
  REV_HARNESS_SHIM_JOB_ID="$job_id" \
    shim_log_hit "codex-job-start" "role=${role}" "job_id=${job_id}" || true

  # nohup でバックグラウンド起動。子プロセスが終了時に exit_code を atomic 書込。
  # 0.0.6 PR-A (HIGH-1): tmp + mv で race を避ける。
  # 0.0.6 PR-A: --keep-prompt 未指定なら子の最後に prompt を消す。
  local cleanup_prompt_cmd=""
  if ! $keep_prompt; then
    cleanup_prompt_cmd='/bin/rm -f "$3" 2>/dev/null || true;'
  fi
  (
    # 子プロセスは新しいセッションで動かしたい所だが setsid は macOS にない。
    # nohup + & で十分。
    nohup bash -c '
      umask 077
      "$1" --role "$2" --stdin < "$3" >> "$4" 2>&1
      rc=$?
      printf "%d\n" "$rc" > "$5.tmp.$$" && mv -f "$5.tmp.$$" "$5"
      chmod 600 "$5" 2>/dev/null || true
      '"$cleanup_prompt_cmd"'
    ' _ "$wrapper" "$role" "$prompt_file" "${job_dir}/log" "${job_dir}/exit_code" \
      >/dev/null 2>&1 &
    echo $! > "${job_dir}/pid"
  )

  # pid file の確定を一瞬待つ
  local bg_pid=""
  local tries=0
  while [[ $tries -lt 20 ]]; do
    if [[ -s "${job_dir}/pid" ]]; then
      bg_pid=$(cat "${job_dir}/pid")
      break
    fi
    tries=$((tries + 1))
    sleep 0.1 2>/dev/null || sleep 1
  done
  if [[ -z "$bg_pid" ]]; then
    bg_pid=0
  fi
  chmod 600 "${job_dir}/pid" 2>/dev/null || true
  chmod 600 "${job_dir}/log" 2>/dev/null || true

  write_status "$job_dir" "running" "$role" "$bg_pid" "$started_at" "" ""

  # job_id を stdout に出力
  printf '%s\n' "$job_id"
  return $EX_OK
}

cmd_status() {
  local job_id="${1:-}"
  if [[ -z "$job_id" ]]; then
    log_err "status requires a job-id"
    return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"
    return 1
  fi
  refresh_status "$job_dir" || true
  cat "${job_dir}/status.json"
  return $EX_OK
}

cmd_wait() {
  local job_id=""
  local timeout=$DEFAULT_WAIT_TIMEOUT
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --timeout)
        timeout="${2:?--timeout requires a value}"
        shift 2
        ;;
      -h|--help)
        usage; return 0
        ;;
      -*)
        log_err "unknown option: $1"; return $EX_USAGE
        ;;
      *)
        if [[ -z "$job_id" ]]; then
          job_id="$1"
        else
          log_err "unexpected arg: $1"; return $EX_USAGE
        fi
        shift
        ;;
    esac
  done
  if [[ -z "$job_id" ]]; then
    log_err "wait requires a job-id"; return $EX_USAGE
  fi
  # 0.0.6 PR-A: timeout の入力検証 (非負整数)
  if [[ ! "$timeout" =~ ^[0-9]+$ ]]; then
    log_err "invalid --timeout value: ${timeout} (must be non-negative integer seconds)"
    return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"; return 1
  fi

  # 0.0.6 PR-A (HIGH-1 境界):
  #   timeout=0 : 即時 check のみ。完了済なら exit code、実行中なら 124。
  #   timeout>=1: 各イテレーションで exit_code を先に確認 → 終了 → sleep。
  #   sleep は min(remaining, POLL_INTERVAL) で実効 1 秒境界も尊重。
  local elapsed=0
  while :; do
    if [[ -f "${job_dir}/exit_code" ]]; then
      refresh_status "$job_dir" || true
      cat "${job_dir}/status.json"
      local ec
      ec=$(cat "${job_dir}/exit_code")
      return "$ec"
    fi
    if [[ "$elapsed" -ge "$timeout" ]]; then
      break
    fi
    local remaining=$((timeout - elapsed))
    local sleep_for=$POLL_INTERVAL
    if [[ "$remaining" -lt "$sleep_for" ]]; then
      sleep_for=$remaining
    fi
    if [[ "$sleep_for" -le 0 ]]; then
      break
    fi
    sleep "$sleep_for"
    elapsed=$((elapsed + sleep_for))
  done

  # timeout 到達直前にもう一度 exit_code を確認 (sleep 中に完了した場合)
  if [[ -f "${job_dir}/exit_code" ]]; then
    refresh_status "$job_dir" || true
    cat "${job_dir}/status.json"
    local ec
    ec=$(cat "${job_dir}/exit_code")
    return "$ec"
  fi

  refresh_status "$job_dir" || true
  if [[ -f "${job_dir}/exit_code" ]]; then
    cat "${job_dir}/status.json"
    local ec
    ec=$(cat "${job_dir}/exit_code")
    return "$ec"
  fi

  local state status_ec
  state=$(json_get "${job_dir}/status.json" state)
  if [[ "$state" != "running" ]]; then
    cat "${job_dir}/status.json"
    status_ec=$(json_get "${job_dir}/status.json" exit_code)
    if [[ "$status_ec" =~ ^[0-9]+$ ]]; then
      return "$status_ec"
    fi
    return 1
  fi

  cat "${job_dir}/status.json"
  return $EX_TIMEOUT
}

cmd_result() {
  local job_id=""
  local field=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --field)
        field="${2:?--field requires a value}"
        shift 2
        ;;
      -h|--help)
        usage; return 0
        ;;
      -*)
        log_err "unknown option: $1"; return $EX_USAGE
        ;;
      *)
        if [[ -z "$job_id" ]]; then
          job_id="$1"
        else
          log_err "unexpected arg: $1"; return $EX_USAGE
        fi
        shift
        ;;
    esac
  done
  if [[ -z "$job_id" ]]; then
    log_err "result requires a job-id"; return $EX_USAGE
  fi
  local job_dir
  job_dir=$(resolve_job_dir "$job_id") || return $?
  if [[ ! -d "$job_dir" ]]; then
    log_err "job not found: ${job_id}"; return 1
  fi
  refresh_status "$job_dir" || true
  if [[ ! -f "${job_dir}/exit_code" ]]; then
    log_err "job not completed: ${job_id}"
    return 1
  fi
  if [[ -z "$field" ]]; then
    cat "${job_dir}/status.json"
    return $EX_OK
  fi
  local val
  val=$(json_get "${job_dir}/status.json" "$field")
  if [[ -z "$val" ]]; then
    log_err "field not found: ${field}"
    return 1
  fi
  printf '%s\n' "$val"
  return $EX_OK
}

cmd_gc() {
  local ttl_days=$DEFAULT_GC_TTL_DAYS
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --ttl)
        ttl_days="${2:?--ttl requires a value}"
        shift 2
        ;;
      -h|--help)
        usage; return 0
        ;;
      *)
        log_err "unknown arg: $1"; return $EX_USAGE
        ;;
    esac
  done

  # 0.0.6 PR-A (HIGH-2): ttl_days の入力検証。
  # 非負整数のみ受理。上限 GC_TTL_MAX_DAYS (1 年)。
  if [[ ! "$ttl_days" =~ ^[0-9]+$ ]]; then
    log_err "invalid --ttl value: ${ttl_days} (must be non-negative integer days)"
    return $EX_USAGE
  fi
  if [[ "$ttl_days" -gt "$GC_TTL_MAX_DAYS" ]]; then
    log_err "--ttl ${ttl_days} exceeds max ${GC_TTL_MAX_DAYS} days"
    return $EX_USAGE
  fi

  if [[ ! -d "$JOBS_DIR" ]]; then
    printf 'deleted=0 failed=0\n'
    return $EX_OK
  fi

  # ttl_days を秒に変換
  local ttl_secs
  ttl_secs=$((ttl_days * 86400))
  local now
  now=$(date -u +%s)
  local cutoff=$((now - ttl_secs))

  local deleted=0
  local failed=0
  local d
  for d in "$JOBS_DIR"/*; do
    [[ -d "$d" ]] || continue
    # status.json の ended_at がない場合 = 未完了、スキップ
    if [[ ! -f "${d}/status.json" ]]; then
      continue
    fi
    refresh_status "$d" || true
    local ended_at ended_secs
    ended_at=$(json_get "${d}/status.json" ended_at)
    if [[ -z "$ended_at" || "$ended_at" == "null" ]]; then
      continue
    fi
    # ISO8601 -> epoch (macOS / Linux 両対応)
    if ended_secs=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ended_at" +%s 2>/dev/null); then
      :
    elif ended_secs=$(date -u -d "$ended_at" +%s 2>/dev/null); then
      :
    else
      continue
    fi
    if [[ "$ended_secs" -le "$cutoff" ]]; then
      # 0.0.6 PR-A (HIGH-3): rm 失敗を握りつぶさず、summary に計上して継続。
      if /bin/rm -rf "$d"; then
        deleted=$((deleted + 1))
      else
        failed=$((failed + 1))
        printf '[gc] WARN: failed to remove %s\n' "$d" >&2
      fi
    fi
  done

  printf 'deleted=%d failed=%d\n' "$deleted" "$failed"
  return $EX_OK
}

usage() {
  cat <<'EOF'
codex-job.sh - Async job manager for codex-wrapper.sh

USAGE:
  codex-job.sh <subcommand> [options]

SUBCOMMANDS:
  start [--role <role>] [--keep-prompt] [<prompt>]
      Launch codex-wrapper.sh in background. Prompt is read from stdin
      unless a positional <prompt> is given. Prints the new job-id on
      stdout and returns immediately. Prompt file is removed on
      completion unless --keep-prompt is given.

  status <job-id>
      Print the current status.json to stdout.

  wait <job-id> [--timeout <sec>]
      Block until the job completes or <sec> elapses (default 900s).
      --timeout 0 returns immediately: the job's own exit code if
      already completed, or 124 if still running. Returns the job's own
      exit code, or 124 on timeout.

  result <job-id> [--field <name>]
      Print status.json (or a single field's value) for a completed
      job. Fails if the job is still running.

  gc [--ttl <days>]
      Delete job directories whose ended_at is older than <days>
      (default 7, max 365). Prints "deleted=N failed=M" on stdout.

EXAMPLES:
  jid=$(echo "say hi" | scripts/codex-job.sh start --role reviewer)
  scripts/codex-job.sh status "$jid"
  scripts/codex-job.sh wait "$jid" --timeout 60
  scripts/codex-job.sh result "$jid" --field exit_code
  scripts/codex-job.sh gc --ttl 3

EXIT CODES:
   0  success
   1  generic error (e.g. job not found, not completed)
  64  invalid argument / usage error (incl. bad job-id, bad --ttl)
  70  canonical-guard refuse (vendored copy)
 124  wait timeout
EOF
}

# ---- dispatcher -------------------------------------------------------------

main() {
  if [[ $# -lt 1 ]]; then
    usage
    return $EX_USAGE
  fi
  local sub="$1"
  shift
  case "$sub" in
    start)   cmd_start  "$@" ;;
    status)  cmd_status "$@" ;;
    wait)    cmd_wait   "$@" ;;
    result)  cmd_result "$@" ;;
    gc)      cmd_gc     "$@" ;;
    -h|--help|help) usage ;;
    *)
      log_err "unknown subcommand: ${sub}"
      usage >&2
      return $EX_USAGE
      ;;
  esac
}

main "$@"
