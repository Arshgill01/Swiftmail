#!/usr/bin/env bash
# Lint, build the app, and run every unit test. Must pass before each milestone commit.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/lint.sh"
"$ROOT/scripts/build.sh"

xcodebuild test \
  -project Swiftmail.xcodeproj \
  -scheme Swiftmail \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -resultBundlePath "$ROOT/.build/TestResults-$(date +%s).xcresult" \
  -skipPackagePluginValidation \
  -quiet "$@"

# Keep only the latest result bundle so test runs don't pile up on disk.
ls -dt "$ROOT"/.build/TestResults-*.xcresult 2>/dev/null | tail -n +2 | xargs rm -rf
echo "tests passed"
"$ROOT/scripts/disk-check.sh"
