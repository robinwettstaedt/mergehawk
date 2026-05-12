#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLOT=""

usage() {
  cat <<'USAGE'
Usage: scripts/teardown-agent-app.sh --slot <name>

Quits and removes a slot-specific MergeHawk app bundle and its generated
agent-slot artifacts.

Examples:
  scripts/teardown-agent-app.sh --slot MER-12
  scripts/teardown-agent-app.sh --slot agent-3
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      SLOT="${2:-}"
      shift 2
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
LOWER_SLOT="$(printf '%s' "$SAFE_SLOT" | tr '[:upper:]' '[:lower:]')"
COMPACT_LOWER_SLOT="$(printf '%s' "$LOWER_SLOT" | tr -d '-')"

declare -a slot_names=("$SAFE_SLOT")
if [[ "$LOWER_SLOT" != "$SAFE_SLOT" ]]; then
  slot_names+=("$LOWER_SLOT")
fi
if [[ "$COMPACT_LOWER_SLOT" != "$LOWER_SLOT" ]]; then
  slot_names+=("$COMPACT_LOWER_SLOT")
fi

for slot_name in "${slot_names[@]}"; do
  bundle_id="com.mergehawk.app.$slot_name"
  process_name="mergehawk-$slot_name"
  app_path="$HOME/Applications/MergeHawk $slot_name.app"

  osascript -e "tell application id \"$bundle_id\" to quit" >/dev/null 2>&1 || true
  pkill -x "$process_name" >/dev/null 2>&1 || true
  rm -rf "$app_path"
  rm -rf "$ROOT_DIR/.build/agent-slots/$slot_name"
done

echo "Removed MergeHawk slot: $SAFE_SLOT"
