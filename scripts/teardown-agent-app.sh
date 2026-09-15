#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/verification-run.py"
SLOT=""
RUN_DIR=""

usage() {
  cat <<'USAGE'
Usage: scripts/teardown-agent-app.sh (--slot <original-logical-name> | --run-dir <absolute-path>)

Quits and removes only the exact slot runtime. Verification run evidence is kept.

Examples:
  scripts/teardown-agent-app.sh --slot MER-12
  scripts/teardown-agent-app.sh --run-dir "$RUN_DIR"
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slot)
      SLOT="${2:-}"
      shift 2
      ;;
    --run-dir)
      RUN_DIR="${2:-}"
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

if [[ -n "$SLOT" && -n "$RUN_DIR" ]] || [[ -z "$SLOT" && -z "$RUN_DIR" ]]; then
  echo "Provide exactly one of --slot or --run-dir" >&2
  usage >&2
  exit 2
fi

if [[ -n "$RUN_DIR" ]]; then
  SLOT="$("$HELPER" --root "$ROOT_DIR" identify --run-dir "$RUN_DIR" --field logical-slot)"
fi

BUNDLE_ID="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --allow-stale --field bundle-id)"
EXECUTABLE_NAME="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --allow-stale --field executable-name)"
RUNTIME_APP="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --allow-stale --field runtime-app)"
RUNTIME_DIR="$(dirname "$RUNTIME_APP")"
RUNTIME_EXECUTABLE="$RUNTIME_APP/Contents/MacOS/$EXECUTABLE_NAME"
PID_PATH="$RUNTIME_DIR/pid"

owned_pid() {
  local pid="${1:-}"
  local command=""
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == "$RUNTIME_EXECUTABLE" || "$command" == "$RUNTIME_EXECUTABLE "* ]]
}

wait_for_owned_exit() {
  local pid="$1"
  for _ in {1..30}; do
    if ! owned_pid "$pid"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

find_owned_pid() {
  local line pid command
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    command="${line#"$pid"}"
    command="${command#"${command%%[![:space:]]*}"}"
    if [[ "$command" == "$RUNTIME_EXECUTABLE" || "$command" == "$RUNTIME_EXECUTABLE "* ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done < <(ps -axo pid=,command=)
  return 1
}

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
pid=""
if [[ -f "$PID_PATH" ]]; then
  pid="$(<"$PID_PATH")"
fi
if ! owned_pid "$pid"; then
  pid="$(find_owned_pid || true)"
fi
if owned_pid "$pid"; then
  if ! wait_for_owned_exit "$pid"; then
    kill "$pid"
    if ! wait_for_owned_exit "$pid"; then
      echo "Owned slot process did not exit after SIGTERM: $pid ($RUNTIME_EXECUTABLE)" >&2
      exit 1
    fi
  fi
fi

expected_runtime_parent="$ROOT_DIR/.verification/$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --allow-stale --field slot-key)"
if [[ "$(dirname "$RUNTIME_DIR")" != "$expected_runtime_parent" || "$(basename "$RUNTIME_DIR")" != "runtime" ]]; then
  echo "Refusing unexpected runtime path: $RUNTIME_DIR" >&2
  exit 1
fi
rm -rf "$RUNTIME_DIR"

echo "Removed MergeHawk slot runtime: $SLOT"
