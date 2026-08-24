#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-source-origins.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

"$compiler" selfhost/source_origin_test.zag -o "$tmp/source_origin_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/source_origin_test"
