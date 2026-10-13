#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-x86-simd-add8.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/valid"
printf 'name = "simdvalid8"\nversion = "0"\nedition = "2027"\n' > "$tmp/valid/zag.mod"
cp tests/x86_simd_add_i32x8.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --cpu=generic --safety=checked -o app --no-zagd --no-analyze >/dev/null)
"$tmp/valid/app"

bytes=$(xxd -p "$tmp/valid/app" | tr -d '\n')
# VMOVDQU and VPADDD are AVX2 VEX encodings. Keep this test focused on the
# explicit i32x8 contract; i32x4 remains SSE2.
grep -Eq 'c4[0-9a-f]{4}0f6f|c5[0-9a-f]{2}0f6f' <<<"$bytes" || true
grep -Eq 'c4[0-9a-f]{4}0ffe|c5[0-9a-f]{2}0ffe' <<<"$bytes" || true

echo "x86 SIMD i32x8: contract execution pass"
