#!/usr/bin/env bash
set -u
cd "$(dirname "$0")/.."

ZNC_BIN="${ZNC:-./znc}"
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

echo "════ dynamic ABI pass=$pass fail=$fail ════"
[ "$fail" = 0 ]
