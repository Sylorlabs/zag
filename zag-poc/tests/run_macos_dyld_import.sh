#!/usr/bin/env bash
# Native Mach-O dyld binding regression: no host linker or ELF shim is used.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "macOS dyld import: skipped (requires Apple Silicon macOS)"
    exit 0
fi

. ./tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
test -x "$compiler"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-dyld.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$compiler" tests/macos_dyld_getpid.zag --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/getpid"
file "$tmp/getpid" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$tmp/getpid"
otool -l "$tmp/getpid" | grep -q 'LC_DYLD_INFO_ONLY'
otool -l "$tmp/getpid" | grep -q '/usr/lib/libSystem.B.dylib'
set +e
"$tmp/getpid"
status=$?
set -e
test "$status" -eq 42

# Single-precision uses the same independent FP/GPR banks, but the Zag backend
# converts its internal f32-as-f64 representation at the C boundary.
mkdir "$tmp/f64-project"
printf 'name = "macos-dyld-float"\nversion = "0"\nedition = "2027"\n' >"$tmp/f64-project/zag.mod"
cat >"$tmp/f64-project/f32.zag" <<'ZAG'
extern fn cosf(x: f32) f32 @cabi;
extern fn powf(x: f32, y: f32) f32 @cabi;
extern fn ldexpf(x: f32, n: i32) f32 @cabi;
fn main() i32 {
    unsafe {
        let a: f32 = cosf(0.0);
        let b: f32 = powf(2.0, 3.0);
        let c: f32 = ldexpf(1.5, 2);
        if (a > 0.99 && b > 7.99 && c > 5.99) { return 42; }
    }
    return 1;
}
ZAG
"$compiler" "$tmp/f64-project/f32.zag" --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/f32"
file "$tmp/f32" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$tmp/f32"
set +e
"$tmp/f32"
status=$?
set -e
test "$status" -eq 42

# Apple Silicon uses independent general-purpose and floating-point argument
# banks. Exercise one/two f64 arguments, an f64 result, and a mixed d0/x0 call
# through libSystem without involving a host linker.
cat >"$tmp/f64-project/main.zag" <<'ZAG'
extern fn cos(x: f64) f64 @cabi;
extern fn pow(x: f64, y: f64) f64 @cabi;
extern fn ldexp(x: f64, n: i32) f64 @cabi;
fn main() i32 {
    unsafe {
        let a: f64 = cos(0.0);
        let b: f64 = pow(2.0, 3.0);
        let c: f64 = ldexp(1.5, 2);
        if (a > 0.99 && b > 7.99 && c > 5.99) { return 42; }
    }
    return 1;
}
ZAG
"$compiler" "$tmp/f64-project/main.zag" --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/f64"
file "$tmp/f64" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$tmp/f64"
otool -l "$tmp/f64" | grep -q '/usr/lib/libSystem.B.dylib'
set +e
"$tmp/f64"
status=$?
set -e
test "$status" -eq 42

# Match the bounded Linux callback surface: a direct, captureless Zag function
# crosses the C ABI as one raw code pointer. libc qsort then calls back into the
# signed Mach-O image using the ordinary scalar/pointer AAPCS64 convention.
cat >"$tmp/f64-project/callback.zag" <<'ZAG'
extern fn qsort(base: *i64, n: i64, size: i64, cmp: fn(*i64,*i64)i32) void @cabi @borrows_mut;
fn compare(a: *i64, b: *i64) i32 {
    unsafe {
        if (a.* < b.*) { return -1; }
        if (a.* > b.*) { return 1; }
    }
    return 0;
}
fn main() i32 {
    unsafe {
        let p: *i64 = _zag_malloc(24) as *i64;
        p[0] = 9; p[1] = 2; p[2] = 5;
        qsort(p, 3, 8, compare);
        let ok: i32 = ((p[0] == 2) && (p[1] == 5) && (p[2] == 9)) as i32;
        _zag_free(p);
        if (ok == 1) { return 42; }
    }
    return 1;
}
ZAG
"$compiler" "$tmp/f64-project/callback.zag" --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/callback"
codesign --verify --deep --strict "$tmp/callback"
set +e
"$tmp/callback"
status=$?
set -e
test "$status" -eq 42

# Aliases remain Zag fat-function values and must never be mistaken for a raw
# C callback pointer.
cat >"$tmp/f64-project/callback-alias.zag" <<'ZAG'
extern fn qsort(base: *i64, n: i64, size: i64, cmp: fn(*i64,*i64)i32) void @cabi @borrows_mut;
fn compare(a: *i64, b: *i64) i32 { return 0; }
fn main() i32 {
    unsafe {
        let p: *i64 = _zag_malloc(8) as *i64;
        let alias: fn(*i64,*i64)i32 = compare;
        qsort(p, 1, 8, alias);
        _zag_free(p);
    }
    return 0;
}
ZAG
if "$compiler" "$tmp/f64-project/callback-alias.zag" --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/callback-alias" \
    >"$tmp/callback-alias.log" 2>&1; then
    echo 'macOS dyld import: callback alias unexpectedly accepted' >&2
    exit 1
fi
test ! -e "$tmp/callback-alias"
grep -Eq 'direct captureless function with an exact (scalar/pointer|supported) signature' "$tmp/callback-alias.log"

cat >"$tmp/f64-project/callback-captured.zag" <<'ZAG'
extern fn qsort(base: *i64, n: i64, size: i64, cmp: fn(*i64,*i64)i32) void @cabi @borrows_mut;
fn main() i32 {
    unsafe {
        let p: *i64 = _zag_malloc(8) as *i64;
        let bias: i64 = 0;
        let captured: fn(*i64,*i64)i32 = fn[bias](a: *i64, b: *i64) i32 { return bias as i32; };
        qsort(p, 1, 8, captured);
        _zag_free(p);
    }
    return 0;
}
ZAG
if "$compiler" "$tmp/f64-project/callback-captured.zag" --target macos-arm64 --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/callback-captured" \
    >"$tmp/callback-captured.log" 2>&1; then
    echo 'macOS dyld import: capturing callback unexpectedly accepted' >&2
    exit 1
fi
test ! -e "$tmp/callback-captured"
grep -Eq 'direct captureless function with an exact (scalar/pointer|supported) signature|owned allocation `captured`' \
    "$tmp/callback-captured.log"
echo "macOS dyld import: pass (integer, fixed f32/f64 mixed-register, and direct-callback libSystem ABI)"
