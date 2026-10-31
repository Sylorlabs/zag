#!/usr/bin/env bash
# Compile and execute the same emulator-backed Linux userspace adapter for
# x86-64, ARM64, and i686. Physical device acquisition is tested as blocked.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
tmp=$(mktemp -d /tmp/zag-driver-userspace.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "driver-userspace"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"
cp tests/fixtures/driver_userspace_adapter.zag "$tmp/project/main.zag"

for target in x86_64 arm64 i686; do
  out="$tmp/$target.out"
  case "$target" in
    x86_64) args=(main.zag -o "$out" --safety=checked --no-zagd) ;;
    arm64) args=(main.zag -o "$out" --target arm64 --safety=checked --no-zagd) ;;
    i686) args=(main.zag -o "$out" --target i686 --no-zagd) ;;
  esac
  if ! (cd "$tmp/project" && "$ZNC" "${args[@]}") >"$tmp/$target.build.log" 2>&1; then
    echo "driver userspace: BLOCKED — $target adapter lowering failed"
    sed -n '1,120p' "$tmp/$target.build.log"
    exit 1
  fi
  case "$target" in
    x86_64) runner=() ;;
    arm64) runner=(qemu-aarch64-static) ;;
    i686) runner=(qemu-i386-static) ;;
  esac
  if ! "${runner[@]}" "$out"; then
    echo "driver userspace: BLOCKED — $target emulator-backed adapter execution failed"
    exit 1
  fi
  echo "  ok  Linux userspace emulator adapter $target"
done
echo 'driver userspace: PASS — emulator-backed adapter is target-lowered and physical path remains fail-closed'
