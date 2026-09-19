#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MARKETING_VERSION="${MARKETING_VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M%S)}"

: "${DEVELOPER_ID_APPLICATION:?Set the Developer ID Application signing identity}"
: "${NOTARYTOOL_PROFILE:?Set the notarytool Keychain profile}"

if [[ ! "$MARKETING_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo 'MARKETING_VERSION must be X.Y.Z and BUILD_NUMBER must be numeric.' >&2
  exit 2
fi
if [[ "$(uname -m)" != arm64 ]]; then
  echo 'Private installers must be built on an Apple Silicon Mac.' >&2
  exit 2
fi

cd "$ROOT_DIR"
OUTPUT_DIR="$ROOT_DIR/dist/private-installers/$MARKETING_VERSION-$BUILD_NUMBER"
mkdir -p "$(dirname "$OUTPUT_DIR")"
# Refuse to mix a new attempt with files from an earlier build.
mkdir "$OUTPUT_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mergehawk-private-installer.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
APP_DIR="$WORK_DIR/MergeHawk.app"
DMG_NAME="MergeHawk-$MARKETING_VERSION-$BUILD_NUMBER-apple-silicon.dmg"
DMG_PATH="$OUTPUT_DIR/$DMG_NAME"

env \
  CONFIGURATION=release \
  APP_DIR="$APP_DIR" \
  APP_NAME=MergeHawk.app \
  APP_EXECUTABLE_NAME=mergehawk \
  BUNDLE_ID=com.mergehawk.app \
  LAUNCH_ARGUMENTS= \
  LAUNCH_ENVIRONMENT= \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  CODE_SIGN_OPTIONS=runtime \
  MARKETING_VERSION="$MARKETING_VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  DISTRIBUTION_CHANNEL=development \
  SPARKLE_FEED_URL= \
  SPARKLE_PUBLIC_KEY= \
  "$ROOT_DIR/scripts/build-app-bundle.sh"

codesign --verify --deep --strict "$APP_DIR"
/usr/bin/python3 - "$APP_DIR/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    info = plistlib.load(handle)
assert info["MergeHawkDistributionChannel"] == "development"
assert "SUFeedURL" not in info and "SUPublicEDKey" not in info
assert "LSEnvironment" not in info
PY

mkdir "$WORK_DIR/dmg-root"
ditto "$APP_DIR" "$WORK_DIR/dmg-root/MergeHawk.app"
ln -s /Applications "$WORK_DIR/dmg-root/Applications"
hdiutil create -volname MergeHawk -srcfolder "$WORK_DIR/dmg-root" -format UDZO "$DMG_PATH"
codesign --force --timestamp --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"

notary_args=(--keychain-profile "$NOTARYTOOL_PROFILE")
if [[ -n "${NOTARYTOOL_KEYCHAIN:-}" ]]; then
  notary_args+=(--keychain "$NOTARYTOOL_KEYCHAIN")
fi
notary_exit=0
xcrun notarytool submit "$DMG_PATH" \
  "${notary_args[@]}" \
  --wait --timeout 20m --output-format json > "$OUTPUT_DIR/notarization.json" || notary_exit=$?
cat "$OUTPUT_DIR/notarization.json"
if [[ "$notary_exit" != 0 ]]; then
  echo "Notarization did not complete successfully; see $OUTPUT_DIR/notarization.json." >&2
  exit "$notary_exit"
fi
/usr/bin/python3 - "$OUTPUT_DIR/notarization.json" <<'PY'
import json
import sys

with open(sys.argv[1]) as handle:
    submission = json.load(handle)
if submission.get("status") != "Accepted":
    sys.exit("Apple did not accept the submission: " + str(submission))
PY

xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
spctl --assess --type execute --verbose=2 "$APP_DIR"

(
  cd "$OUTPUT_DIR"
  shasum -a 256 "$DMG_NAME" > SHA256SUMS.txt
)
cat > "$OUTPUT_DIR/BUILD.txt" <<EOF
MergeHawk $MARKETING_VERSION ($BUILD_NUMBER)
Commit: $(git rev-parse HEAD)
Apple Silicon; macOS 14 or later.
Developer ID signed and notarized. Notarization ticket stapled and validated.
Automatic updates are disabled; Sparkle is bundled only as a linked dependency.

Open the DMG and drag MergeHawk to Applications, then launch it from Applications.
To update an existing installation, quit MergeHawk and replace the app.
EOF
echo "Private installer ready: $DMG_PATH"
