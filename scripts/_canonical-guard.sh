#!/usr/bin/env bash
# _canonical-guard.sh
#
# RevHarness wrapper の runtime identity guard。`claude-wrapper.sh` /
# `codex-wrapper.sh` / `cursor-wrapper.sh` から source される共通ライブラリ。
#
# Design (round 5 redesign, Codex + Opus 合意):
#   Vendor guard を **path whitelist** から **identity class guard** に変更する。
#   RevHarness は多 repo で使う開発基盤なので「rev_harness 本家配下から起動された
#   wrapper だけ実行許可」では adoption 自体が block される。
#   代わりに `.shared/project_id` のクラスで合法 / 不正を区別する。
#
#   識別クラス:
#     canonical-dev     : `revharness-*` project_id + (canonical path 一致 OR
#                         official git remote 一致) → pass
#     managed-adopter   : 有効な非 `revharness-*` project_id (target repo が
#                         自身の identity を持つ) → pass
#     ambiguous-copy    : `revharness-*` だが canonical path にも official remote
#                         にも該当しない → fail-closed (本家の中身を path だけ
#                         移した stale/vendored copy が該当)
#     invalid           : project_id 欠落 / malformed / 制御文字混入 → fail-closed
#
#   Stale-copy drift (wrapper hash mismatch / version skew) の検出は wrapper
#   実行毎ではなく `harness-doctor.sh` / release gate 側で扱う (分離)。
#
# 公開関数:
#   rev_harness_assert_canonical_root <wrapper_basename>
#
# 環境変数:
#   REV_HARNESS_CANONICAL_ROOT  override canonical source-checkout path
#                               (default: $HOME/dev/rev_harness)
#   REV_HARNESS_VENDOR_CHECK    "strict" (default) | "warn" (deprecated migration aid)
#
# 互換性: macOS bash 3.x (associative array 不使用)

# 二重 source ガード
if [[ -n "${_REV_HARNESS_CANONICAL_GUARD_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly _REV_HARNESS_CANONICAL_GUARD_LOADED=1

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

_rev_harness_emit_guard_error() {
  local class="$1"; shift
  local wrapper="$1"; shift
  local repo_root="$1"; shift
  case "$class" in
    ambiguous-copy)
      printf '[rev-harness] VENDOR GUARD: ambiguous RevHarness identity at %s\n' "$repo_root" >&2
      printf '              wrapper=%s project_id starts with revharness- but this is not the\n' "$wrapper" >&2
      printf '              official source checkout (path / git remote mismatch).\n' >&2
      printf '              Resolution: for adoption, bootstrap a target project_id via\n' >&2
      printf '              scripts/init-project.sh; for source dev, set\n' >&2
      printf '              REV_HARNESS_CANONICAL_ROOT to your checkout path.\n' >&2
      ;;
    invalid)
      printf '[rev-harness] VENDOR GUARD: missing or invalid repo identity at %s\n' "$repo_root" >&2
      printf '              wrapper=%s could not read a usable .shared/project_id.\n' "$wrapper" >&2
      printf '              Resolution: run scripts/init-project.sh to bootstrap an\n' >&2
      printf '              adopter project_id, or set REV_HARNESS_CANONICAL_ROOT for a\n' >&2
      printf '              source checkout.\n' >&2
      ;;
  esac
}

rev_harness_assert_canonical_root() {
  local wrapper="${1:-rev_harness}"
  local mode="${REV_HARNESS_VENDOR_CHECK:-strict}"
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

  if [[ -z "$project_id" ]]; then
    _rev_harness_emit_guard_error invalid "$wrapper" "$repo_root"
    [[ "$mode" == "warn" ]] && return 0
    exit 70
  fi

  # Format sanity: ASCII printable, char class limited
  if [[ ! "$project_id" =~ ^[A-Za-z0-9_.-]+$ ]]; then
    _rev_harness_emit_guard_error invalid "$wrapper" "$repo_root"
    [[ "$mode" == "warn" ]] && return 0
    exit 70
  fi

  if [[ "$project_id" != revharness-* ]]; then
    # managed-adopter: target が自身の identity を持つ → pass
    return 0
  fi

  # project_id starts with revharness-: must be the official source checkout
  if _rev_harness_official_remote_match "$repo_root"; then
    return 0  # canonical-dev via git remote
  fi

  # ambiguous-copy
  _rev_harness_emit_guard_error ambiguous-copy "$wrapper" "$repo_root"
  [[ "$mode" == "warn" ]] && return 0
  exit 70
}
