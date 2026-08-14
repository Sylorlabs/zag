#!/usr/bin/env bash
# Exercise the checked-in AArch64 lowering source through its isolated harness.
# This is source-level backend evidence, not foreground compiler authority or
# a claim that the Linux kernel adapter is available.
set -eu
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
case "$compiler" in
  /*) ;;
  *) compiler="$PWD/${compiler#./}" ;;
esac
if [ ! -x "$compiler" ]; then
  echo 'driver arm64 source backend: BLOCKED — ZNC must name an executable compiler'
  exit 1
fi
if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
  echo 'driver arm64 source backend: BLOCKED — qemu-aarch64-static is unavailable'
  exit 1
fi

tmp=$(mktemp -d /tmp/zag-driver-arm64-source.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

if ! "$compiler" selfhost/native/acodegen_source_test.zag \
    -o "$tmp/harness" --no-zagd --no-analyze --no-foreground-cache \
    >"$tmp/harness.log" 2>&1; then
  echo 'driver arm64 source backend: BLOCKED — isolated source harness did not compile'
  sed -n '1,100p' "$tmp/harness.log"
  exit 1
fi

if ! "$tmp/harness" tests/fixtures/driver_arm64_source_backend.zag \
    "$tmp/driver-arm64" >"$tmp/lower.log" 2>&1; then
  echo 'driver arm64 source backend: BLOCKED — source lowering failed'
  sed -n '1,100p' "$tmp/lower.log"
  exit 1
fi
if ! readelf -h "$tmp/driver-arm64" | rg -q 'Machine:[[:space:]]+AArch64'; then
  echo 'driver arm64 source backend: BLOCKED — lowering did not emit an AArch64 executable'
  readelf -h "$tmp/driver-arm64" | sed -n '1,24p'
  exit 1
fi
if ! qemu-aarch64-static "$tmp/driver-arm64"; then
  echo 'driver arm64 source backend: BLOCKED — generated layout/generic program failed under ARM64 QEMU'
  exit 1
fi

echo 'driver arm64 source backend: PASS — target-aware layout and generic aggregate execute under ARM64 QEMU'
