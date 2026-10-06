#!/usr/bin/env bash
# Prints failing tests and their messages from the latest result bundle.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE=$(ls -dt "$ROOT"/.build/TestResults-*.xcresult 2>/dev/null | head -1)
[[ -z "$BUNDLE" ]] && { echo "no result bundle"; exit 1; }
xcrun xcresulttool get test-results summary --path "$BUNDLE" --compact 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
print(f"{d["result"]}: {d["passedTests"]}/{d["totalTestCount"]} passed, {d["failedTests"]} failed, {d["skippedTests"]} skipped")
'
xcrun xcresulttool get test-results tests --path "$BUNDLE" --format json 2>/dev/null | python3 -c '
import json, sys
data = json.load(sys.stdin)
def walk(node):
    if node.get("result") == "Failed" and node.get("nodeType") == "Test Case":
        print("FAIL", node.get("nodeIdentifier") or node.get("name"))
        for child in node.get("children", []):
            if child.get("nodeType") == "Failure Message":
                print("    ", child.get("name"))
    for child in node.get("children", []):
        walk(child)
for node in data.get("testNodes", []):
    walk(node)
'
