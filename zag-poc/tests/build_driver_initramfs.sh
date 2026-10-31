#!/usr/bin/env bash
# Build a target-native, shell-only initramfs for the QEMU module lifecycle.
# BusyBox is supplied explicitly per architecture; there is no host-binary or
# physical-device fallback.
set -eu

busybox=${ZAG_DRIVER_INITRAMFS_BUSYBOX:-}
module=${ZAG_DRIVER_MODULE_KO:-}
output=${ZAG_DRIVER_INITRD_OUT:-}
if [ -z "$busybox" ] || [ ! -f "$busybox" ] || [ -z "$module" ] ||
   [ ! -f "$module" ] || [ -z "$output" ]; then
  echo 'driver initramfs: BLOCKED — native BusyBox, .ko, and output are required'
  exit 1
fi

tmp=$(mktemp -d /tmp/zag-driver-initramfs.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/dev" "$tmp/proc" "$tmp/sys" "$tmp/sbin"
cp "$busybox" "$tmp/bin/busybox"
ln -s /bin/busybox "$tmp/bin/sh"
ln -s /bin/busybox "$tmp/bin/insmod"
ln -s /bin/busybox "$tmp/bin/rmmod"
ln -s /bin/busybox "$tmp/bin/poweroff"
cp "$module" "$tmp/zag_driver.ko"
cp tests/fixtures/driver_init "$tmp/init"
chmod +x "$tmp/init"

mkdir -p "$(dirname "$output")"
(cd "$tmp" && find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9) >"$output"
if [ ! -s "$output" ]; then
  echo 'driver initramfs: BLOCKED — empty initramfs output'
  exit 1
fi
echo "driver initramfs: PASS — target-native lifecycle initramfs $output"
