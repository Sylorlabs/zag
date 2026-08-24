#!/usr/bin/env bash
# Fail-closed Linux kernel/QEMU execution matrix.
#
# A row is executable only when the exact kernel and initramfs for that row are
# supplied row-specific object. The initramfs must load/unload the supplied
# pure-Zag module and
# write ZAG_DRIVER_QEMU_PASS after its conformance corpus and clean-log
# assertions complete. No missing row is silently downgraded to emulator
# evidence.
set -eu
cd "$(dirname "$0")/.."
missing=0

qemu_for_target() {
  local target=$1 explicit bin_dir candidate
  case "$target" in
    x86_64) explicit=${ZAG_DRIVER_QEMU_X86_64-}; candidate=qemu-system-x86_64 ;;
    arm64) explicit=${ZAG_DRIVER_QEMU_ARM64-}; candidate=qemu-system-aarch64 ;;
    i686) explicit=${ZAG_DRIVER_QEMU_I686-}; candidate=qemu-system-i386 ;;
    *) return 1 ;;
  esac
  if [ -n "$explicit" ]; then
    printf '%s\n' "$explicit"
    return 0
  fi
  bin_dir=${ZAG_DRIVER_QEMU_BIN_DIR-}
  if [ -n "$bin_dir" ] && [ -x "$bin_dir/$candidate" ]; then
    printf '%s\n' "$bin_dir/$candidate"
    return 0
  fi
  command -v "$candidate" 2>/dev/null || true
}

for series in 6_1 6_6; do
  for target in x86_64 arm64 i686; do
    qemu=$(qemu_for_target "$target")
    kernel_var="ZAG_DRIVER_LINUX_${series}_${target}_KERNEL"
    initrd_var="ZAG_DRIVER_LINUX_${series}_${target}_INITRD"
    module_var="ZAG_DRIVER_MODULE_${series}_${target}"
    repeat_var="ZAG_DRIVER_MODULE_REPEAT_${series}_${target}"
    kbuild_var="ZAG_DRIVER_KBUILD_${series}_${target}"
    kernel=${!kernel_var-}
    initrd=${!initrd_var-}
    module=${!module_var-}
    repeat=${!repeat_var-}
    kbuild=${!kbuild_var-}
    if [ -z "$qemu" ] || [ ! -x "$qemu" ]; then
      echo "  missing $series/$target: QEMU executable for $target"
      missing=1
    elif [ -z "$kernel" ] || [ ! -f "$kernel" ]; then
      echo "  missing $series/$target: $kernel_var"
      missing=1
    elif [ -z "$initrd" ] || [ ! -f "$initrd" ]; then
      echo "  missing $series/$target: $initrd_var"
      missing=1
    elif [ -z "$module" ] || [ ! -f "$module" ]; then
      echo "  missing $series/$target: $module_var"
      missing=1
    elif [ -z "$repeat" ] || [ ! -f "$repeat" ]; then
      echo "  missing $series/$target: $repeat_var"
      missing=1
    elif [ -z "$kbuild" ] || [ ! -f "$kbuild" ]; then
      echo "  missing $series/$target: $kbuild_var"
      missing=1
    else
      if ! ZAG_DRIVER_MODULE="$module" ZAG_DRIVER_MODULE_TARGET="$target" \
          ZAG_DRIVER_MODULE_KERNEL_SERIES="$series" \
          bash tests/check_driver_kernel_object.sh ||
          ! cmp -s "$module" "$repeat" ||
          ! ZAG_DRIVER_KBUILD="$kbuild" bash tests/check_driver_kbuild_contract.sh; then
        echo "  invalid $series/$target: deterministic kernel object/Kbuild evidence"
        missing=1
      else
        echo "  ready  $series/$target"
      fi
    fi
  done
done

if [ "$missing" -ne 0 ]; then
  echo 'driver QEMU matrix: BLOCKED — all six exact Linux-series/architecture rows are required'
  exit 1
fi

tmp=$(mktemp -d /tmp/zag-driver-qemu.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
log_dir=${ZAG_DRIVER_QEMU_LOG_DIR-}
if [ -n "$log_dir" ]; then
  mkdir -p "$log_dir"
fi
for series in 6_1 6_6; do
  for target in x86_64 arm64 i686; do
    case "$target" in
      x86_64) machine_args=(-machine q35 -cpu max) ;;
      arm64) machine_args=(-machine virt -cpu max) ;;
      i686) machine_args=(-machine pc -cpu max) ;;
    esac
    case "$target" in
      arm64) console_device=ttyAMA0 ;;
      *) console_device=ttyS0 ;;
    esac
    qemu=$(qemu_for_target "$target")
    kernel_var="ZAG_DRIVER_LINUX_${series}_${target}_KERNEL"
    initrd_var="ZAG_DRIVER_LINUX_${series}_${target}_INITRD"
    kernel=${!kernel_var}
    initrd=${!initrd_var}
    log="$tmp/$series-$target.log"
    if ! timeout "${ZAG_DRIVER_QEMU_TIMEOUT:-180}" "$qemu" "${machine_args[@]}" \
        -nographic -no-reboot -kernel "$kernel" -initrd "$initrd" \
        -append "console=$console_device panic=-1" >"$log" 2>&1; then
      if [ -n "$log_dir" ]; then cp "$log" "$log_dir/${series}_${target}.qemu.log"; fi
      echo "  XX  QEMU execution failed for $series/$target"
      sed -n '1,120p' "$log"
      exit 1
    fi
    if [ -n "$log_dir" ]; then
      cp "$log" "$log_dir/${series}_${target}.qemu.log"
      printf '%s\n' "$qemu ${machine_args[*]} -nographic -no-reboot -kernel $kernel -initrd $initrd -append console=$console_device\ panic=-1" \
        >"$log_dir/${series}_${target}.qemu.command"
    fi
    if ! rg -q 'ZAG_DRIVER_QEMU_PASS' "$log"; then
      echo "  XX  QEMU run for $series/$target did not prove clean module lifecycle"
      sed -n '1,120p' "$log"
      exit 1
    fi
    if rg -q 'Oops:|BUG:|Call Trace:|Kernel panic|kernel panic|WARNING:|Unknown symbol|invalid module format|ZAG_DRIVER_QEMU_FAIL' "$log"; then
      echo "  XX  QEMU run for $series/$target reported a kernel fault or module failure"
      sed -n '1,160p' "$log"
      exit 1
    fi
    echo "  ok  Linux $series $target QEMU module lifecycle"
  done
done
echo 'driver QEMU matrix: PASS'
