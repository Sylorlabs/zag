#!/usr/bin/env bash
# Runtime authority for the checked fixed-buffer registry. The public opaque
# surface proves bounded metadata is reusable across resets; raw tuple hooks
# are intentionally no longer source-callable.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-fixed-buffer-runtime.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/std"
ln -s "$PWD/selfhost/std/allocator.zag" "$tmp/std/allocator.zag"
printf 'name = "fixedbufferruntime"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let system:SystemAllocator=system_allocator(); let backing:Allocation=try system.allocate(32,8); let region:FixedBufferAllocator=try fixed_buffer_allocator(backing); let i:i64=0; while(i<1100){let block:FixedBufferBlock=try region.allocate(1,1);try fixed_buffer_write_u8(block,0,7);try region.reset();i=i+1;} let released:Allocation=try region.deinit();try system.deallocate(released);return 42;} fn main() i32{return work() catch 9;}' >"$tmp/main.zag"
if (cd "$tmp" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/log" 2>&1 && [ -x "$tmp/out" ]; then
  set +e
  "$tmp/out"
  rc=$?
  set -e
  if [ "$rc" -eq 42 ]; then
    echo '  ok  opaque fixed-buffer reset reclaims bounded block registry rows'
  else
    echo "  XX  fixed-buffer reset runtime result (exit=$rc)"; sed -n '1,20p' "$tmp/log"; exit 1
  fi
else
  echo '  XX  fixed-buffer runtime harness did not compile'; sed -n '1,20p' "$tmp/log"; exit 1
fi
