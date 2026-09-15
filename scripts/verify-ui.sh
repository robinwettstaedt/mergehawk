#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HELPER="$ROOT_DIR/scripts/verification-run.py"
SLOT="local"
RUN_DIR=""
STAGE="ui"
WAIT_TIMEOUT_SECONDS="${MERGEHAWK_UI_WAIT_TIMEOUT_SECONDS:-5}"
SCENARIO_SELECTOR=""
SURFACE_SELECTOR=""

usage() {
  cat <<'USAGE'
Usage: scripts/verify-ui.sh [--slot <name>] [--run-dir <absolute-path>]
                            [--stage <unique-name>] [--scenario <fixture-name>]...
                            [--surface menu|settings]... [--wait-timeout <seconds>]

Writes paired light/dark visual captures into a unique run stage. Starts a
fresh verification run when --run-dir is omitted.
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
      STAGE="${2:-}"
      shift 2
      ;;
    --scenario)
      scenario="${2:-}"
      if [[ -z "$scenario" || "$scenario" == *,* ]]; then
        echo "--scenario must be one nonempty fixture name" >&2
        exit 2
      fi
      SCENARIO_SELECTOR="${SCENARIO_SELECTOR:+$SCENARIO_SELECTOR,}$scenario"
      shift 2
      ;;
    --surface)
      surface="${2:-}"
      if [[ "$surface" != "menu" && "$surface" != "settings" ]]; then
        echo "Invalid surface: $surface (expected menu or settings)" >&2
        exit 2
      fi
      SURFACE_SELECTOR="${SURFACE_SELECTOR:+$SURFACE_SELECTOR,}$surface"
      shift 2
      ;;
    --wait-timeout)
      WAIT_TIMEOUT_SECONDS="${2:-}"
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

if [[ -z "$SLOT" || ! "$STAGE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "--slot must be nonempty and --stage may contain only letters, numbers, _ and -" >&2
  exit 2
fi
if ! [[ "$WAIT_TIMEOUT_SECONDS" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  echo "--wait-timeout must be a nonnegative number" >&2
  exit 2
fi
if [[ -z "$RUN_DIR" ]]; then
  RUN_DIR="$("$HELPER" --root "$ROOT_DIR" begin --slot "$SLOT")"
else
  RUN_DIR="$("$HELPER" --root "$ROOT_DIR" validate --slot "$SLOT" --run-dir "$RUN_DIR")"
fi

OUTPUT_DIR="$RUN_DIR/screenshots/$STAGE"
LOG_PATH="$RUN_DIR/logs/$STAGE.log"

"$HELPER" --root "$ROOT_DIR" start \
  --slot "$SLOT" \
  --run-dir "$RUN_DIR" \
  --command "$STAGE" \
  --output-path "screenshots/$STAGE"
mkdir "$OUTPUT_DIR"

cd "$ROOT_DIR"
set +e
MERGEHAWK_UI_ARTIFACT_DIR="$OUTPUT_DIR" \
MERGEHAWK_UI_SCENARIOS="$SCENARIO_SELECTOR" \
MERGEHAWK_UI_SURFACES="$SURFACE_SELECTOR" \
MERGEHAWK_UI_WAIT_TIMEOUT_SECONDS="$WAIT_TIMEOUT_SECONDS" \
  swift test --filter VisualVerificationXCTests > >(tee "$LOG_PATH") 2>&1
exit_code=$?
set -e

declare -a output_files=()
while IFS= read -r -d '' output_file; do
  output_files+=("$output_file")
done < <(find "$OUTPUT_DIR" -type f -name '*.png' -print0)

if [[ "$exit_code" == "0" && "${#output_files[@]}" == "0" ]]; then
  echo "Visual capture produced no PNG files" | tee -a "$LOG_PATH" >&2
  exit_code=1
fi

finish_args=(
  --root "$ROOT_DIR" finish
  --slot "$SLOT"
  --run-dir "$RUN_DIR"
  --command "$STAGE"
  --exit-code "$exit_code"
  --file "$LOG_PATH"
  --detail "scenarios=$SCENARIO_SELECTOR"
  --detail "surfaces=$SURFACE_SELECTOR"
)
if [[ "${#output_files[@]}" -gt 0 ]]; then
  for output_file in "${output_files[@]}"; do
    finish_args+=(--file "$output_file")
  done
fi
"$HELPER" "${finish_args[@]}"

echo "Verification run: $RUN_DIR"
echo "UI artifacts:"
if [[ "${#output_files[@]}" -gt 0 ]]; then
  printf '  %s\n' "${output_files[@]}"
fi
exit "$exit_code"
