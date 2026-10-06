#!/usr/bin/env bash
# Fails when free disk space drops below the agreed buffer (default 7 GB).
# Override with MIN_FREE_GB=<n>. Prints the free space and the build output size.
set -euo pipefail

MIN_FREE_GB="${MIN_FREE_GB:-7}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

free_kb=$(df -k /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print $4}')
if [[ -z "${free_kb}" ]]; then
  free_kb=$(df -k "$ROOT" | awk 'NR==2 {print $4}')
fi
free_gb=$(awk -v kb="$free_kb" 'BEGIN { printf "%.1f", kb / 1024 / 1024 }')

build_size="0B"
if [[ -d "$ROOT/.build" ]]; then
  build_size=$(du -sh "$ROOT/.build" 2>/dev/null | awk '{print $1}')
fi

echo "disk: ${free_gb} GB free (buffer ${MIN_FREE_GB} GB), build output ${build_size}"

if awk -v f="$free_gb" -v m="$MIN_FREE_GB" 'BEGIN { exit !(f < m) }'; then
  echo "error: free disk space is below the ${MIN_FREE_GB} GB buffer. Stop and free space before building." >&2
  exit 1
fi
