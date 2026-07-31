#!/usr/bin/env bash
# Edition-2027 retained arena authority.  ArenaAllocator is a distinct source
# capability over the checked retained-region runtime: it must retain one live
# backing Allocation, invalidate old blocks on reset, and hand that same backing
# back through deinit.  This test deliberately exercises no hidden heap path.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-arena-allocator.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

make_case() {
  mkdir -p "$tmp/$1"
  printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$1" >"$tmp/$1/zag.mod"
  ln -s "$PWD/selfhost/std" "$tmp/$1/std"
}

make_case arena_positive
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let system:SystemAllocator=system_allocator(); let backing:Allocation=try system.allocate(64,8); let arena:ArenaAllocator=try arena_allocator(backing); let first:ArenaBlock=try arena.allocate(8,8); try arena_write_u8(first,0,7); try arena.reset(); let second:ArenaBlock=try arena.allocate(8,8); try arena_write_u8(second,0,42); let value:u8=try arena_read_u8(second,0); let released:Allocation=try arena.deinit(); try system.deallocate(released); return value as i32; } fn main() i32 { return work() catch 9; }' >"$tmp/arena_positive/main.zag"
if (cd "$tmp/arena_positive" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/arena_positive/log" 2>&1 && [ -x "$tmp/arena_positive/out" ]; then
  set +e
  "$tmp/arena_positive/out"
  rc=$?
  set -e
  if [ "$rc" -eq 42 ]; then
    echo '  ok  retained ArenaAllocator allocates, resets, and returns its exact backing'
  else
    echo "  XX  retained arena execution (exit=$rc)"; sed -n '1,18p' "$tmp/arena_positive/log"; exit 1
  fi
else
  echo '  XX  retained arena positive case did not compile'; sed -n '1,18p' "$tmp/arena_positive/log"; exit 1
fi

make_case arena_alias
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let system:SystemAllocator=system_allocator(); let backing:Allocation=try system.allocate(64,8); let arena:ArenaAllocator=try arena_allocator(backing); let block:ArenaBlock=try arena.allocate(8,8); let alias:ArenaBlock=block; let released:Allocation=try arena.deinit(); try system.deallocate(released); return 0; } fn main() i32 { return work() catch 9; }' >"$tmp/arena_alias/main.zag"
if (cd "$tmp/arena_alias" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/arena_alias/log" 2>&1 || [ -e "$tmp/arena_alias/out" ]; then
  echo '  XX  retained arena block alias compiled or left an artifact'; sed -n '1,18p' "$tmp/arena_alias/log"; exit 1
elif grep -q 'retained backing, allocator, and blocks cannot be copied' "$tmp/arena_alias/log"; then
  echo '  ok  retained ArenaBlock aliases reject without an artifact'
else
  echo '  XX  retained arena alias rejection lacked lifecycle diagnostic'; sed -n '1,18p' "$tmp/arena_alias/log"; exit 1
fi

make_case arena_stale
printf '%s\n' '@import("std/allocator.zag") fn work() !i32 { let system:SystemAllocator=system_allocator(); let backing:Allocation=try system.allocate(64,8); let arena:ArenaAllocator=try arena_allocator(backing); let first:ArenaBlock=try arena.allocate(8,8); try arena.reset(); let value:u8=try arena_read_u8(first,0); let released:Allocation=try arena.deinit(); try system.deallocate(released); return value as i32; } fn main() i32 { return work() catch 9; }' >"$tmp/arena_stale/main.zag"
if (cd "$tmp/arena_stale" && "$ZNC" main.zag -o out --safety=checked --no-zagd) >"$tmp/arena_stale/log" 2>&1 || [ -e "$tmp/arena_stale/out" ]; then
  echo '  XX  stale retained ArenaBlock compiled or left an artifact'; sed -n '1,18p' "$tmp/arena_stale/log"; exit 1
elif grep -q 'fixed-buffer reads require one live named FixedBufferBlock' "$tmp/arena_stale/log"; then
  echo '  ok  retained arena reset rejects stale blocks without an artifact'
else
  echo '  XX  stale retained arena block rejection lacked lifecycle diagnostic'; sed -n '1,18p' "$tmp/arena_stale/log"; exit 1
fi
