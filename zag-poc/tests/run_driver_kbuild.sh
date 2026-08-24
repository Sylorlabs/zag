#!/usr/bin/env bash
# Build one pure-Zag driver payload through the real kernel Kbuild pipeline.
# The input is a compiler-produced ET_REL; Kbuild owns the composite link,
# modpost, generated module metadata, and final .ko link.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
kernel_build=${ZAG_DRIVER_KERNEL_BUILD:-}
target=${ZAG_DRIVER_TARGET:-}
series=${ZAG_DRIVER_KERNEL_SERIES:-}
artifact_dir=${ZAG_DRIVER_ARTIFACT_DIR:-}
if [ ! -x "$ZNC" ] || [ ! -d "$kernel_build" ] || [ -z "$target" ] ||
   [ -z "$series" ] || [ -z "$artifact_dir" ]; then
  echo 'driver Kbuild: BLOCKED — compiler, kernel build, target, series, and artifact directory are required'
  exit 1
fi

case "$target" in
  x86_64) kbuild_arch=x86; kbuild_llvm=${ZAG_DRIVER_LLVM_X86_64:-} ;;
  arm64) kbuild_arch=arm64; kbuild_llvm=${ZAG_DRIVER_LLVM_ARM64:-${ZAG_DRIVER_LLVM:-}} ;;
  i686) kbuild_arch=x86; kbuild_llvm=${ZAG_DRIVER_LLVM_I686:-} ;;
  *) echo "driver Kbuild: BLOCKED — unsupported target $target"; exit 1 ;;
esac
case "$series" in
  6_1|6.1|61) compiler_series=6.1 ;;
  6_6|6.6|66) compiler_series=6.6 ;;
  *) echo "driver Kbuild: BLOCKED — unsupported Linux series $series"; exit 1 ;;
esac

mkdir -p "$artifact_dir"
tmp=$(mktemp -d /tmp/zag-driver-kbuild.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf 'name = "driver-kbuild"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
cp tests/fixtures/driver_module_kernel.zag "$tmp/main.zag"
cp tests/fixtures/driver.Kbuild "$tmp/Kbuild"

compile_payload() {
  local output=$1
  (cd "$tmp" && "$ZNC" main.zag --emit-driver-module \
      --driver-kernel "$compiler_series" --target "$target" -o "$output" \
      --no-zagd --no-analyze --no-foreground-cache)
}

compile_payload "$tmp/zag_payload.prebuilt.o"
compile_payload "$tmp/zag_payload.repeat.o"
if ! cmp -s "$tmp/zag_payload.prebuilt.o" "$tmp/zag_payload.repeat.o"; then
  echo "driver Kbuild: BLOCKED — nondeterministic $target/$compiler_series payload"
  exit 1
fi

kbuild_args=(
  -C "$kernel_build"
  M="$tmp"
  ARCH="$kbuild_arch"
  ZAG_DRIVER_PREBUILT="$tmp/zag_payload.prebuilt.o"
  KBUILD_MODPOST_WARN=0
)
if [ -n "$kbuild_llvm" ]; then
  kbuild_args+=(LLVM="$kbuild_llvm")
fi
make "${kbuild_args[@]}" modules >"$tmp/kbuild.log" 2>&1

ko="$tmp/zag_driver.ko"
if [ ! -f "$ko" ] || ! file "$ko" | rg -q 'relocatable|ELF'; then
  echo 'driver Kbuild: BLOCKED — Kbuild did not produce an ELF module'
  sed -n '1,160p' "$tmp/kbuild.log"
  exit 1
fi
if ! readelf -S "$ko" | rg -q '(__versions|\.modinfo|\.gnu\.linkonce\.this_module)'; then
  echo 'driver Kbuild: BLOCKED — final .ko lacks kernel-owned module metadata'
  exit 1
fi
if ! readelf -p .modinfo "$ko" | rg -q 'vermagic='; then
  echo 'driver Kbuild: BLOCKED — final .ko lacks kernel-generated vermagic'
  exit 1
fi

prefix="$artifact_dir/${series}_${target}"
cp "$tmp/zag_payload.prebuilt.o" "$prefix.o"
cp "$tmp/zag_payload.repeat.o" "$prefix.repeat.o"
cp "$ko" "$prefix.ko"
cp "$tmp/Kbuild" "$prefix.Kbuild"
cp "$tmp/kbuild.log" "$prefix.kbuild.log"

echo "driver Kbuild: PASS — $target Linux $compiler_series payload linked by kernel Kbuild"
