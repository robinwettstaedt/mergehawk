#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/verification-run.py"
SLOT="local"
RUN_DIR=""
OPEN_APP=1
NOTIFICATION_TYPE_FIXTURES=0
HEALTH_TIMEOUT_SECONDS=10

usage() {
  cat <<'USAGE'
Usage: scripts/run-agent-app.sh [--slot <name>] [--run-dir <absolute-path>] [--mock] [--notification-type-fixtures] [--open|--no-open]

Launches a run-bound, mock-only MergeHawk app bundle without replacing the
normal installed app. Starts a fresh verification run when --run-dir is omitted.

Examples:
  scripts/run-agent-app.sh --slot agent-3 --mock --open
  scripts/run-agent-app.sh --slot agent-3 --run-dir "$RUN_DIR" --mock --open
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
    --mock)
      shift
      ;;
    --health-timeout)
      HEALTH_TIMEOUT_SECONDS="${2:-}"
      shift 2
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
  echo "--slot must not be empty" >&2
  exit 2
fi

if ! [[ "$HEALTH_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--health-timeout must be a nonnegative number" >&2
  exit 2
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$("$HELPER" --root "$ROOT_DIR" begin --slot "$SLOT")"
else
  RUN_DIR="$("$HELPER" --root "$ROOT_DIR" validate --slot "$SLOT" --run-dir "$RUN_DIR")"
fi

APP_NAME="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field app-name)"
APP_EXECUTABLE_NAME="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field executable-name)"
BUNDLE_ID="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field bundle-id)"
PACKAGED_APP="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field packaged-app)"
RUNTIME_APP="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field runtime-app)"
NOTIFICATION_PATH="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field notifications)"
RUNTIME_DIR="$(dirname "$RUNTIME_APP")"
RUNTIME_EXECUTABLE="$RUNTIME_APP/Contents/MacOS/$APP_EXECUTABLE_NAME"
PID_PATH="$RUNTIME_DIR/pid"
LOG_PATH="$RUN_DIR/logs/app.log"
printf -v QUOTED_NOTIFICATION_PATH '%q' "$NOTIFICATION_PATH"
LAUNCH_ENVIRONMENT="MERGEHAWK_MOCK_MODE=1 MERGEHAWK_MOCK_REFRESH_DELAY_SECONDS=3 MERGEHAWK_NOTIFICATION_LOG=$QUOTED_NOTIFICATION_PATH MERGEHAWK_SUPPRESS_MACOS_NOTIFICATIONS=1"
if [[ "$NOTIFICATION_TYPE_FIXTURES" == "1" ]]; then
  LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT MERGEHAWK_NOTIFICATION_TYPE_FIXTURES=1"
fi

FIXTURE_OPTION=""
if [[ "$NOTIFICATION_TYPE_FIXTURES" == "1" ]]; then
  FIXTURE_OPTION="--notification-type-fixtures"
fi

owned_pid() {
  local pid="${1:-}"
  local command=""
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == "$RUNTIME_EXECUTABLE" || "$command" == "$RUNTIME_EXECUTABLE "* ]]
}

stop_owned_runtime() {
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  if [[ -f "$PID_PATH" ]]; then
    local pid
    pid="$(<"$PID_PATH")"
    if owned_pid "$pid"; then
      local attempt
      for attempt in {1..30}; do
        if ! owned_pid "$pid"; then
          break
        fi
        sleep 0.1
      done
      if owned_pid "$pid"; then
        kill "$pid"
      fi
    fi
  fi
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

"$HELPER" --root "$ROOT_DIR" start --slot "$SLOT" --run-dir "$RUN_DIR" --command app

set +e
(
  set -euo pipefail
  cd "$ROOT_DIR"
  if [[ -d "$PACKAGED_APP" ]]; then
    "$HELPER" --root "$ROOT_DIR" validate-app \
      --slot "$SLOT" \
      --run-dir "$RUN_DIR" \
      --kind packaged \
      --path "$PACKAGED_APP" \
      --require-recorded \
      $FIXTURE_OPTION
  else
    APP_DIR="$PACKAGED_APP" \
    APP_NAME="$APP_NAME" \
    APP_EXECUTABLE_NAME="$APP_EXECUTABLE_NAME" \
    BUNDLE_ID="$BUNDLE_ID" \
    LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT" \
      scripts/build-app-bundle.sh
    "$HELPER" --root "$ROOT_DIR" validate-app \
      --slot "$SLOT" \
      --run-dir "$RUN_DIR" \
      --kind packaged \
      --path "$PACKAGED_APP" \
      $FIXTURE_OPTION
    "$HELPER" --root "$ROOT_DIR" record-app \
      --slot "$SLOT" \
      --run-dir "$RUN_DIR" \
      --kind packaged \
      --path "$PACKAGED_APP" \
      --bundle-id "$BUNDLE_ID" \
      --executable-name "$APP_EXECUTABLE_NAME" \
      --mock \
      $FIXTURE_OPTION
  fi

  stop_owned_runtime
  rm -rf "$RUNTIME_DIR"
  mkdir -p "$RUNTIME_DIR"
  ditto "$PACKAGED_APP" "$RUNTIME_APP"
  : > "$NOTIFICATION_PATH"
  "$HELPER" --root "$ROOT_DIR" validate-app \
    --slot "$SLOT" \
    --run-dir "$RUN_DIR" \
    --kind runtime \
    --path "$RUNTIME_APP" \
    $FIXTURE_OPTION

  if [[ "$OPEN_APP" == "1" ]]; then
    open -n "$RUNTIME_APP"
    deadline=$(/usr/bin/python3 - "$HEALTH_TIMEOUT_SECONDS" <<'PY'
import sys, time
print(time.monotonic() + float(sys.argv[1]))
PY
)
    pid=""
    while [[ -z "$pid" ]]; do
      pid="$(find_owned_pid || true)"
      if [[ -n "$pid" ]]; then
        break
      fi
      if /usr/bin/python3 - "$deadline" <<'PY'
import sys, time
raise SystemExit(0 if time.monotonic() >= float(sys.argv[1]) else 1)
PY
      then
        echo "Timed out waiting for exact executable: $RUNTIME_EXECUTABLE" >&2
        exit 1
      fi
      sleep 0.1
    done
    printf '%s\n' "$pid" > "$PID_PATH"
    echo "Launched exact slot executable: $RUNTIME_EXECUTABLE (pid $pid)"
  else
    echo "Prepared slot app without opening: $RUNTIME_APP"
  fi
) > >(tee "$LOG_PATH") 2>&1
exit_code=$?
set -e

if [[ "$exit_code" == "0" ]]; then
  if ! "$HELPER" --root "$ROOT_DIR" record-app \
    --slot "$SLOT" \
    --run-dir "$RUN_DIR" \
    --kind runtime \
    --path "$RUNTIME_APP" \
    --bundle-id "$BUNDLE_ID" \
    --executable-name "$APP_EXECUTABLE_NAME" \
    --mock \
    $FIXTURE_OPTION; then
    exit_code=1
  fi
fi

finish_args=(
  --root "$ROOT_DIR" finish
  --slot "$SLOT"
  --run-dir "$RUN_DIR"
  --command app
  --exit-code "$exit_code"
  --file "$LOG_PATH"
  --detail "opened=$OPEN_APP"
)
if [[ -f "$NOTIFICATION_PATH" ]]; then
  finish_args+=(--file "$NOTIFICATION_PATH")
fi
if [[ "$exit_code" == "0" ]]; then
  finish_args+=(--file "$RUNTIME_APP" --detail "bundle_id=$BUNDLE_ID" --detail "mock=true")
fi
"$HELPER" "${finish_args[@]}"

echo "Verification run: $RUN_DIR"
echo "Notification log: $NOTIFICATION_PATH"
exit "$exit_code"
