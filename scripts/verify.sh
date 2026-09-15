#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/verification-run.py"
SLOT="local"
RUN_DIR=""

usage() {
  cat <<'USAGE'
Usage: scripts/verify.sh [--slot <logical-name>] [--run-dir <absolute-path>]

Runs the Swift tests, core test runner, and slot-specific mock app packaging.
Starts a fresh verification run when --run-dir is omitted.
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

if [[ -z "$SLOT" ]]; then
  echo "--slot must not be empty" >&2
  exit 2
fi

if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$("$HELPER" --root "$ROOT_DIR" begin --slot "$SLOT")"
else
  RUN_DIR="$("$HELPER" --root "$ROOT_DIR" validate --slot "$SLOT" --run-dir "$RUN_DIR")"
fi

APP_NAME="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field app-name)"
BUNDLE_ID="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field bundle-id)"
EXECUTABLE_NAME="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field executable-name)"
PACKAGED_APP="$("$HELPER" --root "$ROOT_DIR" info --slot "$SLOT" --run-dir "$RUN_DIR" --field packaged-app)"
LOG_PATH="$RUN_DIR/logs/verify.log"
LAUNCH_ENVIRONMENT="$("$HELPER" --root "$ROOT_DIR" launch-environment --slot "$SLOT" --run-dir "$RUN_DIR")"

"$HELPER" --root "$ROOT_DIR" start --slot "$SLOT" --run-dir "$RUN_DIR" --command verify

set +e
(
  set -euo pipefail
  cd "$ROOT_DIR"
  swift test
  swift run mergehawkcoretestrunner
  APP_DIR="$PACKAGED_APP" \
  APP_NAME="$APP_NAME" \
  APP_EXECUTABLE_NAME="$EXECUTABLE_NAME" \
  BUNDLE_ID="$BUNDLE_ID" \
  LAUNCH_ENVIRONMENT="$LAUNCH_ENVIRONMENT" \
    scripts/build-app-bundle.sh
  "$HELPER" --root "$ROOT_DIR" validate-app \
    --slot "$SLOT" \
    --run-dir "$RUN_DIR" \
    --kind packaged \
    --path "$PACKAGED_APP"
) > >(tee "$LOG_PATH") 2>&1
exit_code=$?
set -e

finish_args=(
  --root "$ROOT_DIR" finish
  --slot "$SLOT"
  --run-dir "$RUN_DIR"
  --command verify
  --exit-code "$exit_code"
  --file "$LOG_PATH"
)

if [[ "$exit_code" == "0" ]]; then
  if ! "$HELPER" --root "$ROOT_DIR" record-app \
    --slot "$SLOT" \
    --run-dir "$RUN_DIR" \
    --kind packaged \
    --path "$PACKAGED_APP" \
    --bundle-id "$BUNDLE_ID" \
    --executable-name "$EXECUTABLE_NAME" \
    --mock; then
    exit_code=1
    finish_args=(
      --root "$ROOT_DIR" finish
      --slot "$SLOT"
      --run-dir "$RUN_DIR"
      --command verify
      --exit-code "$exit_code"
      --file "$LOG_PATH"
    )
  else
    finish_args+=(--file "$PACKAGED_APP" --detail "bundle_id=$BUNDLE_ID" --detail "mock=true")
  fi
fi

"$HELPER" "${finish_args[@]}"
echo "Verification run: $RUN_DIR"
exit "$exit_code"
