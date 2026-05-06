#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
DEFAULT_CODE_SIGN_IDENTITY="VC Dash Local Code Signing"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APP_DIR="$ROOT_DIR/.build/VCDash.app"
EXECUTABLE="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION/VCDash"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/clang-module-cache" "$ROOT_DIR/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
swift build --disable-sandbox --product VCDash ${CONFIGURATION:+--configuration "$CONFIGURATION"}

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/VCDash"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>VCDash</string>
  <key>CFBundleIdentifier</key>
  <string>com.vcdash.app</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>VC Dash</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSUserNotificationUsageDescription</key>
  <string>VC Dash sends notifications for pull request comments, reviews, failed CI, and changes requested.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

if [[ -z "$CODE_SIGN_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEFAULT_CODE_SIGN_IDENTITY\""; then
  CODE_SIGN_IDENTITY="$DEFAULT_CODE_SIGN_IDENTITY"
fi

if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
  codesign --force --sign "$CODE_SIGN_IDENTITY" "$APP_DIR"
fi

echo "$APP_DIR"
