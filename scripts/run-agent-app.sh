#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOT=""
MOCK=0
OPEN_APP=1
NOTIFICATION_TYPE_FIXTURES=0

usage() {
  cat <<'USAGE'
Usage: scripts/run-agent-app.sh --slot <name> [--mock] [--notification-type-fixtures] [--open|--no-open]

Builds and installs a slot-specific MergeHawk app bundle so multiple agents can
work from different checkouts without replacing the user's normal app bundle.

Examples:
  scripts/run-agent-app.sh --slot agent-3 --mock --open
  scripts/run-agent-app.sh --slot agent-3 --mock --notification-type-fixtures --open
  scripts/run-agent-app.sh --slot agent-3 --mock --no-open
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      SLOT="${2:-}"
      shift 2
      ;;
    --mock)
      MOCK=1
      shift
      ;;
    --notification-type-fixtures)
      NOTIFICATION_TYPE_FIXTURES=1
      shift
      ;;
    --open)
      OPEN_APP=1
      shift
      ;;
    --no-open)
      OPEN_APP=0
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

if [[ -z "$SLOT" ]]; then
  echo "--slot is required" >&2
  usage >&2
  exit 2
fi

SAFE_SLOT="$(printf '%s' "$SLOT" | tr -c '[:alnum:]_-' '-')"
APP_NAME="MergeHawk $SAFE_SLOT.app"
APP_EXECUTABLE_NAME="mergehawk-$SAFE_SLOT"
BUNDLE_ID="com.mergehawk.app.$SAFE_SLOT"
APP_PATH="$HOME/Applications/$APP_NAME"
ARTIFACT_DIR="$ROOT_DIR/.build/agent-slots/$SAFE_SLOT"
LAUNCH_ENVIRONMENT="MERGEHAWK_SUPPRESS_MACOS_NOTIFICATIONS=1 MERGEHAWK_NOTIFICATION_LOG=$ARTIFACT_DIR/notifications.jsonl"

mkdir -p "$ARTIFACT_DIR"
rm -f "$ARTIFACT_DIR/notifications.jsonl"

if [[ "$MOCK" == "1" ]]; then
  LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT MERGEHAWK_MOCK_MODE=1"
fi
if [[ "$NOTIFICATION_TYPE_FIXTURES" == "1" ]]; then
  LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT MERGEHAWK_NOTIFICATION_TYPE_FIXTURES=1"
fi

cd "$ROOT_DIR"
APP_NAME="$APP_NAME" \
APP_EXECUTABLE_NAME="$APP_EXECUTABLE_NAME" \
PROCESS_NAME="$APP_EXECUTABLE_NAME" \
BUNDLE_ID="$BUNDLE_ID" \
APP_PATH="$APP_PATH" \
RESTART="$OPEN_APP" \
LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT" \
  scripts/update-installed-app.sh

if [[ "$OPEN_APP" == "0" ]]; then
  echo "Built agent app without opening: $APP_PATH"
fi
echo "Notification log: $ARTIFACT_DIR/notifications.jsonl"
