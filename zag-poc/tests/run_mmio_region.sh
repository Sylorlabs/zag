#!/usr/bin/env bash
# Bounded MMIO-region authority: unsafe code supplies the raw address once;
# exact-width helpers enforce region bounds before their volatile transaction.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-mmio-region.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

make_case() {
  mkdir -p "$tmp/$1"
  printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
  ln -s "$PWD/selfhost/std" "$tmp/$1/std"
}

make_case positive
printf '%s\n' '@import("std/mmio.zag") fn work() !i32 { let byte:u8=0; unsafe { let ptr:*mut u8=(&byte) as *mut u8; let region:MmioRegion=try mmio_region(ptr,1); try mmio_write8(region,0,42); let value:u8=try mmio_read8(region,0); return value as i32; } } fn main() i32 { return work() catch 9; }' >"$tmp/positive/main.zag"
if (cd "$tmp/positive" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/positive/log" 2>&1 && [ -x "$tmp/positive/out" ]; then
  set +e
  "$tmp/positive/out"
  rc=$?
  set -e
  if [ "$rc" -eq 42 ]; then
    echo '  ok  bounded MMIO region executes an exact byte transaction'
  else
    echo "  XX  bounded MMIO execution (exit=$rc)"; sed -n '1,16p' "$tmp/positive/log"; exit 1
  fi
else
  echo '  XX  bounded MMIO positive case did not compile'; sed -n '1,16p' "$tmp/positive/log"; exit 1
fi

make_case oob
printf '%s\n' '@import("std/mmio.zag") fn work() !i32 { let byte:u8=0; unsafe { let ptr:*mut u8=(&byte) as *mut u8; let region:MmioRegion=try mmio_region(ptr,1); let value:u8=try mmio_read8(region,1); return value as i32; } } fn main() i32 { return work() catch 42; }' >"$tmp/oob/main.zag"
if (cd "$tmp/oob" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/oob/log" 2>&1 && [ -x "$tmp/oob/out" ]; then
  set +e
  "$tmp/oob/out"
  rc=$?
  set -e
  if [ "$rc" -eq 42 ]; then
    echo '  ok  bounded MMIO region rejects out-of-range offset before access'
  else
    echo "  XX  bounded MMIO out-of-range result (exit=$rc)"; sed -n '1,16p' "$tmp/oob/log"; exit 1
  fi
else
  echo '  XX  bounded MMIO out-of-range case did not compile'; sed -n '1,16p' "$tmp/oob/log"; exit 1
fi
