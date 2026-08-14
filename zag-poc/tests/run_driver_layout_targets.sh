#!/usr/bin/env bash
# Prove the same layout contract against each initial native target. The source
# uses exact C leaves admitted by the typed front end; i686 deliberately uses
# 32-bit-or-wider fields until its aggregate lowering grows subword slots.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-driver-layout-targets.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "driver-layout-targets"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"

for target in x86_64 arm64 i686; do
  case "$target" in
    x86_64|arm64)
      cp tests/fixtures/driver_layout_x86_arm.zag "$tmp/project/main.zag"
      ;;
    i686)
      cp tests/fixtures/driver_layout_i686.zag "$tmp/project/main.zag"
      ;;
  esac
  out="$tmp/$target.out"
  args=(main.zag -o "$out" --no-zagd --no-analyze --no-foreground-cache)
  if [ "$target" != x86_64 ]; then args+=(--target "$target"); fi
  if ! (cd "$tmp/project" && "$ZNC" "${args[@]}" >"$tmp/$target.build.log" 2>&1); then
    echo "  XX  target-aware C layout did not compile for $target"
    sed -n '1,140p' "$tmp/$target.build.log"
    exit 1
  fi
  case "$target" in
    x86_64) runner=() ;;
    arm64) runner=(qemu-aarch64-static) ;;
    i686) runner=(qemu-i386-static) ;;
  esac
  if ! "${runner[@]}" "$out"; then
    echo "  XX  target-aware C layout runtime failed for $target"
    exit 1
  fi
  echo "  ok  target-aware @repr(C)/@repr(packed) layout $target"
done

cp tests/fixtures/driver_layout_i686_bad.zag "$tmp/project/reject.zag"
if (cd "$tmp/project" && "$ZNC" reject.zag -o "$tmp/reject.out" --target i686 --no-zagd) >"$tmp/reject.log" 2>&1; then
  echo '  XX  i686 subword aggregate layout was accepted without lowering'
  exit 1
fi
if [ -e "$tmp/reject.out" ] || ! rg -q 'i686 @repr\(C\) fields require 32-bit-or-wider' "$tmp/reject.log"; then
  echo '  XX  i686 subword layout did not fail with its precise capability diagnostic'
  sed -n '1,100p' "$tmp/reject.log"
  exit 1
fi
echo '  ok  i686 subword C-layout mismatch rejected before lowering'
echo 'driver layout targets: PASS'
