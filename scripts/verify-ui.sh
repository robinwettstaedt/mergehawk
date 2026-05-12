#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${MERGEHAWK_UI_ARTIFACT_DIR:-$ROOT_DIR/.build/verification/ui}"

cd "$ROOT_DIR"
mkdir -p "$OUTPUT_DIR"
MERGEHAWK_UI_ARTIFACT_DIR="$OUTPUT_DIR" swift test --filter VisualVerificationXCTests

echo "UI artifacts: $OUTPUT_DIR"
