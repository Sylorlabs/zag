#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-x86-simd-add.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/valid"
printf 'name = "simdvalid"\nversion = "0"\nedition = "2027"\n' > "$tmp/valid/zag.mod"
cp tests/x86_simd_add_i32x4.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --cpu=generic --safety=checked -o app --no-zagd --no-analyze >/dev/null)
"$tmp/valid/app"

# MOVDQU loads/stores are F3 0F 6F/7F; PADDD is the baseline SSE2 66 0F FE
# form. Require all three so a scalar lowering cannot satisfy this contract.
bytes=$(xxd -p "$tmp/valid/app" | tr -d '\n')
grep -Eq 'f3(4[0-9])?0f6f' <<<"$bytes"
grep -q '660ffe' <<<"$bytes"
grep -Eq 'f3(4[0-9])?0f7f' <<<"$bytes"

mkdir -p "$tmp/outside-unsafe"
printf 'name = "simdunsafe"\nversion = "0"\nedition = "2027"\n' > "$tmp/outside-unsafe/zag.mod"
printf 'fn main() i32 { let x:i32=1; @simdAddI32x4((&x) as *mut i32, (&x) as *const i32, (&x) as *const i32); return 0; }\n' > "$tmp/outside-unsafe/main.zag"
if (cd "$tmp/outside-unsafe" && "$ZNC" main.zag -o out) >"$tmp/outside-unsafe/log" 2>&1 || [ -e "$tmp/outside-unsafe/out" ]; then
    echo "packed SIMD outside unsafe unexpectedly compiled" >&2
    exit 1
fi
grep -Eq 'packed SIMD requires unsafe|unsafe' "$tmp/outside-unsafe/log"

mkdir -p "$tmp/wrong-pointee"
printf 'name = "simdtype"\nversion = "0"\nedition = "2027"\n' > "$tmp/wrong-pointee/zag.mod"
printf 'fn main() i32 { let x:i64=1; unsafe { @simdAddI32x4((&x) as *mut i64, (&x) as *const i64, (&x) as *const i64); } return 0; }\n' > "$tmp/wrong-pointee/main.zag"
if (cd "$tmp/wrong-pointee" && "$ZNC" main.zag -o out) >"$tmp/wrong-pointee/log" 2>&1 || [ -e "$tmp/wrong-pointee/out" ]; then
    echo "wrong packed SIMD pointer type unexpectedly compiled" >&2
    exit 1
fi
grep -Eq 'simdAddI32x4.*i32|i32.*simdAddI32x4' "$tmp/wrong-pointee/log"

mkdir -p "$tmp/pure"
printf 'name = "simdpure"\nversion = "0"\nedition = "2027"\n' > "$tmp/pure/zag.mod"
printf 'fn bad() i32 @pure { unsafe { let x:i32=1; @simdAddI32x4((&x) as *mut i32, (&x) as *const i32, (&x) as *const i32); } return 0; } fn main() i32 { return 0; }\n' > "$tmp/pure/main.zag"
if (cd "$tmp/pure" && "$ZNC" main.zag -o out) >"$tmp/pure/log" 2>&1 || [ -e "$tmp/pure/out" ]; then
    echo "packed SIMD unexpectedly satisfied a pure effect contract" >&2
    exit 1
fi
grep -q 'E0002' "$tmp/pure/log"

echo "x86 SIMD i32x4: checked execution, SSE2 opcode, and fail-closed boundary pass"
