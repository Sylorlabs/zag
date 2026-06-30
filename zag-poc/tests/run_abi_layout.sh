#!/usr/bin/env bash
# ABI / layout hardening regression suite for ./znc (native x86-64 ELF).
#
# Documents CURRENT behavior per COMPATIBILITY.md — NOT a stable-ABI claim.
# Catches regressions in @sizeOf, struct padding, union tag+payload, slice and
# fat_fn layout, arbitrary-width integers, and error-union sizing.
#
# Usage:  bash tests/run_abi_layout.sh
#         ZNC=./znc bash tests/run_abi_layout.sh

set -euo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in
    /*) ;;
    *) ZNC="$PWD/${ZNC#./}" ;;
esac

tmp=$(mktemp -d /tmp/zag-abi.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0

# abi <name> <source> <expected-exit>
abi() {
    local name=$1 src=$2 want=$3
    printf '%s' "$src" > "$tmp/src.zag"
    if ! "$ZNC" "$tmp/src.zag" -o "$tmp/bin" >"$tmp/out" 2>&1; then
        echo "  XX  $name (compile failed)"
        sed -n '1,6p' "$tmp/out"
        fail=$((fail + 1))
        return
    fi
    if [ ! -x "$tmp/bin" ]; then
        echo "  XX  $name (no binary)"
        fail=$((fail + 1))
        return
    fi
    set +e
    "$tmp/bin"
    local got=$?
    set -e
    if [ "$got" = "$want" ]; then
        echo "  ok  $name (@sizeOf/exit=$got)"
        pass=$((pass + 1))
    else
        echo "  XX  $name (got exit=$got, want $want)"
        fail=$((fail + 1))
    fi
}

echo "── ABI/layout regression (CURRENT znc behavior; ABI unstable) ──"
echo "   compiler: $ZNC"
echo ""
echo "── @sizeOf compile-time layout ──"

abi "scalar i32" \
    'fn main() i32 { return @sizeOf[i32](); }' \
    8

abi "i32 in struct (8-byte slot)" \
    'struct P { x: i32 } fn main() i32 { return @sizeOf[P](); }' \
    8

abi "nested structs" \
    'struct Inner { x: i32, y: i32 } struct Outer { inner: Inner, z: i32 } fn main() i32 { return @sizeOf[Outer](); }' \
    24

abi "struct + []u8 + i32 (32)" \
    'struct S { a: i32, b: []u8, c: i32 } fn main() i32 { return @sizeOf[S](); }' \
    32

abi "[]u8 fat slice (16)" \
    'fn main() i32 { return @sizeOf[[]u8](); }' \
    16

abi "fat_fn / fn type (16)" \
    'fn id(x: i32) i32 { return x; } fn main() i32 { return @sizeOf[fn(i32) i32](); }' \
    16

abi "f32 promotion struct (3×8)" \
    'struct V { x: f32, y: f32, z: f32 } fn main() i32 { return @sizeOf[V](); }' \
    24

abi "f32 pair struct (2×8)" \
    'struct F { x: f32, y: f32 } fn main() i32 { return @sizeOf[F](); }' \
    16

abi "arbitrary u11 (8-byte slot)" \
    'fn main() i32 { return @sizeOf[u11](); }' \
    8

abi "arbitrary i12 (8-byte slot)" \
    'fn main() i32 { return @sizeOf[i12](); }' \
    8

abi "error union !i32 (16)" \
    'error { E } fn main() i32 { return @sizeOf[!i32](); }' \
    16

abi "optional ?i32 (has+val)" \
    'fn main() i32 { return @sizeOf[?i32](); }' \
    16

abi "union tag+max payload (i32|[]u8 → 24)" \
    'union U { a: i32, b: []u8 } fn main() i32 { return @sizeOf[U](); }' \
    24

abi "union scalar variants (16)" \
    'union U { a: i32, b: i32 } fn main() i32 { return @sizeOf[U](); }' \
    16

abi "struct holding fat_fn field" \
    'fn id(x: i32) i32 { return x; } struct H { f: fn(i32) i32 } fn main() i32 { return @sizeOf[H](); }' \
    16

echo ""
echo "── runtime field offsets & aggregate behavior ──"

if ! "$ZNC" tests/abi/offsets.zag -o "$tmp/offsets" >"$tmp/out" 2>&1; then
    echo "  XX  offsets.zag (compile failed)"
    sed -n '1,8p' "$tmp/out"
    fail=$((fail + 1))
else
    set +e
    "$tmp/offsets"
    off_ec=$?
    set -e
    if [ "$off_ec" = 0 ]; then
        echo "  ok  offsets.zag (8 runtime checks)"
        pass=$((pass + 1))
    else
        echo "  XX  offsets.zag (failed check #$off_ec)"
        fail=$((fail + 1))
    fi
fi

total=$((pass + fail))
echo ""
echo "════ ABI/layout pass=$pass fail=$fail total=$total ════"
if [ "$fail" -ne 0 ]; then
    exit 1
fi