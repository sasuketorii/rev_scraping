#!/usr/bin/env bash
# _canonical-guard.sh
#
# RevHarness wrapper の runtime identity guard。`claude-wrapper.sh` /
# `codex-wrapper.sh` / `cursor-wrapper.sh` から source される共通ライブラリ。
#
# Design (0.0.12 default-warn redesign, Opus×Codex 合意):
#   RevHarness は「多 repo で使う開発基盤」なので、wrapper が repo に copy
#   されること自体は **正規の adoption** (盗作ではない)。runtime guard は
#   advisory に下げ、deep drift/provenance check は `harness-doctor.sh --strict`
#   と `test/integration/harness_release_gate.sh` に集約する。
#
#   Identity class:
#     canonical-dev   : `revharness-*` project_id + (canonical path OR
#                       official git remote 一致) → pass silent
#     managed-adopter : 有効な非 `revharness-*` project_id → pass silent
#     ambiguous-copy  : `revharness-*` だが official 外
#                       → default WARN (advisory)。`REV_HARNESS_VENDOR_CHECK=strict` で fail-close (exit 70)
#     invalid         : project_id 欠落 / malformed (control char / multiline 等)
#                       → identity-dependent な downstream (semantic DB / queue /
#                         capsule path) が後で破綻するため、setup error として
#                         **default で fail-close**。`REV_HARNESS_VENDOR_CHECK=warn` で
#                         advisory に降りる (debug/migration 用)。
#
#   downstream の identity-dependent path (semantic-mcp DB namespace 等) は
#   wrapper guard が warn でも独立に project_id を validate して fail-close
#   すべき (Codex 0.0.12 design partner note 参照)。
#
# 公開関数:
#   rev_harness_assert_canonical_root <wrapper_basename>
#   resolve_target_root [target_arg]
#
# 環境変数:
#   REV_HARNESS_CANONICAL_ROOT  source-checkout path override (default: $HOME/dev/rev_harness)
#   REV_HARNESS_VENDOR_CHECK    "warn" (default) | "strict"
#                               strict は CI / release gate / harness-doctor --strict が opt-in で設定
#
# 互換性: macOS bash 3.x (associative array 不使用)

# 二重 source ガード
if [[ -n "${_REV_HARNESS_CANONICAL_GUARD_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly _REV_HARNESS_CANONICAL_GUARD_LOADED=1

resolve_target_root() {
  local target_arg="${1:-}"
  local target_root

  if [[ -n "$target_arg" ]]; then
    target_root="$(cd "$target_arg" 2>/dev/null && pwd -P)" || {
      echo "ERROR: --target path not accessible: $target_arg" >&2
      return 2
    }
  elif [[ -n "${REV_HARNESS_ADOPTER_ROOT:-}" ]]; then
    target_root="$(cd "$REV_HARNESS_ADOPTER_ROOT" 2>/dev/null && pwd -P)" || {
      echo "ERROR: REV_HARNESS_ADOPTER_ROOT not accessible: $REV_HARNESS_ADOPTER_ROOT" >&2
      return 2
    }
  else
    target_root="$(pwd -P)"
  fi

  local harness_root
  harness_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  if [[ "$target_root" == "$harness_root" ]]; then
    echo "ERROR: refusing self-install (TARGET_ROOT == HARNESS_ROOT == $target_root)" >&2
    echo "       Use --target <adopter-path> or cd into an adopter project first." >&2
    return 72
  fi

  printf '%s\n' "$target_root"
  return 0
}

_rev_harness_read_project_id() {
  local repo_root="$1"
  local pid_file="$repo_root/.shared/project_id"
  [[ -f "$pid_file" ]] || return 0
  # 1 行目のみ読む。CR / 行末空白だけ trim、それ以外の制御文字や混入は
  # 後段 regex で reject させて呼び出し側に invalid を返す (silent strip 禁止)。
  head -1 "$pid_file" 2>/dev/null | tr -d '\r' | sed -e 's/[[:space:]]*$//'
}

_rev_harness_official_remote_match() {
  local repo_root="$1"
  command -v git >/dev/null 2>&1 || return 1
  local remote
  remote=$(git -C "$repo_root" remote get-url origin 2>/dev/null) || return 1
  case "$remote" in
    *github.com:sasuketorii/rev_harness.git|*github.com/sasuketorii/rev_harness.git|\
    *github.com:sasuketorii/rev_harness|*github.com/sasuketorii/rev_harness)
      return 0
      ;;
  esac
  return 1
}

# REV_HARNESS_VENDOR_CHECK を canonical な小文字値に正規化:
#   "warn" | "strict"。不明な値は warn 扱い (advisory 警告も出す)。
_rev_harness_resolve_mode() {
  local raw="${REV_HARNESS_VENDOR_CHECK:-warn}"
  case "$raw" in
    strict) printf 'strict' ;;
    warn|"") printf 'warn' ;;
    *)
      printf '[rev-harness] identity-check (advisory): unknown REV_HARNESS_VENDOR_CHECK=%s; falling back to warn\n' "$raw" >&2
      printf 'warn'
      ;;
  esac
}

_rev_harness_emit_guard_notice() {
  local class="$1"; shift
  local wrapper="$1"; shift
  local repo_root="$1"; shift
  local label="$1"  # "advisory" or "strict"

  case "$class" in
    ambiguous-copy)
      printf '[rev-harness] identity-check (%s): source-style project_id outside the official source checkout\n' "$label" >&2
      printf '              wrapper=%s repo=%s\n' "$wrapper" "$repo_root" >&2
      printf '              project_id starts with revharness- but this checkout does not match\n' >&2
      printf '              REV_HARNESS_CANONICAL_ROOT or the official git remote.\n' >&2
      printf '              For adoption, run scripts/init-project.sh to create a target project_id.\n' >&2
      printf '              For source development, set REV_HARNESS_CANONICAL_ROOT to your checkout.\n' >&2
      ;;
    invalid)
      printf '[rev-harness] identity-check (%s): repo identity is missing or malformed\n' "$label" >&2
      printf '              wrapper=%s repo=%s\n' "$wrapper" "$repo_root" >&2
      printf '              .shared/project_id could not be read as a valid RevHarness identity.\n' >&2
      printf '              Identity-dependent commands (semantic-mcp / queue / capsule) will fail closed\n' >&2
      printf '              downstream until repaired. Run scripts/init-project.sh or fix .shared/project_id.\n' >&2
      ;;
  esac

  if [[ "$label" == "strict" ]]; then
    printf '              [rev-harness] strict: refusing to continue. Set REV_HARNESS_VENDOR_CHECK=warn only for local debug.\n' >&2
  fi
}

rev_harness_assert_canonical_root() {
  local wrapper="${1:-rev_harness}"
  local mode
  mode=$(_rev_harness_resolve_mode)

  local script_dir repo_root
  local expected expected_resolved
  local project_id

  # Source 元 wrapper (BASH_SOURCE[1]) を起点に repo root を確定
  script_dir=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P) || return 1
  repo_root=$(cd "$script_dir/.." && pwd -P) || return 1

  expected="${REV_HARNESS_CANONICAL_ROOT:-$HOME/dev/rev_harness}"

  # Path 一致 = canonical-dev (fast path、env override 効く)
  if expected_resolved=$(cd "$expected" 2>/dev/null && pwd -P); then
    [[ "$repo_root" == "$expected_resolved" ]] && return 0
  fi

  # Identity class derivation
  project_id=$(_rev_harness_read_project_id "$repo_root")

  # ---- invalid: setup error, default strict ----
  # downstream (semantic-mcp DB namespace 等) が project_id 必須なので、
  # default は fail-close。`REV_HARNESS_VENDOR_CHECK=warn` を明示した時のみ
  # advisory に降りる (debug / migration 用)。`ambiguous-copy` の default-warn
  # とは非対称: invalid は setup error なので、unset でも strict 扱い。
  if [[ -z "$project_id" ]] || [[ ! "$project_id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    local invalid_mode="${REV_HARNESS_VENDOR_CHECK:-strict}"
    case "$invalid_mode" in
      warn)
        _rev_harness_emit_guard_notice invalid "$wrapper" "$repo_root" advisory
        return 0
        ;;
      *)
        _rev_harness_emit_guard_notice invalid "$wrapper" "$repo_root" strict
        exit 70
        ;;
    esac
  fi

  # ---- managed-adopter: target が自身の identity を持つ → silent pass ----
  if [[ "$project_id" != revharness-* ]]; then
    return 0
  fi

  # ---- revharness-*: source-checkout か否か ----
  if _rev_harness_official_remote_match "$repo_root"; then
    return 0  # canonical-dev via git remote
  fi

  # ---- ambiguous-copy: framework copy のうち source-style id を持つもの ----
  # 0.0.12 design partner debate (Opus×Codex 合意) で「framework は copy する
  # ためのもの」を前提に default を warn (advisory) に下げる。strict 強制が
  # 必要な surface (release gate / doctor --strict) は env で opt-in。
  if [[ "$mode" == "strict" ]]; then
    _rev_harness_emit_guard_notice ambiguous-copy "$wrapper" "$repo_root" strict
    exit 70
  fi
  _rev_harness_emit_guard_notice ambiguous-copy "$wrapper" "$repo_root" advisory
  return 0
}
