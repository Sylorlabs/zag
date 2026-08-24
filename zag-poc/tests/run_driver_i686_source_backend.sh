#!/usr/bin/env bash
# Exercise the checked-in i686 lowering source through its isolated harness.
# This is source-level backend evidence, not a replacement for foreground
# compiler bootstrap authority or the six-row Kbuild/QEMU release gate.
set -eu
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
case "$compiler" in
  /*) ;;
  *) compiler="$PWD/${compiler#./}" ;;
esac
if [ ! -x "$compiler" ]; then
  echo 'driver i686 source backend: BLOCKED — ZNC must name an executable compiler'
  exit 1
fi
if ! command -v qemu-i386-static >/dev/null 2>&1; then
  echo 'driver i686 source backend: BLOCKED — qemu-i386-static is unavailable'
  exit 1
fi

tmp=$(mktemp -d /tmp/zag-driver-i686-source.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

if ! "$compiler" selfhost/native/i386_codegen_source_test.zag \
    -o "$tmp/harness" --no-zagd --no-analyze --no-foreground-cache \
    >"$tmp/harness.log" 2>&1; then
  echo 'driver i686 source backend: BLOCKED — isolated source harness did not compile'
  sed -n '1,100p' "$tmp/harness.log"
  exit 1
fi

if ! "$tmp/harness" tests/fixtures/driver_i686_source_backend.zag \
    "$tmp/driver-i686" >"$tmp/lower.log" 2>&1; then
  echo 'driver i686 source backend: BLOCKED — source lowering failed'
  sed -n '1,100p' "$tmp/lower.log"
  exit 1
fi
if ! readelf -h "$tmp/driver-i686" | rg -q 'Class:[[:space:]]+ELF32|Machine:[[:space:]]+Intel 80386'; then
  echo 'driver i686 source backend: BLOCKED — lowering did not emit an ELF32/i386 executable'
  readelf -h "$tmp/driver-i686" | sed -n '1,24p'
  exit 1
fi
if ! qemu-i386-static "$tmp/driver-i686"; then
  echo 'driver i686 source backend: BLOCKED — generated generic aggregate program failed under i386 QEMU'
  exit 1
fi

if ! "$tmp/harness" tests/fixtures/driver_userspace_adapter.zag \
    "$tmp/driver-i686-userspace" >"$tmp/userspace-lower.log" 2>&1; then
  echo 'driver i686 source backend: BLOCKED — full userspace adapter lowering failed'
  sed -n '1,100p' "$tmp/userspace-lower.log"
  exit 1
fi
if ! readelf -h "$tmp/driver-i686-userspace" | rg -q 'Class:[[:space:]]+ELF32|Machine:[[:space:]]+Intel 80386'; then
  echo 'driver i686 source backend: BLOCKED — userspace adapter lowering did not emit ELF32/i386'
  readelf -h "$tmp/driver-i686-userspace" | sed -n '1,24p'
  exit 1
fi
if ! qemu-i386-static "$tmp/driver-i686-userspace"; then
  echo 'driver i686 source backend: BLOCKED — full userspace adapter failed under i386 QEMU'
  exit 1
fi

echo 'driver i686 source backend: PASS — generic core and full userspace adapter execute as ELF32 under i386 QEMU'
