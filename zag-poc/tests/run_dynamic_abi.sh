#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
WORK="$(mktemp -d /tmp/zag_dynamic_abi.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

if "$ZNC_BIN" tests/dynamic_vulkan_test.zag --dynamic --needed libvulkan.so.1 \
    --no-analyze -o "$WORK/vulkan" >"$WORK/build.log" 2>&1 &&
    readelf -l "$WORK/vulkan" | grep -q 'Requesting program interpreter' &&
    readelf -d "$WORK/vulkan" | grep -q 'libvulkan.so.1'; then
    "$WORK/vulkan"
    rc=$?
    if [ "$rc" = 42 ]; then ok "Vulkan loader call through Zag-emitted dynamic ELF"; else bad "Vulkan call exit=$rc"; fi
else
    bad "dynamic Vulkan build metadata"
    sed -n '1,16p' "$WORK/build.log"
fi

if "$ZNC_BIN" tests/dynamic_vulkan_test.zag --needed libvulkan.so.1 \
    --no-analyze -o "$WORK/no-mode" >"$WORK/no-mode.log" 2>&1; then
    bad "--needed accepted without --dynamic"
else
    grep -q 'requires explicit --dynamic' "$WORK/no-mode.log" && ok "--needed fails closed without --dynamic" || bad "missing --needed diagnostic"
fi

if "$ZNC_BIN" tests/dynamic_vulkan_test.zag --dynamic --needed '../libvulkan.so.1' \
    --no-analyze -o "$WORK/unsafe-name" >"$WORK/unsafe-name.log" 2>&1; then
    bad "unsafe SONAME accepted"
else
    grep -q 'safe shared-library SONAME' "$WORK/unsafe-name.log" && ok "unsafe SONAME rejected" || bad "missing unsafe SONAME diagnostic"
fi

cat >"$WORK/float.zag" <<'ZAG'
extern fn foreign_float(x: f64) f64 @io;
fn main() i32 { let x: f64 = foreign_float(1.0); if (x > 0.0) { return 1; } return 0; }
ZAG
if "$ZNC_BIN" "$WORK/float.zag" --dynamic --needed libm.so.6 \
    --no-analyze -o "$WORK/float" >"$WORK/float.log" 2>&1; then
    bad "unsupported float ABI accepted"
else
    grep -q 'supports only scalar integers' "$WORK/float.log" && ok "unsupported ABI class rejected" || bad "missing ABI rejection diagnostic"
fi

# Edition-2027 foreign calls require an explicit C-ABI contract and an unsafe
# call site.  Keep these checks separate from the legacy v1 dynamic loader
# fixture above so a broad extern regression cannot silently weaken v2.
mkdir -p "$WORK/v2-cabi"
printf 'name = "v2cabi"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn getpid() i64 @cabi; fn main() i32 { unsafe { let pid:i64=getpid(); if (pid > 0) { return 42; } } return 1; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o out) >"$WORK/v2-cabi/build.log" 2>&1 && [ -x "$WORK/v2-cabi/out" ]; then
    "$WORK/v2-cabi/out"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi dynamic integer import executes" || bad "v2 @cabi execution exit=$rc"
else
    bad "v2 @cabi dynamic import build"
    sed -n '1,16p' "$WORK/v2-cabi/build.log"
fi

# Exercise the implemented six-register scalar/pointer C-ABI path rather than
# inferring it from the zero-argument getpid witness. `mmap` returns a raw
# pointer and accepts mixed integer/pointer arguments; `munmap` proves the
# returned pointer can cross the same explicitly unsafe outbound boundary.
printf 'name = "v2cabimmap"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn mmap(addr:*u8, len:i64, prot:i32, flags:i32, fd:i32, offset:i64) *u8 @cabi; extern fn munmap(addr:*u8, len:i64) i32 @cabi; fn main() i32 { unsafe { let p:*u8=mmap(null as *u8,4096,3,34,-1,0); if (p == null as *u8) { return 1; } p[0]=42; if (p[0] != 42) { return 2; } if (munmap(p,4096) != 0) { return 3; } return 42; } }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o mmap) >"$WORK/v2-cabi/mmap.log" 2>&1 && [ -x "$WORK/v2-cabi/mmap" ]; then
    "$WORK/v2-cabi/mmap"
    rc=$?
    [ "$rc" = 42 ] && ok "v2 @cabi six-argument pointer import executes" || bad "v2 @cabi mmap execution exit=$rc"
else
    bad "v2 @cabi six-argument pointer import build"
    sed -n '1,16p' "$WORK/v2-cabi/mmap.log"
fi

printf 'name = "v2bareextern"\nversion = "0"\nedition = "2027"\n' >"$WORK/v2-cabi/zag.mod"
printf 'extern fn getpid() i64; fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --dynamic --needed libc.so.6 --no-zagd --no-analyze -o bare) >"$WORK/v2-cabi/bare.log" 2>&1; then
    bad "v2 bare extern accepted"
else
    grep -q 'v2 foreign imports require explicit @cabi' "$WORK/v2-cabi/bare.log" && ok "v2 bare extern rejects without @cabi" || bad "missing @cabi requirement diagnostic"
fi

printf 'extern fn getpid() i64 @cabi; fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o nodynamic) >"$WORK/v2-cabi/nodynamic.log" 2>&1; then
    bad "v2 @cabi accepted without dynamic mode"
else
    grep -q 'v2 @cabi imports require --dynamic' "$WORK/v2-cabi/nodynamic.log" && ok "v2 @cabi rejects without dynamic mode" || bad "missing dynamic-mode diagnostic"
fi

# `--emit-obj` has a real i686 ET_REL path, but it is not evidence for the
# native x86-64 v2 C ABI.  A v2 @cabi declaration must fail before that target
# can emit an apparently-C-compatible object.
printf 'extern fn getpid() i64 @cabi; fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --target i686 --emit-obj --no-zagd --no-analyze -o foreign.o) >"$WORK/v2-cabi/i686.log" 2>&1 || [ -e "$WORK/v2-cabi/foreign.o" ]; then
    bad "v2 @cabi emitted non-native object"
else
    grep -q 'supported only for native x86-64 --dynamic' "$WORK/v2-cabi/i686.log" && ok "v2 @cabi rejects non-native object target" || bad "missing non-native ABI diagnostic"
fi

# The normal x86-64 writer is ET_EXEC only.  Its object/archive flags must not
# silently produce an executable with no section or public-symbol table.
printf 'pub fn exported_answer() i64 { return 42; } fn main() i32 { return 0; }\n' >"$WORK/v2-cabi/main.zag"
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --emit-obj --no-zagd --no-analyze -o native.o) >"$WORK/v2-cabi/native-object.log" 2>&1 || [ -e "$WORK/v2-cabi/native.o" ]; then
    bad "native x86-64 emitted a misleading object artifact"
else
    grep -q 'native x86-64 --emit-obj/--emit-static is not implemented' "$WORK/v2-cabi/native-object.log" && ok "native x86-64 object request fails closed" || bad "missing native object diagnostic"
fi

# A shared-object request is also unsupported: it must not be ignored and
# silently fall through to the ET_EXEC writer.
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --emit-shared --no-zagd --no-analyze -o native.so) >"$WORK/v2-cabi/native-shared.log" 2>&1 || [ -e "$WORK/v2-cabi/native.so" ]; then
    bad "native x86-64 emitted a misleading shared-object artifact"
else
    grep -q 'v2 compiler option is not implemented: --emit-shared' "$WORK/v2-cabi/native-shared.log" && ok "native x86-64 shared-object request fails closed" || bad "missing native shared-object diagnostic"
fi

# Common shared/library spellings must be equally explicit.  None currently
# names an implemented object format, so accepting one as ET_EXEC would lie
# about its ABI just as --emit-shared did.
for shared_flag in --shared --emit-dylib --emit-lib --emit=shared; do
    shared_name=$(printf '%s' "$shared_flag" | tr -cd '[:alnum:]')
    if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag "$shared_flag" --no-zagd --no-analyze -o "$shared_name.out") >"$WORK/v2-cabi/$shared_name.log" 2>&1 || [ -e "$WORK/v2-cabi/$shared_name.out" ]; then
        bad "$shared_flag emitted a misleading output artifact"
    elif grep -q "v2 compiler option is not implemented: $shared_flag" "$WORK/v2-cabi/$shared_name.log"; then
        ok "$shared_flag fails closed"
    else
        bad "$shared_flag missing output-mode diagnostic"
    fi
done

# Symbol-export controls are equally unavailable without an x86-64 symbol
# table and public ABI. They must not make `pub fn` look externally callable.
for export_flag in --export --export-dynamic --export-symbol=exported_answer; do
    export_name=$(printf '%s' "$export_flag" | tr -cd '[:alnum:]')
    if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag "$export_flag" --no-zagd --no-analyze -o "$export_name.out") >"$WORK/v2-cabi/$export_name.log" 2>&1 || [ -e "$WORK/v2-cabi/$export_name.out" ]; then
        bad "$export_flag emitted a misleading export artifact"
    elif grep -q "v2 compiler option is not implemented: $export_flag" "$WORK/v2-cabi/$export_name.log"; then
        ok "$export_flag fails closed"
    else
        bad "$export_flag missing export diagnostic"
    fi
done
if (cd "$WORK/v2-cabi" && "$ZNC_BIN" main.zag --export-symbol exported_answer --no-zagd --no-analyze -o split-export.out) >"$WORK/v2-cabi/split-export.log" 2>&1 || [ -e "$WORK/v2-cabi/split-export.out" ]; then
    bad "split --export-symbol emitted a misleading export artifact"
elif grep -q 'v2 compiler option is not implemented: --export-symbol' "$WORK/v2-cabi/split-export.log"; then
    ok "split --export-symbol fails closed"
else
    bad "split --export-symbol missing export diagnostic"
fi

echo "════ dynamic ABI pass=$pass fail=$fail ════"
[ "$fail" = 0 ]
