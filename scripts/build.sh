#!/usr/bin/env bash
# Generates the Xcode project and builds the app. Build output stays in .build/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

"$ROOT/scripts/disk-check.sh"
xcodegen generate --quiet

CONFIG="${CONFIG:-Debug}"
set -o pipefail
xcodebuild build \
  -project Swiftmail.xcodeproj \
  -scheme Swiftmail \
  -configuration "$CONFIG" \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -skipPackagePluginValidation \
  ONLY_ACTIVE_ARCH=YES \
  -quiet "$@"

echo "built: $ROOT/.build/DerivedData/Build/Products/$CONFIG/Swiftmail.app"
"$ROOT/scripts/disk-check.sh"
