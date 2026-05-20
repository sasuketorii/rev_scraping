#!/usr/bin/env bash
set -euo pipefail

LEVEL="B"

usage() {
  cat <<'USAGE'
Usage: quality_gate.sh [--level A|B|C]

Level A (Hotfix/小修正): cargo fmt, targeted tests (optional)
Level B (通常): fmt, cargo clippy --all-targets --all-features -- -D warnings, cargo test, cargo audit
Level C (local-only bench/非 authoritative): Level B + cargo bench (主要経路)
Canonical harness benchmark/memory evidence は scripts/harness-benchmark.sh を使ってください。

cargo または対象 cargo subcommand が無い場合はスキップし警告します。実行ログで確認してください。
USAGE
}

warn() { echo "[WARN] $*" >&2; }
info() { echo "[INFO] $*"; }

run_cargo_subcommand_if_available() {
  local subcommand="$1"; shift

  if ! command -v cargo >/dev/null 2>&1; then
    warn "skip: cargo (not found)"
    return 0
  fi

  if cargo "$subcommand" --help >/dev/null 2>&1; then
    info "run: cargo $subcommand $*"
    cargo "$subcommand" "$@"
  else
    warn "skip: cargo $subcommand (subcommand not available)"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --level) LEVEL="${2^^}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) warn "unknown arg: $1"; shift ;;
  esac
done

case "$LEVEL" in
  A)
    run_cargo_subcommand_if_available fmt
    info "Level A done (fmt only;テストは任意で実行してください)"
    ;;
  B)
    run_cargo_subcommand_if_available fmt
    run_cargo_subcommand_if_available clippy --all-targets --all-features -- -D warnings
    run_cargo_subcommand_if_available test
    run_cargo_subcommand_if_available audit
    info "Level B done"
    ;;
  C)
    run_cargo_subcommand_if_available fmt
    run_cargo_subcommand_if_available clippy --all-targets --all-features -- -D warnings
    run_cargo_subcommand_if_available test
    run_cargo_subcommand_if_available audit
    run_cargo_subcommand_if_available bench
    info "Level C done (local-only bench; not authoritative harness benchmark evidence)"
    ;;
  *)
    warn "unknown level: $LEVEL (use A/B/C)"; exit 1 ;;
esac
