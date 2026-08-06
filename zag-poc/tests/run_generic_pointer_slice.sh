#!/bin/sh
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
znc=${ZNC:-"$root/znc"}
qemu=${QEMU_AARCH64:-/usr/bin/qemu-aarch64-static}
tmp=$(mktemp -d /tmp/zag-generic-pointer-slice.XXXXXX)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

"$znc" "$root/tests/generic_pointer_slice.zag" --no-zagd \
    --analyze-strict --no-foreground-cache -o "$tmp/x86"
set +e
"$tmp/x86"
x86_status=$?
set -e
[ "$x86_status" -eq 42 ]

"$znc" "$root/tests/generic_pointer_slice.zag" --target arm64 --no-zagd \
    --analyze-strict --no-foreground-cache -o "$tmp/arm64"
set +e
"$qemu" "$tmp/arm64"
arm64_status=$?
set -e
[ "$arm64_status" -eq 42 ]

if "$znc" "$root/tests/generic_pointer_slice_open_ended_bad.zag" --no-zagd \
    --analyze-strict --no-foreground-cache -o "$tmp/bad" >"$tmp/bad.log" 2>&1; then
    printf 'generic pointer slice: FAIL: open-ended raw pointer slice compiled\n' >&2
    exit 1
fi
grep -q 'open-ended slice of a raw pointer needs an upper bound' "$tmp/bad.log"

printf 'generic pointer slice: PASS (x86-64, ARM64, mutation, nested slice, negative)\n'
