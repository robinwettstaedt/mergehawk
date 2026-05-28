#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-debug}"
DEFAULT_CODE_SIGN_IDENTITY="MergeHawk Local Code Signing"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:-}"
APP_NAME="${APP_NAME:-MergeHawk.app}"
APP_BUNDLE_NAME="${APP_NAME%.app}"
BUNDLE_ID="${BUNDLE_ID:-com.mergehawk.app}"
APP_EXECUTABLE_NAME="${APP_EXECUTABLE_NAME:-mergehawk}"
APP_DIR="${APP_DIR:-$ROOT_DIR/.build/$APP_NAME}"
EXECUTABLE="$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION/mergehawk"
LAUNCH_ARGUMENTS="${LAUNCH_ARGUMENTS:-}"
LAUNCH_ENVIRONMENT="${LAUNCH_ENVIRONMENT:-}"

cd "$ROOT_DIR"
mkdir -p "$ROOT_DIR/.build/clang-module-cache" "$ROOT_DIR/.build/swiftpm-cache"
export CLANG_MODULE_CACHE_PATH="$ROOT_DIR/.build/clang-module-cache"
export SWIFTPM_CACHE_PATH="$ROOT_DIR/.build/swiftpm-cache"
swift build --disable-sandbox --product mergehawk ${CONFIGURATION:+--configuration "$CONFIGURATION"}

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
if [[ -n "$LAUNCH_ARGUMENTS" ]]; then
  cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME.bin"
  /usr/bin/python3 - "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME" "$APP_EXECUTABLE_NAME.bin" "$LAUNCH_ARGUMENTS" "$LAUNCH_ENVIRONMENT" <<'PY'
import shlex
import sys

path, binary_name, launch_args, launch_environment = sys.argv[1:]
args = shlex.split(launch_args)
environment = {}
for assignment in shlex.split(launch_environment):
    if "=" in assignment:
        key, value = assignment.split("=", 1)
        environment[key] = value

lines = ["#!/usr/bin/env bash", "set -euo pipefail"]
for key, value in environment.items():
    lines.append(f"export {key}={shlex.quote(value)}")
quoted_args = " ".join(shlex.quote(arg) for arg in args)
lines.append(f'exec "$(dirname "$0")/{binary_name}" {quoted_args} "$@"')

with open(path, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines) + "\n")
PY
  chmod +x "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
else
  cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$APP_EXECUTABLE_NAME"
fi

while IFS= read -r -d '' resource_bundle; do
  ditto "$resource_bundle" "$APP_DIR/Contents/Resources"
done < <(
  find "$ROOT_DIR/.build/arm64-apple-macosx/$CONFIGURATION" \
    -maxdepth 1 \
    -type d \
    -name "mergehawk_*.bundle" \
    -print0
)

APP_ICON_PNG="$ROOT_DIR/Design/mergehawk_logo_without_text.png"
cp "$APP_ICON_PNG" "$APP_DIR/Contents/Resources/MergeHawkAppIcon.png"
ICONSET_DIR="$APP_DIR/Contents/Resources/MergeHawkAppIcon.iconset"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"
tmp_icon_dir="$(mktemp -d)"
cp "$APP_ICON_PNG" "$tmp_icon_dir/source.png"
for spec in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"
do
  read -r pixel_size icon_name <<<"$spec"
  sips -z "$pixel_size" "$pixel_size" "$tmp_icon_dir/source.png" --out "$ICONSET_DIR/$icon_name" >/dev/null
done
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/MergeHawkAppIcon.icns"
rm -rf "$ICONSET_DIR" "$tmp_icon_dir"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>__APP_EXECUTABLE_NAME__</string>
  <key>CFBundleIdentifier</key>
  <string>__BUNDLE_ID__</string>
  <key>CFBundleIconFile</key>
  <string>MergeHawkAppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>__APP_BUNDLE_NAME__</string>
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
  <string>MergeHawk sends notifications for pull request comments, reviews, failed CI, and changes requested.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

/usr/bin/python3 - "$APP_DIR/Contents/Info.plist" "$APP_EXECUTABLE_NAME" "$BUNDLE_ID" "$APP_BUNDLE_NAME" "$LAUNCH_ARGUMENTS" "$LAUNCH_ENVIRONMENT" <<'PY'
import plistlib
import shlex
import sys

path, executable_name, bundle_id, app_name, launch_args, launch_environment = sys.argv[1:]
with open(path, "rb") as handle:
    plist = plistlib.load(handle)

plist["CFBundleExecutable"] = executable_name
plist["CFBundleIdentifier"] = bundle_id
plist["CFBundleName"] = app_name

environment = {}
for assignment in shlex.split(launch_environment):
    if "=" in assignment:
        key, value = assignment.split("=", 1)
        environment[key] = value
if environment:
    plist["LSEnvironment"] = environment

with open(path, "wb") as handle:
    plistlib.dump(plist, handle, sort_keys=False)
PY

if [[ -z "$CODE_SIGN_IDENTITY" ]] && security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$DEFAULT_CODE_SIGN_IDENTITY\""; then
  CODE_SIGN_IDENTITY="$DEFAULT_CODE_SIGN_IDENTITY"
fi

if [[ -n "$CODE_SIGN_IDENTITY" ]]; then
  codesign --force --deep --sign "$CODE_SIGN_IDENTITY" "$APP_DIR"
else
  codesign --force --deep --sign - "$APP_DIR"
fi

echo "$APP_DIR"
