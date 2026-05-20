#!/usr/bin/env bash
set -euo pipefail
# Template: Flutter macOS アプリの署名 + 公証フロー（Flutter Desktop）
# 前提: flutter build macos 済みで、成果物は build/macos/Build/Products/Release/<App>.app にある。
# 使い方:
#   APP_NAME=MyApp APP_BUNDLE=build/macos/Build/Products/Release/MyApp.app \
#   APPLE_CERT_BASE64=... APPLE_CERT_PASSWORD=... APPLE_DEVELOPER_ID="Developer ID Application: ... (TEAMID)" \
#   APPLE_NOTARY_ISSUER_ID=... APPLE_NOTARY_KEY_ID=... APPLE_NOTARY_PRIVATE_KEY=... \
#   ./flutter-sign-template.sh
# 公証をスキップする場合は SKIP_NOTARIZE=true。

APP_BUNDLE=${APP_BUNDLE:-""}
ENTITLEMENTS=${ENTITLEMENTS:-"macos/Runner/DebugProfile.entitlements"}
SKIP_NOTARIZE=${SKIP_NOTARIZE:-false}
KEYCHAIN_NAME=${KEYCHAIN_NAME:-temp-signing.keychain-db}

require() { local v=${!1:-}; [[ -n "$v" ]] || { echo "missing env: $1" >&2; exit 1; }; }
cleanup() { security delete-keychain "$KEYCHAIN_NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

[[ -d "$APP_BUNDLE" ]] || { echo "APP_BUNDLE not found: $APP_BUNDLE" >&2; exit 1; }
require APPLE_CERT_BASE64; require APPLE_CERT_PASSWORD; require APPLE_DEVELOPER_ID

TMP_P12=$(mktemp)
echo "$APPLE_CERT_BASE64" | base64 --decode > "$TMP_P12"
security create-keychain -p pass "$KEYCHAIN_NAME"
security set-keychain-settings -lut 21600 "$KEYCHAIN_NAME"
security unlock-keychain -p pass "$KEYCHAIN_NAME"
security import "$TMP_P12" -k "$KEYCHAIN_NAME" -P "$APPLE_CERT_PASSWORD" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple: -s -k pass "$KEYCHAIN_NAME"

# Flutter の .app を再帰署名（Frameworks, Plugins を含む）
find "$APP_BUNDLE/Contents" -type f \( -perm -111 -o -name '*.dylib' -o -name '*.so' \) -print0 |
  while IFS= read -r -d '' f; do
    codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APPLE_DEVELOPER_ID" --keychain "$KEYCHAIN_NAME" "$f"
  done
codesign --force --deep --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APPLE_DEVELOPER_ID" --keychain "$KEYCHAIN_NAME" "$APP_BUNDLE"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
spctl --assess --type execute --verbose "$APP_BUNDLE" || true

if [[ "$SKIP_NOTARIZE" != true ]]; then
  require APPLE_NOTARY_ISSUER_ID; require APPLE_NOTARY_KEY_ID; require APPLE_NOTARY_PRIVATE_KEY
  KEY_P8=$(mktemp)
  ZIPFILE=$(mktemp).zip
  echo "$APPLE_NOTARY_PRIVATE_KEY" | base64 --decode > "$KEY_P8"
  ditto -c -k --keepParent "$APP_BUNDLE" "$ZIPFILE"
  xcrun notarytool submit "$ZIPFILE" --key "$KEY_P8" --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" --wait
  xcrun stapler staple "$APP_BUNDLE"
  spctl --assess --type execute --verbose "$APP_BUNDLE"
fi

echo "done"
