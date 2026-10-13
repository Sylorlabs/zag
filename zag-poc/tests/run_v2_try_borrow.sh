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
# Raw allocations participate in the resource provenance checker. Require its
# retained-view diagnostic from both entry points; an unrelated backend error
# must never count as proof that `try` preserved the backing owner's identity.
if (cd "$tmp" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/check.log" 2>&1; then
  echo 'not ok - check permits backing release through a try-wrapped borrow' >&2
  exit 1
fi
for result in "$tmp/log" "$tmp/check.log"; do
  if ! rg -Fq 'resource `backing` cannot be released while a container retains a borrowed view' "$result"; then
    sed -n '1,80p' "$result" >&2
    echo 'v2-try-borrow pass=0 fail=1' >&2
    exit 1
  fi
done
echo 'v2-try-borrow pass=2 fail=0'
