#!/usr/bin/env bash
set -euo pipefail

# Take the Sparkle signing key out of the environment before any child process
# starts, so no tool inherits it. Only generate_appcast receives it, on stdin.
sparkle_private_key=""
if [[ -n "${SPARKLE_PRIVATE_KEY+set}" ]]; then
  sparkle_private_key="$SPARKLE_PRIVATE_KEY"
  unset SPARKLE_PRIVATE_KEY
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/release-env.sh
source "$ROOT_DIR/scripts/lib/release-env.sh"
RELEASE_ENV_KEYS=(
  RELEASE_REPOSITORY SPARKLE_PUBLIC_KEY DEVELOPER_ID_APPLICATION NOTARYTOOL_PROFILE
  NOTARYTOOL_KEYCHAIN SPARKLE_GENERATE_APPCAST SPARKLE_KEY_ACCOUNT
)
load_release_env_file "${RELEASE_ENV_FILE:-$ROOT_DIR/scripts/release-github.env}" "${RELEASE_ENV_KEYS[@]}"
load_release_env_file "${RELEASE_LOCAL_ENV_FILE:-$ROOT_DIR/scripts/release-github.local.env}" "${RELEASE_ENV_KEYS[@]}"
VERSION_TAG=""
BUILD_NUMBER=""
DRY_RUN=0
ALLOW_DIRTY=0

usage() {
  cat <<'USAGE'
Usage: scripts/release-github.sh --version v1.2.3 --build YYYYMMDDHHMMSS [options]

Build, sign, notarize, staple and verify a Sparkle-enabled installer, then sign
its appcast. This tool only prepares local release assets. Publishing happens
only in the release workflow.

Options:
  --generate-appcast PATH    Override Sparkle's generate_appcast executable
  --dry-run                  Print the release plan without side effects
  --allow-dirty              Allow a dirty worktree only for --dry-run
  -h, --help                 Show this help

Defaults: scripts/release-github.env. Local non-secret settings:
scripts/release-github.local.env. Override file locations with RELEASE_ENV_FILE
and RELEASE_LOCAL_ENV_FILE.
Building requires DEVELOPER_ID_APPLICATION, NOTARYTOOL_PROFILE and a Sparkle
signing key in Keychain (SPARKLE_KEY_ACCOUNT, default ed25519) or in the
SPARKLE_PRIVATE_KEY environment variable. NOTARYTOOL_KEYCHAIN optionally
selects a custom Keychain.
USAGE
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || { echo "Required command not found: $1" >&2; exit 2; }
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version|--build|--generate-appcast)
      [[ $# -ge 2 && -n "$2" ]] || { echo "Missing value for $1" >&2; exit 2; }
      case "$1" in
        --version) VERSION_TAG="$2" ;;
        --build) BUILD_NUMBER="$2" ;;
        --generate-appcast) SPARKLE_GENERATE_APPCAST="$2" ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --allow-dirty) ALLOW_DIRTY=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ ! "$VERSION_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ || ! "$BUILD_NUMBER" =~ ^[0-9]{14}$ ]]; then
  echo 'Use --version vX.Y.Z and --build UTC YYYYMMDDHHMMSS.' >&2
  exit 2
fi
require_command python3
python3 - "$BUILD_NUMBER" <<'PY'
import datetime, sys
try:
    datetime.datetime.strptime(sys.argv[1], '%Y%m%d%H%M%S')
except ValueError:
    sys.exit('Build number must be a valid UTC YYYYMMDDHHMMSS timestamp.')
PY
if [[ ! "${RELEASE_REPOSITORY:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo 'RELEASE_REPOSITORY must identify owner/repository.' >&2
  exit 2
fi
if [[ -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  echo 'Configure the public Sparkle key in SPARKLE_PUBLIC_KEY.' >&2
  exit 2
fi
if [[ "$ALLOW_DIRTY" == 1 && "$DRY_RUN" != 1 ]]; then
  echo '--allow-dirty is only supported with --dry-run.' >&2
  exit 2
fi
cd "$ROOT_DIR"
require_command git
if [[ "$ALLOW_DIRTY" != 1 ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo 'Working tree must be clean before preparing a release.' >&2
  exit 2
fi

MARKETING_VERSION="${VERSION_TAG#v}"
SPARKLE_FEED_URL="https://github.com/$RELEASE_REPOSITORY/releases/latest/download/appcast.xml"
RELEASE_ROOT="$ROOT_DIR/.build/releases/$VERSION_TAG-$BUILD_NUMBER"
ASSET_DIR="$RELEASE_ROOT/assets"
DMG_NAME="MergeHawk-$MARKETING_VERSION-apple-silicon.dmg"
DMG_PATH="$ASSET_DIR/$DMG_NAME"
APPCAST_PATH="$ASSET_DIR/appcast.xml"
DOWNLOAD_URL_PREFIX="https://github.com/$RELEASE_REPOSITORY/releases/download/$VERSION_TAG/"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "Release plan: $MARKETING_VERSION ($BUILD_NUMBER)"
  echo "Repository: $RELEASE_REPOSITORY, tag: $VERSION_TAG"
  echo "Sparkle feed: $SPARKLE_FEED_URL"
  echo "Installer: $DOWNLOAD_URL_PREFIX$DMG_NAME"
  echo "Build channel=github: sign, notarize, staple, verify, sign appcast."
  exit 0
fi

for tool in swift codesign hdiutil xcrun spctl ditto sips iconutil; do
  require_command "$tool"
done
: "${DEVELOPER_ID_APPLICATION:?Set the Developer ID Application signing identity}"
: "${NOTARYTOOL_PROFILE:?Set the notarytool Keychain profile}"
[[ "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac.' >&2; exit 2; }
mkdir -p "$(dirname "$RELEASE_ROOT")"
# Refuse to mix assets from separate attempts. Use a fresh build timestamp to retry.
mkdir "$RELEASE_ROOT"
mkdir "$ASSET_DIR"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/mergehawk-release.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT
APP_DIR="$WORK_DIR/MergeHawk.app"
env CONFIGURATION=release APP_DIR="$APP_DIR" APP_NAME=MergeHawk.app \
  APP_EXECUTABLE_NAME=mergehawk BUNDLE_ID=com.mergehawk.app \
  LAUNCH_ARGUMENTS= LAUNCH_ENVIRONMENT= CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  CODE_SIGN_OPTIONS=runtime MARKETING_VERSION="$MARKETING_VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
  DISTRIBUTION_CHANNEL=github SPARKLE_FEED_URL="$SPARKLE_FEED_URL" SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  "$ROOT_DIR/scripts/build-app-bundle.sh"
GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
if [[ -z "$GENERATE_APPCAST" ]]; then
  if [[ ! -d "$ROOT_DIR/.build/artifacts" ]]; then
    echo 'Could not find Sparkle generate_appcast: .build/artifacts is missing after the app build.' >&2
    exit 2
  fi
  GENERATE_APPCAST="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle/bin/generate_appcast' -type f -print -quit)"
fi
[[ -x "$GENERATE_APPCAST" ]] || { echo 'Could not find Sparkle generate_appcast.' >&2; exit 2; }
codesign --verify --deep --strict "$APP_DIR"
python3 - "$APP_DIR/Contents/Info.plist" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_KEY" "$BUILD_NUMBER" "$MARKETING_VERSION" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as handle:
    info = plistlib.load(handle)
assert info['MergeHawkDistributionChannel'] == 'github'
assert info['SUFeedURL'] == sys.argv[2] and info['SUPublicEDKey'] == sys.argv[3]
assert info['CFBundleVersion'] == sys.argv[4]
assert info['CFBundleShortVersionString'] == sys.argv[5], 'Wrong bundle marketing version'
assert info['CFBundleIdentifier'] == 'com.mergehawk.app'
assert 'LSEnvironment' not in info
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
xcrun notarytool submit "$DMG_PATH" "${notary_args[@]}" \
  --wait --timeout 20m --output-format json > "$RELEASE_ROOT/notarization.json"
python3 - "$RELEASE_ROOT/notarization.json" <<'PY'
import json, sys
with open(sys.argv[1]) as handle:
    status = json.load(handle).get('status')
if status != 'Accepted':
    sys.exit('Notarization was not accepted: ' + str(status))
PY
xcrun stapler staple "$DMG_PATH"
xcrun stapler validate "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"
hdiutil verify "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
spctl --assess --type execute --verbose=2 "$APP_DIR"
if [[ -n "$sparkle_private_key" ]]; then
  printf '%s' "$sparkle_private_key" | "$GENERATE_APPCAST" --ed-key-file - --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$ASSET_DIR"
else
  "$GENERATE_APPCAST" --account "${SPARKLE_KEY_ACCOUNT:-ed25519}" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$ASSET_DIR"
fi

# Validate the actual feed before the workflow can publish it.
python3 - "$APPCAST_PATH" "$DMG_PATH" "$DOWNLOAD_URL_PREFIX$DMG_NAME" "$BUILD_NUMBER" "$MARKETING_VERSION" <<'PY'
import os, sys, xml.etree.ElementTree as ET
feed, dmg, url, build, marketing_version = sys.argv[1:]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, 'Expected exactly one release in the appcast'
item = items[0]
enclosure = item.find('enclosure')
assert enclosure is not None and enclosure.get('url') == url, 'Wrong download URL'
assert (item.findtext(sparkle + 'version') or enclosure.get(sparkle + 'version')) == build, 'Wrong build'
assert (item.findtext(sparkle + 'shortVersionString') or enclosure.get(sparkle + 'shortVersionString')) == marketing_version, 'Wrong marketing version'
assert enclosure.get(sparkle + 'edSignature'), 'Missing Sparkle signature'
assert int(enclosure.get('length', '0')) == os.path.getsize(dmg) > 0, 'Wrong archive length'
PY
echo "Prepared release assets: $ASSET_DIR"
