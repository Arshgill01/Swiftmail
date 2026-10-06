#!/usr/bin/env bash
# Builds and prints only compiler errors and warnings (deduplicated).
"$(dirname "$0")/build.sh" "$@" 2>&1 | grep -E "^/.*: (error|warning):|BUILD FAILED|^built:|^disk:|error: " | sort -u | head -60
