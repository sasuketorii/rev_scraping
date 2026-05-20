#!/usr/bin/env bash
# _canonical-guard.sh
#
# scripts/claude-wrapper.sh と scripts/codex-wrapper.sh から source される
# vendoring 防止共通ライブラリ。canonical install (~/dev/rev_harness または
# REV_HARNESS_CANONICAL_ROOT) 配下から起動されていない場合、vendored copy と
# 判定して exit 70 (sysexits.h EX_SOFTWARE 相当の refuse) する。
#
# 公開関数:
#   rev_harness_assert_canonical_root <wrapper_basename>
#
# 環境変数:
#   REV_HARNESS_CANONICAL_ROOT  期待する canonical root (default: $HOME/dev/rev_harness)
#   REV_HARNESS_VENDOR_CHECK    "strict" (default) | "warn" (deprecated, 次のマイナーで削除予定 (0.0.6+ 候補))
#
# 互換性: macOS bash 3.x (associative array 不使用)

# 二重 source ガード
if [[ -n "${_REV_HARNESS_CANONICAL_GUARD_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
readonly _REV_HARNESS_CANONICAL_GUARD_LOADED=1

rev_harness_assert_canonical_root() {
  local wrapper_basename="${1:-rev_harness}"
  local mode="${REV_HARNESS_VENDOR_CHECK:-strict}"
  local script_dir
  local repo_root
  local expected
  local expected_resolved

  # この関数を source した呼び出し元 (BASH_SOURCE[1]) を起点に
  # scripts/ の親 (= repo root) を pwd -P で正規化する。
  script_dir=$(cd "$(dirname "${BASH_SOURCE[1]}")" && pwd -P) || return 1
  repo_root=$(cd "$script_dir/.." && pwd -P) || return 1

  expected="${REV_HARNESS_CANONICAL_ROOT:-$HOME/dev/rev_harness}"

  if expected_resolved=$(cd "$expected" 2>/dev/null && pwd -P); then
    if [[ "$repo_root" == "$expected_resolved" ]]; then
      return 0
    fi
  fi

  # 不一致 = vendored copy とみなす
  printf '[rev-harness] VENDOR GUARD: %s appears to be a vendored copy at %s\n' \
    "$wrapper_basename" "$repo_root" >&2
  printf '              Canonical install: %s\n' "$expected" >&2
  printf '              Override: set REV_HARNESS_CANONICAL_ROOT or use REV_HARNESS_VENDOR_CHECK=warn (deprecated, removed in a future minor (planned 0.0.6+))\n' >&2
  printf '              See: docs/adoption-guide.md\n' >&2

  if [[ "$mode" == "warn" ]]; then
    printf '[rev-harness] WARNING: VENDOR GUARD soft-mode active; scheduled for removal in a future minor (planned 0.0.6+)\n' >&2
    return 0
  fi

  exit 70
}
