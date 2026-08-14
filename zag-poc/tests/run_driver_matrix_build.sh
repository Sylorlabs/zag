#!/usr/bin/env bash
# Build all six exact kernel/Kbuild/module/initramfs rows and execute the
# QEMU gate in the same shell, preserving every row-specific input.
set -eu
cd "$(dirname "$0")/.."

kernel_root=${ZAG_DRIVER_KERNEL_ROOT:-}
artifact_root=${ZAG_DRIVER_ARTIFACT_ROOT:-}
if [ -z "$kernel_root" ] || [ ! -d "$kernel_root" ] || [ -z "$artifact_root" ]; then
  echo 'driver matrix build: BLOCKED — ZAG_DRIVER_KERNEL_ROOT and artifact root are required'
  exit 1
fi
mkdir -p "$artifact_root"

busybox_for_target() {
  case "$1" in
    x86_64) printf '%s\n' "${ZAG_DRIVER_INITRAMFS_BUSYBOX_X86_64-}" ;;
    arm64) printf '%s\n' "${ZAG_DRIVER_INITRAMFS_BUSYBOX_ARM64-}" ;;
    i686) printf '%s\n' "${ZAG_DRIVER_INITRAMFS_BUSYBOX_I686-}" ;;
    *) return 1 ;;
  esac
}

for series in 6_1 6_6; do
  case "$series" in
    6_1) kernel_series=6.1 ;;
    6_6) kernel_series=6.6 ;;
  esac
  for target in x86_64 arm64 i686; do
    build="$kernel_root/$kernel_series-$target"
    if [ "$target" = arm64 ]; then
      kernel="$build/arch/arm64/boot/Image"
    else
      kernel="$build/arch/x86/boot/bzImage"
    fi
    if [ ! -f "$kernel" ]; then
      echo "driver matrix build: BLOCKED — missing kernel image $kernel"
      exit 1
    fi
    row_prefix="$artifact_root/${series}_${target}"
    ZAG_DRIVER_KERNEL_BUILD="$build" \
      ZAG_DRIVER_TARGET="$target" \
      ZAG_DRIVER_KERNEL_SERIES="$series" \
      ZAG_DRIVER_ARTIFACT_DIR="$artifact_root" \
      bash tests/run_driver_kbuild.sh
    busybox=$(busybox_for_target "$target")
    ZAG_DRIVER_INITRAMFS_BUSYBOX="$busybox" \
      ZAG_DRIVER_MODULE_KO="$row_prefix.ko" \
      ZAG_DRIVER_INITRD_OUT="$row_prefix.initrd.gz" \
      bash tests/build_driver_initramfs.sh
    export "ZAG_DRIVER_LINUX_${series}_${target}_KERNEL=$kernel"
    export "ZAG_DRIVER_LINUX_${series}_${target}_INITRD=$row_prefix.initrd.gz"
    export "ZAG_DRIVER_MODULE_${series}_${target}=$row_prefix.o"
    export "ZAG_DRIVER_MODULE_REPEAT_${series}_${target}=$row_prefix.repeat.o"
    export "ZAG_DRIVER_KBUILD_${series}_${target}=$row_prefix.Kbuild"
  done
done

ZAG_DRIVER_QEMU_LOG_DIR="${ZAG_DRIVER_QEMU_LOG_DIR:-$artifact_root}" \
  bash tests/run_driver_qemu_matrix.sh
