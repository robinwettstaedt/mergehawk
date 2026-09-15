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

BUNDLE_ID="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --field bundle-id)"
EXECUTABLE_NAME="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --field executable-name)"
RUNTIME_APP="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --field runtime-app)"
RUNTIME_DIR="$(dirname "$RUNTIME_APP")"
RUNTIME_EXECUTABLE="$RUNTIME_APP/Contents/MacOS/$EXECUTABLE_NAME"

find_owned_pids() {
  local line pid command found=1
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    pid="${line%%[[:space:]]*}"
    command="${line#"$pid"}"
    command="${command#"${command%%[![:space:]]*}"}"
    if [[ "$command" == "$RUNTIME_EXECUTABLE" || "$command" == "$RUNTIME_EXECUTABLE "* ]]; then
      printf '%s\n' "$pid"
      found=0
    fi
  done < <(ps -axo pid=,command=)
  return "$found"
}

wait_for_all_owned_exit() {
  for _ in {1..30}; do
    if [[ -z "$(find_owned_pids || true)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
if ! wait_for_all_owned_exit; then
  pids="$(find_owned_pids || true)"
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  if ! wait_for_all_owned_exit; then
    remaining="$(find_owned_pids || true)"
    echo "Owned slot processes did not exit after SIGTERM: $remaining ($RUNTIME_EXECUTABLE)" >&2
    exit 1
  fi
fi

expected_runtime_parent="$ROOT_DIR/.verification/$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --field slot-key)"
if [[ "$(dirname "$RUNTIME_DIR")" != "$expected_runtime_parent" || "$(basename "$RUNTIME_DIR")" != "runtime" ]]; then
  echo "Refusing unexpected runtime path: $RUNTIME_DIR" >&2
  exit 1
fi
rm -rf "$RUNTIME_DIR"

echo "Removed MergeHawk slot runtime: $SLOT"
