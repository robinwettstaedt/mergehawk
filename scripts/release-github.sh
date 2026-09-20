#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/release-env.sh
source "$ROOT_DIR/scripts/lib/release-env.sh"
RELEASE_ENV_KEYS=(
  RELEASE_REPOSITORY SPARKLE_FEED_URL SPARKLE_PUBLIC_KEY DEVELOPER_ID_APPLICATION
  NOTARYTOOL_PROFILE NOTARYTOOL_KEYCHAIN SPARKLE_GENERATE_APPCAST SPARKLE_PRIVATE_KEY SPARKLE_KEY_ACCOUNT
  DOWNLOADS_TOKEN DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD
  APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD
)
load_release_env_file "${RELEASE_ENV_FILE:-$ROOT_DIR/scripts/release-github.env}" "${RELEASE_ENV_KEYS[@]}"
load_release_env_file "${RELEASE_LOCAL_ENV_FILE:-$ROOT_DIR/scripts/release-github.local.env}" "${RELEASE_ENV_KEYS[@]}"
# The setup helper shares this file, but these bootstrap credentials are not
# needed by local releases, which use imported identities, a saved notary
# profile, and gh authentication. Do not pass them to build/publish subprocesses.
unset DOWNLOADS_TOKEN DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD
unset APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD
VERSION_TAG=""
BUILD_NUMBER=""
DRAFT=0
DRY_RUN=0
ALLOW_DIRTY=0
PHASE=all

usage() {
  cat <<'USAGE'
Usage: scripts/release-github.sh --version v0.1.0 --build YYYYMMDDHHMMSS [options]

Build, sign, notarize, and publish a Sparkle-enabled installer to the public
RELEASE_REPOSITORY. Tags are VERSION-BUILD; no source commits or tags are pushed.

Options:
  --prepare-only             Build local release assets without GitHub credentials
  --publish-only             Publish previously prepared assets without rebuilding
  --draft                    Leave the release as a draft, outside the update feed
  --generate-appcast PATH     Override Sparkle's generate_appcast executable
  --dry-run                  Print the release plan without side effects
  --allow-dirty              Allow a dirty worktree only for --dry-run
  -h, --help                 Show this help

Defaults: scripts/release-github.env; local overrides: scripts/release-github.local.env.
Override file locations with RELEASE_ENV_FILE and RELEASE_LOCAL_ENV_FILE.
Preparation requires DEVELOPER_ID_APPLICATION, NOTARYTOOL_PROFILE, and a Sparkle
signing key in Keychain (SPARKLE_KEY_ACCOUNT, default ed25519) or SPARKLE_PRIVATE_KEY.
NOTARYTOOL_KEYCHAIN optionally selects a custom Keychain. Publishing requires gh
authentication with Contents:write permission for the downloads repository.
USAGE
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
    --prepare-only|--publish-only)
      [[ "$PHASE" == all ]] || { echo 'Choose only one release phase.' >&2; exit 2; }
      PHASE="${1#--}"; shift ;;
    --draft) DRAFT=1; shift ;;
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
python3 - "$BUILD_NUMBER" <<'PY'
import datetime, sys
try:
    datetime.datetime.strptime(sys.argv[1], '%Y%m%d%H%M%S')
except ValueError:
    sys.exit('Build number must be a valid UTC YYYYMMDDHHMMSS timestamp.')
PY
if [[ ! "${RELEASE_REPOSITORY:-}" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo 'RELEASE_REPOSITORY must explicitly identify owner/downloads-repository.' >&2
  exit 2
fi
# Keep the embedded feed, published asset name, and enclosure destination together.
EXPECTED_FEED="https://github.com/$RELEASE_REPOSITORY/releases/latest/download/appcast.xml"
if [[ "${SPARKLE_FEED_URL:-}" != "$EXPECTED_FEED" || -z "${SPARKLE_PUBLIC_KEY:-}" ]]; then
  echo 'Configure the public Sparkle key and the destination repository latest/download/appcast.xml feed.' >&2
  exit 2
fi
if [[ "$ALLOW_DIRTY" == 1 && "$DRY_RUN" != 1 ]]; then
  echo '--allow-dirty is only supported with --dry-run.' >&2
  exit 2
fi
cd "$ROOT_DIR"
if [[ "$ALLOW_DIRTY" != 1 ]] && [[ -n "$(git status --porcelain)" ]]; then
  echo 'Working tree must be clean before preparing or publishing a release.' >&2
  exit 2
fi

MARKETING_VERSION="${VERSION_TAG#v}"
RELEASE_TAG="$VERSION_TAG-$BUILD_NUMBER"
RELEASE_ROOT="$ROOT_DIR/.build/releases/$RELEASE_TAG"
ASSET_DIR="$RELEASE_ROOT/assets"
DMG_NAME="MergeHawk-$MARKETING_VERSION-$BUILD_NUMBER-apple-silicon.dmg"
DMG_PATH="$ASSET_DIR/$DMG_NAME"
APPCAST_PATH="$ASSET_DIR/appcast.xml"
DOWNLOAD_URL_PREFIX="https://github.com/$RELEASE_REPOSITORY/releases/download/$RELEASE_TAG/"

if [[ "$DRY_RUN" == 1 ]]; then
  echo "Release plan: $MARKETING_VERSION ($BUILD_NUMBER), phase=$PHASE"
  echo "Destination: $RELEASE_REPOSITORY; tag: $RELEASE_TAG"
  echo "Sparkle feed: $SPARKLE_FEED_URL"
  echo "Installer: $DOWNLOAD_URL_PREFIX$DMG_NAME"
  echo "Build channel=github; sign, notarize, staple, verify, sign appcast."
  echo "Create draft with only DMG and appcast.xml; publish latest unless --draft ($DRAFT)."
  exit 0
fi

if [[ "$PHASE" != publish-only ]]; then
  : "${DEVELOPER_ID_APPLICATION:?Set the Developer ID Application signing identity}"
  : "${NOTARYTOOL_PROFILE:?Set the notarytool Keychain profile}"
  [[ "$(uname -m)" == arm64 ]] || { echo 'Build on an Apple Silicon Mac.' >&2; exit 2; }
  mkdir -p "$(dirname "$RELEASE_ROOT")"
  # Refuse to mix assets from separate attempts; use a fresh build timestamp to retry.
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
  codesign --verify --deep --strict "$APP_DIR"
  python3 - "$APP_DIR/Contents/Info.plist" "$SPARKLE_FEED_URL" "$SPARKLE_PUBLIC_KEY" "$BUILD_NUMBER" <<'PY'
import plistlib, sys
with open(sys.argv[1], 'rb') as handle:
    info = plistlib.load(handle)
assert info['MergeHawkDistributionChannel'] == 'github'
assert info['SUFeedURL'] == sys.argv[2] and info['SUPublicEDKey'] == sys.argv[3]
assert info['CFBundleVersion'] == sys.argv[4]
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
  GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
  if [[ -z "$GENERATE_APPCAST" ]]; then
    GENERATE_APPCAST="$(find "$ROOT_DIR/.build/artifacts" -path '*/Sparkle/bin/generate_appcast' -type f -print -quit)"
  fi
  [[ -x "$GENERATE_APPCAST" ]] || { echo 'Could not find Sparkle generate_appcast.' >&2; exit 2; }
  if [[ -n "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$ASSET_DIR"
  else
    "$GENERATE_APPCAST" --account "${SPARKLE_KEY_ACCOUNT:-ed25519}" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$ASSET_DIR"
  fi
fi

# Validate the actual feed in both phases before any public release is created.
python3 - "$APPCAST_PATH" "$DMG_PATH" "$DOWNLOAD_URL_PREFIX$DMG_NAME" "$BUILD_NUMBER" <<'PY'
import os, sys, xml.etree.ElementTree as ET
feed, dmg, url, build = sys.argv[1:]
sparkle = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
items = ET.parse(feed).findall('./channel/item')
assert len(items) == 1, 'Expected exactly one release in the appcast'
item = items[0]
enclosure = item.find('enclosure')
assert enclosure is not None and enclosure.get('url') == url, 'Wrong download URL'
assert (item.findtext(sparkle + 'version') or enclosure.get(sparkle + 'version')) == build, 'Wrong build'
assert enclosure.get(sparkle + 'edSignature'), 'Missing Sparkle signature'
assert int(enclosure.get('length', '0')) == os.path.getsize(dmg) > 0, 'Wrong archive length'
PY
if [[ "$PHASE" == prepare-only ]]; then
  echo "Prepared release assets: $ASSET_DIR"
  exit 0
fi

# Publishing does not need the Sparkle signing key used during preparation.
unset SPARKLE_PRIVATE_KEY

# Read all published tags, rather than trusting request time or workflow queue order.
# This also prevents a delayed local publication from replacing a newer update feed.
PUBLISHED_TAGS="$(gh api --paginate "repos/$RELEASE_REPOSITORY/releases" --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')"
while IFS= read -r published_tag; do
  [[ -z "$published_tag" ]] && continue
  published_build="${published_tag##*-}"
  if [[ ! "$published_build" =~ ^[0-9]{14}$ ]]; then
    echo "Cannot establish build order for existing release: $published_tag" >&2
    exit 2
  fi
  if [[ "$BUILD_NUMBER" < "$published_build" || "$BUILD_NUMBER" == "$published_build" ]]; then
    echo "Build $BUILD_NUMBER must be newer than published build $published_build." >&2
    exit 2
  fi
done <<< "$PUBLISHED_TAGS"

# GitHub creates the tag on the downloads repository's own default branch.
# Never push this private checkout or its commit SHA to the public repository.
RELEASE_URL="$(gh release create "$RELEASE_TAG" --repo "$RELEASE_REPOSITORY" \
  "$DMG_PATH" "$APPCAST_PATH" --draft --latest=false \
  --title "MergeHawk $MARKETING_VERSION ($BUILD_NUMBER)" \
  --notes "MergeHawk $MARKETING_VERSION ($BUILD_NUMBER). Apple Silicon; macOS 14 or later. Signed and notarized. Includes in-app software updates.")"
if [[ "$DRAFT" == 0 ]]; then
  gh release edit "$RELEASE_TAG" --repo "$RELEASE_REPOSITORY" --draft=false --latest
  echo "Published: https://github.com/$RELEASE_REPOSITORY/releases/tag/$RELEASE_TAG"
else
  echo "Created draft: $RELEASE_URL"
fi
