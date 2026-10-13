#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [ "$(uname -s)" != "Darwin" ] || [ "$(uname -m)" != "arm64" ]; then
    echo "XX macOS machine-control gate requires native Apple Silicon" >&2
    exit 2
fi

ZNC=${ZNC:-./znc-macos-arm64}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-machine-control.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

make_project() {
    local dir=$1 name=$2
    mkdir -p "$dir"
    printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$name" >"$dir/zag.mod"
}

make_project "$tmp/positive" macos-machine-control
cp tests/macos_machine_control.zag "$tmp/positive/main.zag"
(cd "$tmp/positive" && "$ZNC" main.zag --target macos-arm64 --cpu=native \
    --safety=checked --no-zagd --no-analyze -o app >/dev/null)
set +e
"$tmp/positive/app"
rc=$?
set -e
if [ "$rc" -ne 42 ]; then
    echo "XX macOS machine-control execution failed: $rc" >&2
    exit 1
fi

otool -tvV "$tmp/positive/app" >"$tmp/disassembly"
grep -Eq 'strb|sturb' "$tmp/disassembly"
grep -Eq 'ldrb|ldurb' "$tmp/disassembly"
grep -Eq 'strh|sturh' "$tmp/disassembly"
grep -Eq 'ldrh|ldurh' "$tmp/disassembly"
grep -Eq 'prfm[[:space:]]+pldl1keep' "$tmp/disassembly"
grep -Eq 'add\.4s' "$tmp/disassembly"
grep -Eq 'sub\.4s' "$tmp/disassembly"
grep -Eq 'and\.16b' "$tmp/disassembly"
grep -Eq 'orr\.16b' "$tmp/disassembly"
grep -Eq 'eor\.16b' "$tmp/disassembly"
echo "  ok  volatile 8/16/32/64, PRFM, and NEON i32x4 execute with native opcodes"

reject_compile() {
    local name=$1 source=$2 needle=$3
    make_project "$tmp/$name" "$name"
    printf '%s\n' "$source" >"$tmp/$name/main.zag"
    if (cd "$tmp/$name" && "$ZNC" main.zag --target macos-arm64 --safety=checked \
        --no-zagd --no-analyze -o out) >"$tmp/$name/log" 2>&1 || [ -e "$tmp/$name/out" ]; then
        echo "XX macOS machine-control negative accepted: $name" >&2
        sed -n '1,12p' "$tmp/$name/log" >&2
        exit 1
    fi
    grep -Eq "$needle" "$tmp/$name/log"
}

reject_compile volatile-wrong-width \
    'fn main()i32{let v:i32=0;unsafe{let p:*mut i32=(&v) as *mut i32;@volatileLoad16(p);}return 0;}' \
    'halfword access requires|wrong width'
reject_compile volatile-const-store \
    'fn main()i32{let v:u16=0;unsafe{let p:*const u16=(&v) as *const u16;@volatileStore16(p,7);}return 0;}' \
    'cannot write through \*const|mutability'
reject_compile volatile-wrong-value \
    'fn main()i32{let v:u16=0;let x:u32=7;unsafe{@volatileStore16((&v) as *mut u16,x);}return 0;}' \
    'halfword store value must be u16|wrong width'
reject_compile volatile-safe-scope \
    'fn main()i32{let v:u32=0;@volatileLoad32((&v) as *mut u32);return 0;}' \
    'volatile/MMIO access requires unsafe|unsafe'
reject_compile simd-safe-scope \
    'fn main()i32{let x:i32=1;@simdAddI32x4((&x) as *mut i32,(&x) as *const i32,(&x) as *const i32);return 0;}' \
    'packed SIMD requires unsafe|unsafe'
reject_compile simd-wrong-pointee \
    'fn main()i32{let x:i64=1;unsafe{@simdOrI32x4((&x) as *mut i64,(&x) as *const i64,(&x) as *const i64);}return 0;}' \
    'packed i32x4 SIMD.*i32|i32.*packed i32x4 SIMD'
reject_compile simd-const-dst \
    'fn main()i32{let x:i32=1;unsafe{@simdXorI32x4((&x) as *const i32,(&x) as *const i32,(&x) as *const i32);}return 0;}' \
    'dst requires \*mut/\*host i32|packed i32x4 SIMD'
reject_compile simd-pure \
    'fn bad()i32 @pure{unsafe{let x:i32=1;@simdSubI32x4((&x) as *mut i32,(&x) as *const i32,(&x) as *const i32);}return 0;}fn main()i32{return 0;}' \
    'E0002|pure'
reject_compile prefetch-safe-scope \
    'fn main()i32{let x:i64=1;@prefetch((&x) as *const i64);return 0;}' \
    'prefetch requires unsafe|unsafe'
echo "  ok  machine-control type, mutability, width, unsafe, and effect boundaries reject"

make_project "$tmp/simd-oob" simd-oob
printf '%s\n' 'fn main()i32{unsafe{let p:*u8=_zag_malloc(8) as *u8;@simdAddI32x4(p as *mut i32,p as *const i32,p as *const i32);_zag_free(p);return 0;}}' >"$tmp/simd-oob/main.zag"
(cd "$tmp/simd-oob" && "$ZNC" main.zag --target macos-arm64 --safety=checked \
    --no-zagd --no-analyze -o app >/dev/null)
set +e
"$tmp/simd-oob/app" >"$tmp/simd-oob/runtime.log" 2>&1
oob_rc=$?
set -e
if [ "$oob_rc" -eq 0 ]; then
    echo "XX checked 16-byte SIMD access accepted an 8-byte allocation" >&2
    exit 1
fi
grep -Eq 'out of bounds|pointer access' "$tmp/simd-oob/runtime.log"
echo "  ok  checked SIMD probes the full 16-byte raw access"

echo "macos-machine-control pass=3 fail=0"
