#!/usr/bin/env bash
# ABI/layout hardening regression suite for the checkout-native compiler.
#
# RELEASE-BLOCKING GATE: failure aborts a release (see RELEASES.md step 5b).
# Documents CURRENT behavior per COMPATIBILITY.md — NOT a frozen/stable ABI.
# Catches regressions in @sizeOf, struct padding, union tag+payload, slice and
# fat_fn layout, pointer alignment, arbitrary-width integers, and error-union
# sizing.
#
# Usage:  bash tests/run_abi_layout.sh
#         ZNC=/path/to/znc bash tests/run_abi_layout.sh

set -euo pipefail
cd "$(dirname "$0")/.."
. ./tests/portable.sh

ZNC=${ZNC:-$(zag_native_compiler "$PWD")}
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

abi "pointer *i32 (8)" \
    'fn main() i32 { return @sizeOf[*i32](); }' \
    8

abi "pointer *u8 (8)" \
    'fn main() i32 { return @sizeOf[*u8](); }' \
    8

abi "union max payload (i32|3×i32 struct → 32)" \
    'struct Trip { x: i32, y: i32, z: i32 } union U { a: i32, b: Trip } fn main() i32 { return @sizeOf[U](); }' \
    32

abi "nested struct padding (i32 + 3×i32 + i32 → 40)" \
    'struct Mid { a: i32, b: i32, c: i32 } struct Wrap { x: i32, mid: Mid, y: i32 } fn main() i32 { return @sizeOf[Wrap](); }' \
    40

abi "optional between scalars (?i32 inline → 32)" \
    'struct Edge { head: i32, opt: ?i32, tail: i32 } fn main() i32 { return @sizeOf[Edge](); }' \
    32

echo ""
echo "── typed allocation primitives (word-ABI safe) ──"
# _zag_alloc_array[T](n)/_zag_alloc_struct[T]() make the COMPILER own the
# element stride, so `p[i]` stays in bounds for i<n by construction. The
# matching hard error rejects byte-guess `_zag_malloc`→*T bindings whose size
# is not provably a whole number of elements (see footgun cases below).

abi "@sizeof alias spelling" \
    'fn main() i32 { return @sizeof[i32](); }' \
    8

abi "@elemStride scalar (8)" \
    'fn main() i32 { return @elemStride[i32](); }' \
    8

abi "@elemStride byte (1)" \
    'fn main() i32 { return @elemStride[u8](); }' \
    1

abi "@elemStride slice (16)" \
    'fn main() i32 { return @elemStride[[]u8](); }' \
    16

# (exit codes are mod 256, so the checksum is kept ≤ 255)
abi "alloc_array i32 fill+sum" \
    'fn main() i32 { let p: *i32 = _zag_alloc_array[i32](8); let i: i32 = 0; while (i < 8) { p[i] = i * 7; i = i + 1; } let s: i32 = 0; i = 0; while (i < 8) { s = s + p[i]; i = i + 1; } _zag_free(p as *i8); return s; }' \
    196

abi "alloc_array []u8 elements" \
    'fn main() i32 { let p: *[]u8 = _zag_alloc_array[[]u8](4); p[0] = "ab"; p[3] = "cd"; _zag_free(p as *i8); return p[0].len + p[3].len; }' \
    4

abi "alloc_array u8 byte buffer" \
    'fn main() i32 { let p: *u8 = _zag_alloc_array[u8](13); p[12] = 65; _zag_free(p as *i8); return p[12]; }' \
    65

abi "alloc_struct field access" \
    'struct P { a: i32, b: i32 } fn main() i32 { let s: *P = _zag_alloc_struct[P](); s.*.a = 3; s.*.b = 4; let v: i32 = s.*.a + s.*.b; _zag_free(s as *i8); return v; }' \
    7

abi "malloc whole-elements still ok" \
    'fn main() i32 { let p = _zag_malloc(5 * 8) as *i32; p[0] = 9; let q: *i32 = _zag_malloc(4 * @sizeOf[i32]()); q[0] = 1; return p[0] + q[0]; }' \
    10

# abifail <name> <source> <stderr-fragment> — the source MUST fail to compile
# and the diagnostics MUST name the typed primitive as the fix.
abifail() {
    local name=$1 src=$2 frag=$3
    printf '%s' "$src" > "$tmp/src.zag"
    if "$ZNC" "$tmp/src.zag" -o "$tmp/bin" >"$tmp/out" 2>&1; then
        echo "  XX  $name (compiled, want hard error)"
        fail=$((fail + 1))
        return
    fi
    if grep -q "$frag" "$tmp/out"; then
        echo "  ok  $name (hard error names _zag_alloc_array)"
        pass=$((pass + 1))
    else
        echo "  XX  $name (error missing fix hint '$frag')"
        sed -n '1,6p' "$tmp/out"
        fail=$((fail + 1))
    fi
}

abifail "cast byte-guess n*4 -> *i32" \
    'fn main() i32 { let n: i32 = 8; let p = _zag_malloc(n * 4) as *i32; p[0] = 1; return 0; }' \
    "_zag_alloc_array"

abifail "let-bound byte-guess n*4 -> *i32" \
    'fn main() i32 { let n: i32 = 8; let p: *i32 = _zag_malloc(n * 4); return 0; }' \
    "_zag_alloc_array"

abifail "assign byte-guess -> *i32" \
    'fn main() i32 { let n: i32 = 8; let p: *i32 = 0 as *i32; p = _zag_malloc(n * 4 + 1); return 0; }' \
    "_zag_alloc_array"

abifail "literal under-alloc 24 -> *[]u8" \
    'fn main() i32 { let p = _zag_malloc(24) as *[]u8; return 0; }' \
    "_zag_alloc_array"

abifail "realloc byte-guess -> *i32" \
    'fn main() i32 { let n: i32 = 8; let p: *i32 = 0 as *i32; p = _zag_realloc(p as *i8, n * 4) as *i32; return 0; }' \
    "_zag_alloc_array"

abi "u8 buffer exempt (any byte count)" \
    'fn main() i32 { let p = _zag_malloc(7) as *u8; p[6] = 3; return p[6]; }' \
    3

# The committed footgun fixture: a byte-guess malloc bound to *i32 that would
# have silently corrupted the heap at base; now it must hard-error with the
# fix hint.
if "$ZNC" tests/footgun_demo.zag -o "$tmp/footgun" >"$tmp/out" 2>&1; then
    echo "  XX  footgun_demo.zag fixture (compiled, want hard error)"
    fail=$((fail + 1))
elif grep -q "_zag_alloc_array" "$tmp/out"; then
    echo "  ok  footgun_demo.zag fixture (hard error names _zag_alloc_array)"
    pass=$((pass + 1))
else
    echo "  XX  footgun_demo.zag fixture (error missing fix hint)"
    sed -n '1,6p' "$tmp/out"
    fail=$((fail + 1))
fi

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
        echo "  ok  offsets.zag (13 runtime checks)"
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
