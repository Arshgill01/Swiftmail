#!/usr/bin/env bash
# Writes a synthetic 30,000-thread mailbox to the app container as Preview.sqlite.
# Launch with: Swiftmail.app/Contents/MacOS/Swiftmail --database Preview.sqlite (debug builds)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
"$ROOT/scripts/disk-check.sh"
TARGET="$HOME/Library/Containers/app.swiftmail.Swiftmail/Data/Library/Application Support/Swiftmail/Preview.sqlite"
TEST_RUNNER_SWIFTMAIL_PREVIEW_DB="$TARGET" xcodebuild test \
  -project "$ROOT/Swiftmail.xcodeproj" -scheme Swiftmail -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$ROOT/.build/DerivedData" -skipPackagePluginValidation -quiet \
  -only-testing:SwiftmailCoreTests/PreviewDatabaseTool
ls -la "$TARGET"
