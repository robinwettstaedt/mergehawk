#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="VC Dash.app"
PROCESS_NAME="VCDash"
APP_PATH="${APP_PATH:-}"
RESTART="${RESTART:-1}"

cd "$ROOT_DIR"

build_output="$(CONFIGURATION="${CONFIGURATION:-debug}" scripts/build-app-bundle.sh)"
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
  osascript -e 'tell application "VC Dash" to quit' >/dev/null 2>&1 || true
  pkill -x "$PROCESS_NAME" >/dev/null 2>&1 || true
fi

rm -rf "$APP_PATH"
ditto "$built_app" "$APP_PATH"

if [[ "$RESTART" == "1" ]]; then
  open "$APP_PATH"
fi

echo "Updated $APP_PATH"
