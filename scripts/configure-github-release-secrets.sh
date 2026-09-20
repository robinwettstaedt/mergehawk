#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RELEASE_ENV_FILE="${RELEASE_ENV_FILE:-$ROOT_DIR/scripts/release-github.env}"
RELEASE_LOCAL_ENV_FILE="${RELEASE_LOCAL_ENV_FILE:-$ROOT_DIR/scripts/release-github.local.env}"
DRY_RUN=0

usage() {
  cat <<'USAGE'
Usage: scripts/configure-github-release-secrets.sh [--dry-run]

Uploads MergeHawk GitHub release variables and secrets from:
  scripts/release-github.env
  scripts/release-github.local.env

The local env file is gitignored and should contain the private values.

Options:
  --dry-run   Validate required values without uploading anything
  -h, --help  Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
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

if ! command -v gh >/dev/null 2>&1; then
  echo "Required command not found: gh" >&2
  exit 2
fi

# shellcheck source=scripts/lib/release-env.sh
source "$ROOT_DIR/scripts/lib/release-env.sh"

RELEASE_ENV_KEYS=(
  RELEASE_REPOSITORY DOWNLOADS_TOKEN SPARKLE_FEED_URL SPARKLE_PUBLIC_KEY DEVELOPER_ID_APPLICATION SPARKLE_PRIVATE_KEY
  DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD
  APPLE_ID APPLE_TEAM_ID APPLE_APP_SPECIFIC_PASSWORD
)
load_release_env_file "$RELEASE_ENV_FILE" "${RELEASE_ENV_KEYS[@]}"

if [[ ! -f "$RELEASE_LOCAL_ENV_FILE" ]]; then
  echo "Missing local release credential file: $RELEASE_LOCAL_ENV_FILE" >&2
  exit 2
fi

load_release_env_file "$RELEASE_LOCAL_ENV_FILE" "${RELEASE_ENV_KEYS[@]}"

required_names=(
  DOWNLOADS_TOKEN
  DEVELOPER_ID_APPLICATION
  SPARKLE_PRIVATE_KEY
  DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64
  DEVELOPER_ID_CERTIFICATE_PASSWORD
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD
)

for name in "${required_names[@]}"; do
  value="${!name:-}"
  if [[ -z "$value" || "$value" == TODO:* ]]; then
    echo "Missing required value: $name" >&2
    exit 2
  fi
done

if [[ "$DRY_RUN" == "1" ]]; then
  echo "Release GitHub variables/secrets are present."
  exit 0
fi

gh variable set DEVELOPER_ID_APPLICATION --body "$DEVELOPER_ID_APPLICATION"

gh secret set DOWNLOADS_TOKEN --body "$DOWNLOADS_TOKEN"

gh secret set SPARKLE_PRIVATE_KEY --body "$SPARKLE_PRIVATE_KEY"
gh secret set DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64 --body "$DEVELOPER_ID_APPLICATION_CERTIFICATE_P12_BASE64"
gh secret set DEVELOPER_ID_CERTIFICATE_PASSWORD --body "$DEVELOPER_ID_CERTIFICATE_PASSWORD"
gh secret set APPLE_ID --body "$APPLE_ID"
gh secret set APPLE_TEAM_ID --body "$APPLE_TEAM_ID"
gh secret set APPLE_APP_SPECIFIC_PASSWORD --body "$APPLE_APP_SPECIFIC_PASSWORD"

echo "Configured GitHub release variables and secrets."
