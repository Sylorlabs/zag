#!/usr/bin/env bash
# Runtime authority for the checked fixed-buffer registry.  Public v2 syntax
# intentionally exposes only construction/deinit today; this compiler-owned
# intrinsic harness proves the bounded runtime metadata is reusable across
# resets rather than becoming permanent historical exhaustion.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-fixed-buffer-runtime.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/std"
ln -s "$PWD/selfhost/std/allocator.zag" "$tmp/std/allocator.zag"
printf 'name = "fixedbufferruntime"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let system:SystemAllocator=system_allocator(); let backing:Allocation=try system.allocate(32,8); let region:i64=_zag_fixed_buffer_init(backing.ptr,backing.len,backing.alignment,backing.generation,backing.allocator_id); if(region==0){return 2;} let i:i64=0; while(i<1100){let block:i64=_zag_fixed_buffer_allocate(region,1,1);if(block==0){return 3;}_zag_fixed_buffer_reset(region);i=i+1;} _zag_fixed_buffer_deinit(region,backing.ptr,backing.len,backing.alignment,backing.generation,backing.allocator_id);try system.deallocate(backing);return 42;} fn main() i32{return work() catch 9;}' >"$tmp/main.zag"
if (cd "$tmp" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/log" 2>&1 && [ -x "$tmp/out" ]; then
  set +e
  "$tmp/out"
  rc=$?
  set -e
  if [ "$rc" -eq 42 ]; then
    echo '  ok  fixed-buffer reset reclaims bounded block registry rows'
  else
    echo "  XX  fixed-buffer reset runtime result (exit=$rc)"; sed -n '1,20p' "$tmp/log"; exit 1
  fi
else
  echo '  XX  fixed-buffer runtime harness did not compile'; sed -n '1,20p' "$tmp/log"; exit 1
fi
mkdir -p "$tmp/stale/std"
ln -s "$PWD/selfhost/std/allocator.zag" "$tmp/stale/std/allocator.zag"
printf 'name = "fixedbufferstale"\nversion = "0"\nedition = "2027"\n' >"$tmp/stale/zag.mod"
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let system:SystemAllocator=system_allocator(); let backing:Allocation=try system.allocate(32,8); let region:i64=_zag_fixed_buffer_init(backing.ptr,backing.len,backing.alignment,backing.generation,backing.allocator_id); try system.deallocate(backing); let block:i64=_zag_fixed_buffer_allocate(region,1,1); return block as i32; } fn main() i32{return work() catch 9;}' >"$tmp/stale/main.zag"
if (cd "$tmp/stale" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/stale/log" 2>&1 && [ -x "$tmp/stale/out" ]; then
  set +e
  "$tmp/stale/out" >"$tmp/stale/out.log" 2>"$tmp/stale/err.log"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'invalid or released Allocation handle' "$tmp/stale/err.log"; then
    echo '  ok  fixed-buffer allocation revalidates released backing at runtime'
    exit 0
  fi
  echo "  XX  stale fixed-buffer backing runtime result (exit=$rc)"; sed -n '1,12p' "$tmp/stale/log"; sed -n '1,12p' "$tmp/stale/err.log"; exit 1
fi
echo '  XX  stale fixed-buffer backing harness did not compile'; sed -n '1,20p' "$tmp/stale/log"; exit 1
