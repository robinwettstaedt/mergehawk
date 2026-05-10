#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

swift test
swift run VCDashCoreTestRunner
swift build --product VCDash
scripts/build-app-bundle.sh >/dev/null
