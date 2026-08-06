#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZNC=${ZNC:-$ROOT/znc}
TMP=$(mktemp -d /tmp/zag-compression.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

"$ZNC" "$ROOT/tests/compression_primitives.zag" \
  --no-zagd --analyze-strict --no-foreground-cache \
  -o "$TMP/compression-primitives"
"$TMP/compression-primitives"
