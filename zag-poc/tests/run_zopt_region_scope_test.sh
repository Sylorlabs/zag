#!/usr/bin/env bash
# Experimental optimizer regression only; not v2 production compiler evidence.
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zopt-region-scope.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" selfhost/native/zopt_region_scope_test.zag -o "$tmp/test" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test"
