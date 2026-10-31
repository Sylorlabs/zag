#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-script-projection.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

"$compiler" selfhost/script_projection_test.zag -o "$tmp/script_projection_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/script_projection_test"
