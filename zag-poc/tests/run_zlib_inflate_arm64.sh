#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZNC=${ZNC:-$ROOT/znc}
QEMU=${QEMU:-qemu-aarch64-static}
TMP=$(mktemp -d /tmp/zag-zlib-inflate-arm64.XXXXXX)
trap 'rm -rf "$TMP"' EXIT

command -v "$QEMU" >/dev/null 2>&1 || {
  echo "zlib inflate ARM64 conformance requires $QEMU" >&2
  exit 1
}

"$ZNC" --target arm64 "$ROOT/tests/zlib_inflate.zag" \
  --no-zagd --analyze-strict --no-foreground-cache \
  -o "$TMP/zlib-inflate-arm64"
"$QEMU" "$TMP/zlib-inflate-arm64"
