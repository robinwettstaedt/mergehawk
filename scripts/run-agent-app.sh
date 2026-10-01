#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/verification-run.py"
SLOT="local"
RUN_DIR=""
LAUNCH_STAGE="app"
OPEN_APP=1
UI_SURFACE="settings"
NOTIFICATION_TYPE_FIXTURES=0
MOCK_SCENARIO="standard"
HEALTH_TIMEOUT_SECONDS=10

usage() {
  cat <<'USAGE'
Usage: scripts/run-agent-app.sh [--slot <name>] [--run-dir <absolute-path>] [--stage <unique-name>] [--mock] [--mock-scenario <name>] [--notification-type-fixtures] [--open|--no-open] [--ui settings|menu|native]

Launches a run-bound, mock-only MergeHawk app bundle without replacing the
normal installed app. Opens Settings by default for unattended computer use.
Use --ui native for normal menu bar presentation during human review.
Starts a fresh verification run when --run-dir is omitted.
When reusing a run, preserve its recorded --mock-scenario and replay
--notification-type-fixtures when the packaged verified bundle used it.

Examples:
  scripts/run-agent-app.sh --slot agent-3 --mock --open
  scripts/run-agent-app.sh --slot agent-3 --mock --mock-scenario merged-final-activity --ui menu --open
  scripts/run-agent-app.sh --slot agent-3 --mock --mock-scenario bot-notifications --ui menu --open
  scripts/run-agent-app.sh --slot agent-3 --mock --mock-scenario comment-notifications --ui settings --open
  scripts/run-agent-app.sh --slot agent-3 --mock --mock-scenario new-review-request --ui menu --open
  scripts/run-agent-app.sh --slot agent-3 --run-dir "$RUN_DIR" --stage app-final-activity --mock --mock-scenario merged-final-activity --ui menu --open
  # Native handoff for a run verified with long-lists and notification type fixtures:
  scripts/run-agent-app.sh --slot agent-3 --run-dir "$RUN_DIR" --stage app-review --ui native --mock --mock-scenario long-lists --notification-type-fixtures --open
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
    --stage)
      LAUNCH_STAGE="${2:-}"
      shift 2
      ;;
    --mock)
      shift
      ;;
    --ui)
      UI_SURFACE="${2:-}"
      shift 2
      ;;
    --health-timeout)
      HEALTH_TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --notification-type-fixtures)
      NOTIFICATION_TYPE_FIXTURES=1
      shift
      ;;
    --mock-scenario)
      MOCK_SCENARIO="${2:-}"
      shift 2
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
if [[ ! "$LAUNCH_STAGE" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "--stage must contain only letters, numbers, dots, underscores or hyphens" >&2
  exit 2
fi
if [[ "$UI_SURFACE" != "settings" && "$UI_SURFACE" != "menu" && "$UI_SURFACE" != "native" ]]; then
  echo "--ui must be settings, menu or native" >&2
  exit 2
fi
case "$MOCK_SCENARIO" in
  standard|delayed-refresh|refresh-failure|merged-final-activity|quiet-access-loss|bot-notifications|comment-notifications|long-lists|new-review-request) ;;
  *)
    echo "--mock-scenario must be standard, delayed-refresh, refresh-failure, merged-final-activity, quiet-access-loss, bot-notifications, comment-notifications, long-lists or new-review-request" >&2
    exit 2
    ;;
esac

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
if [[ "$LAUNCH_STAGE" == "app" ]]; then
  LOG_PATH="$RUN_DIR/logs/app.log"
else
  LOG_PATH="$RUN_DIR/logs/$LAUNCH_STAGE.log"
  NOTIFICATION_PATH="$RUN_DIR/notifications-$LAUNCH_STAGE.jsonl"
fi

FIXTURE_OPTION=""
if [[ "$NOTIFICATION_TYPE_FIXTURES" == "1" ]]; then
  FIXTURE_OPTION="--notification-type-fixtures"
fi
LAUNCH_ENVIRONMENT="$("$HELPER" --root "$ROOT_DIR" launch-environment \
  --slot "$SLOT" \
  --run-dir "$RUN_DIR" \
  $FIXTURE_OPTION)"

owned_pid() {
  local pid="${1:-}"
  local command=""
  if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  command="$(ps -p "$pid" -o command= 2>/dev/null || true)"
  [[ "$command" == "$RUNTIME_EXECUTABLE" || "$command" == "$RUNTIME_EXECUTABLE "* ]]
}

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
  local attempt
  for attempt in {1..30}; do
    if [[ -z "$(find_owned_pids || true)" ]]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

stop_owned_runtime() {
  local pid pids remaining
  osascript -e 'with timeout of 2 seconds' -e "tell application id \"$BUNDLE_ID\" to quit" -e 'end timeout' >/dev/null 2>&1 || true
  if wait_for_all_owned_exit; then
    rm -f "$PID_PATH"
    return 0
  fi
  pids="$(find_owned_pids || true)"
  for pid in $pids; do
    kill "$pid" 2>/dev/null || true
  done
  if ! wait_for_all_owned_exit; then
    remaining="$(find_owned_pids || true)"
    echo "Owned slot processes did not exit after SIGTERM: $remaining ($RUNTIME_EXECUTABLE)" >&2
    return 1
  fi
  rm -f "$PID_PATH"
}

"$HELPER" --root "$ROOT_DIR" start --slot "$SLOT" --run-dir "$RUN_DIR" --command "$LAUNCH_STAGE" --app-launch

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
    launch_args=(--mock-scenario "$MOCK_SCENARIO" --notification-log "$NOTIFICATION_PATH")
    if [[ "$UI_SURFACE" != "native" ]]; then
      launch_args=(--verification-ui "$UI_SURFACE" "${launch_args[@]}")
    fi
    open -g -n "$RUNTIME_APP" --args "${launch_args[@]}"
    deadline=$(/usr/bin/python3 - "$HEALTH_TIMEOUT_SECONDS" <<'PY'
import sys, time
print(time.monotonic() + float(sys.argv[1]))
PY
)
    pid=""
    while [[ -z "$pid" ]]; do
      pid="$(find_owned_pids || true)"
      pid="${pid%%$'\n'*}"
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
    sleep 0.5
    if ! owned_pid "$pid"; then
      echo "Slot process exited during post-launch health check: $pid ($RUNTIME_EXECUTABLE)" >&2
      exit 1
    fi
    printf '%s\n' "$pid" > "$PID_PATH"
    echo "Launched exact slot executable: $RUNTIME_EXECUTABLE (pid $pid)"
  else
    echo "Prepared slot app without opening: $RUNTIME_APP"
  fi
) 2>&1 | tee "$LOG_PATH"
pipeline_status=("${PIPESTATUS[@]}")
set -e
exit_code="${pipeline_status[0]}"
if [[ "$exit_code" == "0" && "${pipeline_status[1]}" != "0" ]]; then
  exit_code="${pipeline_status[1]}"
fi

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
  --command "$LAUNCH_STAGE"
  --exit-code "$exit_code"
  --file "$LOG_PATH"
  --detail "opened=$OPEN_APP"
  --detail "ui=$UI_SURFACE"
  --detail "mock_scenario=$MOCK_SCENARIO"
)
if [[ -f "$NOTIFICATION_PATH" ]]; then
  finish_args+=(--file "$NOTIFICATION_PATH")
fi
if [[ "$exit_code" == "0" ]]; then
  finish_args+=(--detail "bundle_id=$BUNDLE_ID" --detail "mock=true")
fi
"$HELPER" "${finish_args[@]}"

echo "Verification run: $RUN_DIR"
echo "Notification log: $NOTIFICATION_PATH"
exit "$exit_code"
