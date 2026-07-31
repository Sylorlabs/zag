#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
if diff -u docs/V2_SUPPORT_MATRIX.generated.md <(bash tests/generate_v2_support_matrix.sh); then
  echo '  ok  generated v2 support matrix matches authoritative release gate'
else
  echo '  XX  generated v2 support matrix is stale; run bash tests/generate_v2_support_matrix.sh'
  exit 1
fi
