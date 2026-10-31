#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-utf8-normalization.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" tests/utf8_normalization.zag -o "$tmp/test" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test"
echo "utf8 normalization: pass (bounded NFC composition and fail-closed recovery)"
