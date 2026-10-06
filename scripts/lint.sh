#!/usr/bin/env bash
# SwiftFormat (check only) and SwiftLint over app, features and core sources.
# Pass --fix to apply SwiftFormat and SwiftLint autocorrections first.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PATHS=(App Features Packages/SwiftmailCore/Sources Packages/SwiftmailCore/Tests)

if [[ "${1:-}" == "--fix" ]]; then
  swiftformat "${PATHS[@]}" --quiet
  swiftlint lint --fix --quiet "${PATHS[@]}" >/dev/null || true
fi

swiftformat "${PATHS[@]}" --lint --quiet
swiftlint lint --strict --quiet "${PATHS[@]}"
echo "lint passed"
