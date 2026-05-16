#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="${APP_NAME:-MergeHawk.app}"
PROCESS_NAME="${PROCESS_NAME:-${APP_EXECUTABLE_NAME:-mergehawk}}"
BUNDLE_ID="${BUNDLE_ID:-com.mergehawk.app}"
APP_PATH="${APP_PATH:-}"
RESTART="${RESTART:-1}"
LAUNCH_ENVIRONMENT="${LAUNCH_ENVIRONMENT:-}"

cd "$ROOT_DIR"

if [[ -f "$ROOT_DIR/.env.local" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env.local"
  set +a
fi

append_launch_environment() {
  local key="$1"
  local value="${!key:-}"
  if [[ -n "$value" && "$LAUNCH_ENVIRONMENT" != *"$key="* ]]; then
    LAUNCH_ENVIRONMENT="${LAUNCH_ENVIRONMENT:+$LAUNCH_ENVIRONMENT }$key=$(printf '%q' "$value")"
  fi
}

append_launch_environment "MERGEHAWK_GITHUB_OAUTH_CLIENT_ID"
append_launch_environment "MERGEHAWK_GITHUB_OAUTH_CLIENT_SECRET"

build_output="$(CONFIGURATION="${CONFIGURATION:-debug}" APP_NAME="$APP_NAME" BUNDLE_ID="$BUNDLE_ID" APP_EXECUTABLE_NAME="${APP_EXECUTABLE_NAME:-mergehawk}" LAUNCH_ARGUMENTS="${LAUNCH_ARGUMENTS:-}" LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT" scripts/build-app-bundle.sh)"
printf '%s\n' "$build_output"
built_app="$(printf '%s\n' "$build_output" | tail -n 1)"

if [[ -z "$APP_PATH" ]]; then
  if [[ -d "/Applications/$APP_NAME" ]]; then
    APP_PATH="/Applications/$APP_NAME"
  elif [[ -d "$HOME/Applications/$APP_NAME" ]]; then
    APP_PATH="$HOME/Applications/$APP_NAME"
  else
    mkdir -p "$HOME/Applications"
    APP_PATH="$HOME/Applications/$APP_NAME"
  fi
fi

if [[ "$RESTART" == "1" ]]; then
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
fi

rm -rf "$APP_PATH"
ditto "$built_app" "$APP_PATH"

if [[ "$RESTART" == "1" ]]; then
  open "$APP_PATH"
fi

echo "Updated $APP_PATH"
