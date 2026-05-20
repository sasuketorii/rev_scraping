#!/usr/bin/env bash
set -euo pipefail

# Development build helper that guarantees “no signing/no prompts”.
# It is safe to run without Apple certificates; missing toolchains are treated as a skip.

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_ROOT"

PLATFORM="macos"
BUILD_PROFILE="debug"
DRY_RUN=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/build-dev.sh [--platform macos|ios] [--release] [--dry-run]

目的: ローカル開発で署名や公証のプロンプトを一切出さずにビルドを確認する。
      環境が無ければスキップで終了する。

Options:
  --platform <macos|ios>  対象プラットフォーム (default: macos)
  --release               リリースビルドフラグ（署名は依然として行わない）
  --dry-run               コマンドを表示するだけで実行しない
  -h, --help              ヘルプ表示
USAGE
}

log()   { echo "[build-dev] $*"; }
warn()  { echo "[build-dev][warn] $*" >&2; }
die()   { echo "[build-dev][error] $*" >&2; exit 1; }
run()   { if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      shift
      PLATFORM="${1:-}"
      ;;
    --release)
      BUILD_PROFILE="release"
      ;;
    --dry-run)
      DRY_RUN=true
      ;;
    -h|--help)
      usage; exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
  shift || true
done

case "$PLATFORM" in
  macos)
    log "macOS dev buildを開始 (署名・公証なし)"
    # 署名系環境変数を意図的に空にすることで、Tauri/Cargo側で署名処理が走らないようにする
    export APPLE_CERTIFICATE=""
    export APPLE_CERTIFICATE_PASSWORD=""
    export APPLE_SIGNING_IDENTITY=""

    if [[ -f "src-tauri/tauri.conf.json" || -f "tauri.conf.json" ]]; then
      TAURI_ARGS=(build --bundles app)
      [[ "$BUILD_PROFILE" == "debug" ]] && TAURI_ARGS+=(--debug)

      if command -v pnpm >/dev/null 2>&1 && [[ -f package.json ]]; then
        if [[ -f pnpm-lock.yaml ]]; then
          run pnpm install --frozen-lockfile
        else
          run pnpm install
        fi
        run pnpm tauri "${TAURI_ARGS[@]}"
      elif command -v cargo >/dev/null 2>&1; then
        run cargo tauri "${TAURI_ARGS[@]}"
      else
        warn "Tauri CLI が見つかりません。'cargo install tauri-cli' を検討してください。"
      fi
    else
      warn "tauri.conf.json が無いため macOS ビルドをスキップします。"
    fi

    log "完了: 署名/公証は実行していません。"
    ;;

  ios)
    log "iOS 開発ビルドのスタブを実行します（署名なし）。"
    if [[ -d "ios" || -d "apps/ios" ]]; then
      warn "Xcode プロジェクトを検出しましたが、本スクリプトではビルドのみ／署名なしを推奨します。"
      warn "例: xcodebuild -scheme <AppScheme> -sdk iphonesimulator CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO"
    else
      warn "iOS プロジェクトが見つからないためスキップします。"
    fi
    ;;

  *)
    die "Unsupported platform: $PLATFORM"
    ;;
esac
