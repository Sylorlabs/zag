#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZNC=${ZNC:-$ROOT/znc}
TMP=$(mktemp -d /tmp/zag-zlib-inflate.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

"$ZNC" "$ROOT/tests/zlib_inflate.zag" \
  --no-zagd --analyze-strict --no-foreground-cache \
  -o "$TMP/zlib-inflate"
"$TMP/zlib-inflate"
