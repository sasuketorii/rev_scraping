#!/usr/bin/env bash
set -euo pipefail

# Release signing + notarization pipeline for macOS (iOS stub).
# macOS: builds (unless --skip-build), signs with Developer ID, notarizes via notarytool, staples and verifies.
# iOS: intentionally stubbed; controlled by ENABLE_IOS_SIGNING to avoid secret leakage.

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$PROJECT_ROOT"

PLATFORM="macos"
APP_BUNDLE=""
ENTITLEMENTS="$PROJECT_ROOT/docs/entitlements/macos-release.plist"
BUILD_PROFILE="release"
DRY_RUN=false
SKIP_NOTARIZE=false
SKIP_BUILD=false
KEYCHAIN_NAME="build-signing.keychain-db"
KEYCHAIN_PASSWORD=""
KEYCHAIN_CREATED=false
TEMP_FILES=()
USE_EXISTING_IDENTITY=false

usage() {
  cat <<'USAGE'
Usage: ./scripts/sign-and-build.sh [--platform macos|ios] [--app-bundle <path>] [--entitlements <plist>]
                                   [--skip-notarize] [--skip-build] [--debug] [--dry-run]

目的: リリース用の署名・公証パイプラインを一貫して実行する（macOS）。iOSはデフォルトで無効。

Options:
  --platform <macos|ios>    対象プラットフォーム (default: macos)
  --app-bundle <path>       署名対象の .app パス（省略時は target/release/bundle/macos から自動検出）
  --entitlements <plist>    entitlements ファイルへのパス (default: docs/entitlements/macos-release.plist)
  --skip-notarize           公証ステップをスキップ（ローカル検証用）
  --skip-build              既存バンドルを使用しビルドを行わない
  --debug                   デバッグビルドを対象に署名
  --dry-run                 コマンドを実行せず表示のみ（秘密情報チェックも緩和）
  -h, --help                ヘルプ表示

必須環境変数（macOS）:
  APPLE_CERT_BASE64, APPLE_CERT_PASSWORD, APPLE_DEVELOPER_ID
  公証はいずれか一方をセット（--skip-notarize 時は不要）
    A) APIキー方式: APPLE_NOTARY_ISSUER_ID, APPLE_NOTARY_KEY_ID, APPLE_NOTARY_PRIVATE_KEY
    B) Apple ID方式: APPLE_ID, APPLE_TEAM_ID, APPLE_APP_SPECIFIC_PASSWORD
USAGE
}

log()   { echo "[sign-and-build] $*"; }
warn()  { echo "[sign-and-build][warn] $*" >&2; }
die()   { echo "[sign-and-build][error] $*" >&2; exit 1; }
run()   { if $DRY_RUN; then echo "[dry-run] $*"; else "$@"; fi; }

require_cmd() {
  local bin="$1"
  command -v "$bin" >/dev/null 2>&1 || die "command not found: $bin"
}

require_env() {
  local name="$1"
  local val="${!name:-}"
  if [[ -z "$val" ]]; then
    if $DRY_RUN; then
      warn "env $name is missing (ignored due to --dry-run)"
    else
      die "環境変数 $name が未設定です"
    fi
  fi
}

cleanup() {
  if ! $DRY_RUN && [[ "$KEYCHAIN_CREATED" == true ]]; then
    security delete-keychain "$KEYCHAIN_NAME" >/dev/null 2>&1 || true
  fi
  for f in "${TEMP_FILES[@]:-}"; do
    [[ -f "$f" ]] && rm -f "$f"
  done
  return 0
}
trap cleanup EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      shift; PLATFORM="${1:-}" ;;
    --app-bundle)
      shift; APP_BUNDLE="${1:-}" ;;
    --entitlements)
      shift; ENTITLEMENTS="${1:-}" ;;
    --skip-notarize)
      SKIP_NOTARIZE=true ;;
    --skip-build)
      SKIP_BUILD=true ;;
    --debug)
      BUILD_PROFILE="debug" ;;
    --dry-run)
      DRY_RUN=true ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die "Unknown option: $1" ;;
  esac
  shift || true
done

random_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 32
}

ensure_keychain() {
  require_cmd security

  if [[ -z "${APPLE_CERT_BASE64:-}" ]]; then
    USE_EXISTING_IDENTITY=true
    if [[ -z "${APPLE_DEVELOPER_ID:-}" ]]; then
      die "APPLE_DEVELOPER_ID が未設定です"
    fi
    log "既存キーチェーンの Developer ID を使用します: $APPLE_DEVELOPER_ID"
    return
  fi

  require_env APPLE_CERT_BASE64
  require_env APPLE_CERT_PASSWORD
  require_env APPLE_DEVELOPER_ID

  KEYCHAIN_PASSWORD=${KEYCHAIN_PASSWORD:-$(random_password)}
  local cert_file
  cert_file=$(mktemp -t apple-cert.XXXXXX.p12)
  TEMP_FILES+=("$cert_file")

  if ! $DRY_RUN; then
    echo "$APPLE_CERT_BASE64" | base64 --decode > "$cert_file"

    run security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    run security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
    run security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"
    run security import "$cert_file" -k "$KEYCHAIN_NAME" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security

    # key partition list so codesign can access without prompts
    run security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN_NAME"

    # Prepend to search list while keeping existing keychains
    local existing
    existing=$(security list-keychains -d user | tr -d '"')
    run security list-keychains -d user -s "$KEYCHAIN_NAME" $existing
    KEYCHAIN_CREATED=true
  else
    log "--dry-run: keychain作成をスキップします"
  fi
}

build_macos() {
  [[ "$SKIP_BUILD" == true ]] && { log "ビルドをスキップ (--skip-build)"; return; }

  if [[ -f "src-tauri/tauri.conf.json" || -f "tauri.conf.json" ]]; then
    local tauri_args=(build --bundles app)
    [[ "$BUILD_PROFILE" == "debug" ]] && tauri_args+=(--debug)

    if command -v pnpm >/dev/null 2>&1 && [[ -f package.json ]]; then
      if [[ -f pnpm-lock.yaml ]]; then
        run pnpm install --frozen-lockfile
      else
        run pnpm install
      fi
      run pnpm tauri "${tauri_args[@]}"
    elif command -v cargo >/dev/null 2>&1; then
      run cargo tauri "${tauri_args[@]}"
    else
      die "Tauri CLI が見つかりません。pnpm tauri または cargo tauri を利用できるようにしてください。"
    fi
  else
    warn "tauri.conf.json が無いのでビルドを実行しません。--app-bundle を指定してください。"
  fi
}

find_app_bundle() {
  if [[ -n "$APP_BUNDLE" ]]; then
    [[ -d "$APP_BUNDLE" ]] || die "指定された .app が見つかりません: $APP_BUNDLE"
    return
  fi

  local found
  found=$(find "$PROJECT_ROOT/target" -type d -path "*/bundle/macos/*.app" -maxdepth 6 2>/dev/null | head -n 1 || true)
  if [[ -z "$found" ]]; then
    die ".app が見つかりませんでした。--app-bundle で明示するか build を有効にしてください。"
  fi
  APP_BUNDLE="$found"
}

sign_file() {
  local path="$1"
  if $USE_EXISTING_IDENTITY || [[ -z "$KEYCHAIN_NAME" ]]; then
    run codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" \
      --sign "$APPLE_DEVELOPER_ID" \
      "$path"
  else
    run codesign --force --options runtime --timestamp \
      --entitlements "$ENTITLEMENTS" \
      --sign "$APPLE_DEVELOPER_ID" \
      --keychain "$KEYCHAIN_NAME" \
      "$path"
  fi
}

sign_tree_if_exists() {
  local dir="$1"
  [[ -d "$dir" ]] || return 0
  find "$dir" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) -print0 |
    while IFS= read -r -d '' item; do
      sign_file "$item"
    done
}

sign_macos_bundle() {
  require_cmd codesign
  [[ -f "$ENTITLEMENTS" ]] || die "Entitlements ファイルが見つかりません: $ENTITLEMENTS"

  sign_tree_if_exists "$APP_BUNDLE/Contents/Frameworks"
  sign_tree_if_exists "$APP_BUNDLE/Contents/Helpers"
  sign_tree_if_exists "$APP_BUNDLE/Contents/PlugIns"
  sign_tree_if_exists "$APP_BUNDLE/Contents/Resources"

  if [[ -d "$APP_BUNDLE/Contents/MacOS" ]]; then
    while IFS= read -r -d '' main_bin; do
      sign_file "$main_bin"
    done < <(find "$APP_BUNDLE/Contents/MacOS" -type f -perm -111 -print0)
  fi

  sign_file "$APP_BUNDLE"
}

verify_macos_bundle() {
  require_cmd spctl
  run codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
  if $SKIP_NOTARIZE; then
    set +e
    /usr/sbin/spctl --assess --type execute --verbose "$APP_BUNDLE"
    status=$?
    set -e
    if [[ $status -ne 0 ]]; then
      warn "spctl は公証前のため失敗（想定） status=${status}"
    fi
    return 0
  else
    run spctl --assess --type execute --verbose "$APP_BUNDLE"
  fi
}

notarize_macos() {
  $SKIP_NOTARIZE && { log "公証をスキップ (--skip-notarize)"; return; }

  require_cmd xcrun
  local key_file zip_path use_api_key=false use_apple_id=false
  if [[ -n "${APPLE_NOTARY_ISSUER_ID:-}" || -n "${APPLE_NOTARY_KEY_ID:-}" || -n "${APPLE_NOTARY_PRIVATE_KEY:-}" ]]; then
    use_api_key=true
  elif [[ -n "${APPLE_ID:-}" || -n "${APPLE_TEAM_ID:-}" || -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
    use_apple_id=true
  fi

  if ! $use_api_key && ! $use_apple_id; then
    die "公証用資格情報がありません。APIキー方式(APPLE_NOTARY_*)またはApple ID方式(APPLE_ID/APPLE_TEAM_ID/APPLE_APP_SPECIFIC_PASSWORD)のどちらかを設定してください。"
  fi

  local zip_path
  zip_path=$(mktemp -t app-bundle.XXXXXX.zip)
  TEMP_FILES+=("$zip_path")

  run ditto -c -k --keepParent "$APP_BUNDLE" "$zip_path"

  if $use_api_key; then
    require_env APPLE_NOTARY_ISSUER_ID
    require_env APPLE_NOTARY_KEY_ID
    require_env APPLE_NOTARY_PRIVATE_KEY
    key_file=$(mktemp -t notary-key.XXXXXX.p8)
    TEMP_FILES+=("$key_file")
    if ! $DRY_RUN; then
      echo "$APPLE_NOTARY_PRIVATE_KEY" | base64 --decode > "$key_file"
    fi
    run xcrun notarytool submit "$zip_path" --key "$key_file" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --wait
  else
    require_env APPLE_ID
    require_env APPLE_TEAM_ID
    require_env APPLE_APP_SPECIFIC_PASSWORD
    run xcrun notarytool submit "$zip_path" \
      --apple-id "$APPLE_ID" \
      --team-id "$APPLE_TEAM_ID" \
      --password "$APPLE_APP_SPECIFIC_PASSWORD" \
      --wait
  fi

  run xcrun stapler staple "$APP_BUNDLE"
  run spctl --assess --type execute --verbose "$APP_BUNDLE"
}

macos_flow() {
  build_macos
  find_app_bundle
  ensure_keychain
  sign_macos_bundle
  verify_macos_bundle
  notarize_macos
  log "macOS 署名フロー完了"
  return 0
}

ios_flow() {
  warn "iOS フローはデフォルト無効です。ENABLE_IOS_SIGNING=true か --platform ios で明示的に実行してください。"
  warn "現在は実装スタブのみ。fastlane/match など既存の署名チェーンと統合してください。"
}

case "$PLATFORM" in
  macos)
    macos_flow ;;
  ios)
    ios_flow ;;
  *)
    die "Unsupported platform: $PLATFORM" ;;
esac

exit 0
