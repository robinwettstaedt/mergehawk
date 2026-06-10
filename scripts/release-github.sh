#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-$ROOT_DIR/scripts/release-github.env}"
RELEASE_LOCAL_ENV_FILE="${RELEASE_LOCAL_ENV_FILE:-$ROOT_DIR/scripts/release-github.local.env}"
VERSION_TAG=""
BUILD_NUMBER=""
DRAFT=0
DRY_RUN=0
ALLOW_DIRTY=0
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-}"
DEVELOPER_ID_APPLICATION="${DEVELOPER_ID_APPLICATION:-}"
NOTARYTOOL_PROFILE="${NOTARYTOOL_PROFILE:-}"
DOWNLOAD_URL_PREFIX="${DOWNLOAD_URL_PREFIX:-}"
SPARKLE_GENERATE_APPCAST="${SPARKLE_GENERATE_APPCAST:-}"
SPARKLE_PRIVATE_KEY="${SPARKLE_PRIVATE_KEY:-}"
SPARKLE_KEY_ACCOUNT="${SPARKLE_KEY_ACCOUNT:-ed25519}"

load_release_env_file() {
  local file="$1"
  local line
  local line_number=0
  local key
  local value

  [[ -f "$file" ]] || return 0

  while IFS= read -r line || [[ -n "$line" ]]; do
    line_number=$((line_number + 1))
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"

    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" == export[[:space:]]* ]]; then
      line="${line#export}"
      line="${line#"${line%%[![:space:]]*}"}"
    fi
    if [[ ! "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "Unsupported release env syntax in $file:$line_number" >&2
      exit 2
    fi

    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    if [[ ${#value} -ge 2 ]]; then
      if [[ "${value:0:1}" == '"' && "${value: -1}" == '"' ]]; then
        value="${value:1:${#value}-2}"
      elif [[ "${value:0:1}" == "'" && "${value: -1}" == "'" ]]; then
        value="${value:1:${#value}-2}"
      fi
    fi

    case "$key" in
      SPARKLE_FEED_URL|SPARKLE_PUBLIC_KEY|DEVELOPER_ID_APPLICATION|NOTARYTOOL_PROFILE|DOWNLOAD_URL_PREFIX|SPARKLE_GENERATE_APPCAST|SPARKLE_PRIVATE_KEY|SPARKLE_KEY_ACCOUNT)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      *)
        echo "Unsupported release env key in $file:$line_number: $key" >&2
        exit 2
        ;;
    esac
  done < "$file"
}

load_release_env_file "$RELEASE_ENV_FILE"
load_release_env_file "$RELEASE_LOCAL_ENV_FILE"

usage() {
  cat <<'USAGE'
Usage: scripts/release-github.sh --version v0.1.0 --build 1 [options]

Builds a Developer ID signed GitHub-distributed MergeHawk app, packages it,
notarizes it, generates a Sparkle appcast, and publishes a GitHub Release.

Required:
  --version TAG              Release tag, for example v0.1.0
  --build NUMBER             CFBundleVersion build number

Sparkle config:
  --feed-url URL             Override the public Sparkle appcast URL embedded in the app
  --sparkle-public-key KEY   Override the Sparkle EdDSA public key embedded in the app

Required for publishing:
  DEVELOPER_ID_APPLICATION   Developer ID Application signing identity
  NOTARYTOOL_PROFILE         xcrun notarytool keychain profile

Options:
  --draft                    Create a draft GitHub Release
  --download-url-prefix URL  Prefix used in generated appcast item enclosures
  --generate-appcast PATH    Path to Sparkle's generate_appcast tool
  RELEASE_ENV_FILE           Env file for repo-safe defaults (default scripts/release-github.env)
  RELEASE_LOCAL_ENV_FILE     Env file for local overrides (default scripts/release-github.local.env)
  SPARKLE_PRIVATE_KEY        Optional private EdDSA key, used by CI via stdin
  SPARKLE_KEY_ACCOUNT        Keychain account for local signing (default ed25519)
  --dry-run                  Print and validate the workflow without side effects
  --allow-dirty              Permit a dirty working tree during dry-run
  -h, --help                 Show this help

Example:
  DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
  NOTARYTOOL_PROFILE="mergehawk-notary" \
  scripts/release-github.sh \
    --version v0.1.0 \
    --build 1 \
    --draft
USAGE
}

log_run() {
  printf '+'
  printf ' %q' "$@"
  printf '\n'
  if [[ "$DRY_RUN" == "0" ]]; then
    "$@"
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Required command not found: $1" >&2
    exit 2
  fi
}

require_clean_worktree() {
  if [[ "$ALLOW_DIRTY" == "1" ]]; then
    return
  fi
  if ! git diff --quiet || ! git diff --cached --quiet || [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree must be clean before publishing a release." >&2
    echo "Use --allow-dirty only with --dry-run." >&2
    exit 2
  fi
}

find_generate_appcast() {
  if [[ -n "$SPARKLE_GENERATE_APPCAST" ]]; then
    printf '%s\n' "$SPARKLE_GENERATE_APPCAST"
    return
  fi
  find "$ROOT_DIR/.build/artifacts" -path "*/Sparkle/bin/generate_appcast" -type f -print -quit 2>/dev/null || true
}

run_generate_appcast() {
  if [[ -n "$SPARKLE_PRIVATE_KEY" ]]; then
    echo "+ generate_appcast --ed-key-file - --download-url-prefix $DOWNLOAD_URL_PREFIX $APPCAST_INPUT_DIR"
    printf '%s' "$SPARKLE_PRIVATE_KEY" | "$GENERATE_APPCAST" --ed-key-file - --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$APPCAST_INPUT_DIR"
  else
    log_run "$GENERATE_APPCAST" --account "$SPARKLE_KEY_ACCOUNT" --download-url-prefix "$DOWNLOAD_URL_PREFIX" "$APPCAST_INPUT_DIR"
  fi
}

resolve_commit() {
  git rev-parse --verify -q "$1^{commit}" 2>/dev/null || true
}

resolve_remote_tag_commit() {
  local output
  local direct_commit
  local peeled_commit

  output="$(git ls-remote --tags origin "refs/tags/$VERSION_TAG" "refs/tags/$VERSION_TAG^{}")"
  peeled_commit="$(printf '%s\n' "$output" | awk '$2 ~ /\^\{\}$/ { print $1; exit }')"
  direct_commit="$(printf '%s\n' "$output" | awk '$2 !~ /\^\{\}$/ { print $1; exit }')"

  if [[ -n "$peeled_commit" ]]; then
    printf '%s\n' "$peeled_commit"
  else
    printf '%s\n' "$direct_commit"
  fi
}

ensure_tag_points_at_head_or_is_absent() {
  local head_commit
  local local_tag_commit
  local remote_tag_commit
  head_commit="$(git rev-parse HEAD)"
  local_tag_commit="$(resolve_commit "$VERSION_TAG")"

  if [[ -n "$local_tag_commit" && "$local_tag_commit" != "$head_commit" ]]; then
    echo "Local tag $VERSION_TAG points at $local_tag_commit, not HEAD $head_commit." >&2
    exit 2
  fi

  if [[ "$DRY_RUN" == "0" ]]; then
    remote_tag_commit="$(resolve_remote_tag_commit)"
    if [[ -n "$remote_tag_commit" && "$remote_tag_commit" != "$head_commit" ]]; then
      echo "Remote tag $VERSION_TAG points at $remote_tag_commit, not HEAD $head_commit." >&2
      exit 2
    fi
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      VERSION_TAG="${2:-}"
      shift 2
      ;;
    --build)
      BUILD_NUMBER="${2:-}"
      shift 2
      ;;
    --feed-url)
      SPARKLE_FEED_URL="${2:-}"
      shift 2
      ;;
    --sparkle-public-key)
      SPARKLE_PUBLIC_KEY="${2:-}"
      shift 2
      ;;
    --download-url-prefix)
      DOWNLOAD_URL_PREFIX="${2:-}"
      shift 2
      ;;
    --generate-appcast)
      SPARKLE_GENERATE_APPCAST="${2:-}"
      shift 2
      ;;
    --draft)
      DRAFT=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$ALLOW_DIRTY" == "1" && "$DRY_RUN" == "0" ]]; then
  echo "--allow-dirty is only supported with --dry-run" >&2
  exit 2
fi

if [[ -z "$VERSION_TAG" || -z "$BUILD_NUMBER" || -z "$SPARKLE_FEED_URL" || -z "$SPARKLE_PUBLIC_KEY" ]]; then
  usage >&2
  exit 2
fi

if [[ ! "$VERSION_TAG" =~ ^v[0-9]+(\.[0-9]+){1,2}(-[A-Za-z0-9.-]+)?$ ]]; then
  echo "--version must look like v0.1.0" >&2
  exit 2
fi

if [[ ! "$BUILD_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "--build must be an integer CFBundleVersion" >&2
  exit 2
fi

cd "$ROOT_DIR"
require_command git
require_command gh
require_command swift
require_clean_worktree
ensure_tag_points_at_head_or_is_absent

if [[ "$DRY_RUN" == "0" ]]; then
  require_command hdiutil
  require_command xcrun
  require_command codesign
  if [[ -z "$DEVELOPER_ID_APPLICATION" || -z "$NOTARYTOOL_PROFILE" ]]; then
    echo "DEVELOPER_ID_APPLICATION and NOTARYTOOL_PROFILE are required for publishing." >&2
    exit 2
  fi
  log_run gh auth status
else
  echo "Dry run: skipping gh auth, signing, packaging, notarization, appcast generation, and publishing side effects."
fi

MARKETING_VERSION="${VERSION_TAG#v}"
RELEASE_ROOT="$ROOT_DIR/.build/releases/$VERSION_TAG"
APP_DIR="$RELEASE_ROOT/MergeHawk.app"
DMG_ROOT="$RELEASE_ROOT/dmg-root"
APPCAST_INPUT_DIR="$RELEASE_ROOT/appcast-input"
DMG_PATH="$APPCAST_INPUT_DIR/MergeHawk-$MARKETING_VERSION.dmg"
APPCAST_NAME="$(basename "${SPARKLE_FEED_URL%%\?*}")"
if [[ "$APPCAST_NAME" != *.xml ]]; then
  APPCAST_NAME="appcast.xml"
fi
APPCAST_PATH="$APPCAST_INPUT_DIR/$APPCAST_NAME"

if [[ -z "$DOWNLOAD_URL_PREFIX" && "$DRY_RUN" == "0" ]]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"
  DOWNLOAD_URL_PREFIX="https://github.com/$REPO/releases/download/$VERSION_TAG"
elif [[ -z "$DOWNLOAD_URL_PREFIX" ]]; then
  DOWNLOAD_URL_PREFIX="https://github.com/OWNER/REPO/releases/download/$VERSION_TAG"
fi

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Would build MergeHawk $MARKETING_VERSION ($BUILD_NUMBER)"
  echo "Would use Sparkle feed: $SPARKLE_FEED_URL"
  echo "Would use appcast download prefix: $DOWNLOAD_URL_PREFIX"
  exit 0
fi

rm -rf "$RELEASE_ROOT"
mkdir -p "$DMG_ROOT" "$APPCAST_INPUT_DIR"

env \
  CONFIGURATION=release \
  APP_DIR="$APP_DIR" \
  CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION" \
  CODE_SIGN_OPTIONS=runtime \
  MARKETING_VERSION="$MARKETING_VERSION" \
  BUILD_NUMBER="$BUILD_NUMBER" \
  DISTRIBUTION_CHANNEL=github \
  SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
  SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY" \
  "$ROOT_DIR/scripts/build-app-bundle.sh" >/dev/null

GENERATE_APPCAST="$(find_generate_appcast)"
if [[ -z "$GENERATE_APPCAST" ]]; then
  echo "Could not find Sparkle generate_appcast. Build once or pass --generate-appcast PATH." >&2
  exit 2
fi

ditto "$APP_DIR" "$DMG_ROOT/MergeHawk.app"
ln -s /Applications "$DMG_ROOT/Applications"
log_run hdiutil create -volname MergeHawk -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"
log_run codesign --force --sign "$DEVELOPER_ID_APPLICATION" "$DMG_PATH"
log_run xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARYTOOL_PROFILE" --wait
log_run xcrun stapler staple "$DMG_PATH"
run_generate_appcast

if [[ ! -f "$APPCAST_PATH" ]]; then
  echo "Expected appcast not found: $APPCAST_PATH" >&2
  exit 2
fi

if ! git rev-parse "$VERSION_TAG" >/dev/null 2>&1; then
  log_run git tag "$VERSION_TAG"
fi
log_run git push origin "$VERSION_TAG"

release_args=(release create "$VERSION_TAG" "$DMG_PATH" "$APPCAST_PATH" --title "MergeHawk $VERSION_TAG" --notes "MergeHawk $VERSION_TAG")
if [[ "$DRAFT" == "1" ]]; then
  release_args+=(--draft)
fi
log_run gh "${release_args[@]}"

echo "Published GitHub release $VERSION_TAG"
