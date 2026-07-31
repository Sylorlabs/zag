#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
tmp=$(mktemp -d /tmp/zag-v2-try-borrow.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf 'name = "tryborrow"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"
printf 'fn borrow(p:*u8) !*u8 @borrows_mut { return p; } fn main() i32 { unsafe { let backing:*u8=_zag_malloc(8); let held:*u8=try borrow(backing); _zag_free(backing); return 0; } }\n' >"$tmp/main.zag"
if (cd "$tmp" && "$ZNC" main.zag -o out --no-zagd --no-analyze) >"$tmp/log" 2>&1 || [ -e "$tmp/out" ]; then
  echo 'not ok - try-wrapped mutable borrow permits backing release' >&2
  exit 1
fi
if rg -q 'exclusive mutable borrow' "$tmp/log" && rg -q 'cannot pass a borrow to a consuming call' "$tmp/log"; then
  echo 'v2-try-borrow pass=1 fail=0'
else
  sed -n '1,80p' "$tmp/log" >&2
  echo 'v2-try-borrow pass=0 fail=1' >&2
  exit 1
fi
