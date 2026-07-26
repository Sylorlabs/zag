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

echo "════ dynamic ABI pass=$pass fail=$fail ════"
[ "$fail" = 0 ]
