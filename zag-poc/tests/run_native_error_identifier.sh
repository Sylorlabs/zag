#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
znc=${ZNC:-"$root/znc"}
tmp=$(mktemp -d /tmp/zag-native-error-identifier.XXXXXX)
cleanup() { rm -rf -- "$tmp"; }
trap cleanup EXIT

"$znc" "$root/tests/native_error_identifier.zag" --no-zagd \
    --analyze-strict --no-foreground-cache -o "$tmp/x86"
output=$("$tmp/x86")
if [ "$output" != "native error identifier: PASS" ]; then
    printf 'native error identifier: unexpected x86 output: %s\n' "$output" >&2
    exit 1
fi

"$znc" "$root/tests/native_error_identifier.zag" --target arm64 --no-zagd \
    --analyze-strict --no-foreground-cache -o "$tmp/arm64"
file "$tmp/arm64" | grep -q 'ARM aarch64'

printf 'native error identifier: PASS (x86-64 runtime, ARM64 compile)\n'
