#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-x86-simd-sub.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/valid"
printf 'name = "simdsubvalid"\nversion = "0"\nedition = "2027"\n' > "$tmp/valid/zag.mod"
cp tests/x86/x86_simd_sub_i32x4.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --cpu=generic --safety=checked -o app --no-zagd --no-analyze >/dev/null)
"$tmp/valid/app"

# MOVDQU loads/stores are F3 0F 6F/7F; PSUBD is baseline SSE2 66 0F FA.
bytes=$(xxd -p "$tmp/valid/app" | tr -d '\n')
grep -Eq 'f3(4[0-9])?0f6f' <<<"$bytes"
grep -q '660ffa' <<<"$bytes"
grep -Eq 'f3(4[0-9])?0f7f' <<<"$bytes"

mkdir -p "$tmp/outside-unsafe"
printf 'name = "simdsubunsafe"\nversion = "0"\nedition = "2027"\n' > "$tmp/outside-unsafe/zag.mod"
printf 'fn main() i32 { let x:i32=1; @simdSubI32x4((&x) as *mut i32, (&x) as *const i32, (&x) as *const i32); return 0; }\n' > "$tmp/outside-unsafe/main.zag"
if (cd "$tmp/outside-unsafe" && "$ZNC" main.zag -o out) >"$tmp/outside-unsafe/log" 2>&1 || [ -e "$tmp/outside-unsafe/out" ]; then
    echo "packed SIMD subtraction outside unsafe unexpectedly compiled" >&2
    exit 1
fi
grep -Eq 'packed SIMD requires unsafe|unsafe' "$tmp/outside-unsafe/log"

mkdir -p "$tmp/wrong-pointee"
printf 'name = "simdsubtype"\nversion = "0"\nedition = "2027"\n' > "$tmp/wrong-pointee/zag.mod"
printf 'fn main() i32 { let x:i64=1; unsafe { @simdSubI32x4((&x) as *mut i64, (&x) as *const i64, (&x) as *const i64); } return 0; }\n' > "$tmp/wrong-pointee/main.zag"
if (cd "$tmp/wrong-pointee" && "$ZNC" main.zag -o out) >"$tmp/wrong-pointee/log" 2>&1 || [ -e "$tmp/wrong-pointee/out" ]; then
    echo "wrong packed SIMD subtraction pointer type unexpectedly compiled" >&2
    exit 1
fi
grep -Eq 'packed i32x4 SIMD.*i32|i32.*packed i32x4 SIMD' "$tmp/wrong-pointee/log"

mkdir -p "$tmp/pure"
printf 'name = "simdsubpure"\nversion = "0"\nedition = "2027"\n' > "$tmp/pure/zag.mod"
printf 'fn bad() i32 @pure { unsafe { let x:i32=1; @simdSubI32x4((&x) as *mut i32, (&x) as *const i32, (&x) as *const i32); } return 0; } fn main() i32 { return 0; }\n' > "$tmp/pure/main.zag"
if (cd "$tmp/pure" && "$ZNC" main.zag -o out) >"$tmp/pure/log" 2>&1 || [ -e "$tmp/pure/out" ]; then
    echo "packed SIMD subtraction unexpectedly satisfied a pure effect contract" >&2
    exit 1
fi
grep -q 'E0002' "$tmp/pure/log"

echo "x86 SIMD i32x4 subtraction: checked execution, SSE2 opcode, and fail-closed boundary pass"
