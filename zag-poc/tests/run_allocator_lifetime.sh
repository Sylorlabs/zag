#!/usr/bin/env bash
# Native allocator lifetime integrity: this is runtime coverage for values that
# evade the edition-2027 local ownership proof (for example a v1 ABI boundary).
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-allocator-lifetime.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; _zag_free(p); let q:*i8 = _zag_malloc(32) as *i8; _zag_free(q); return 0; }' >"$tmp/reuse.zag"
if "$ZNC" "$tmp/reuse.zag" -o "$tmp/reuse" --no-zagd --no-analyze --no-foreground-cache >"$tmp/reuse.log" 2>&1 && "$tmp/reuse"; then
  echo "  ok  allocator restores a live header on free-list reuse"; pass=$((pass + 1))
else
  echo "  XX  allocator reuse after free"; sed -n '1,8p' "$tmp/reuse.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; _zag_free(p); _zag_free(p); return 0; }' >"$tmp/double_free.zag"
if "$ZNC" "$tmp/double_free.zag" -o "$tmp/double_free" --no-zagd --no-analyze --no-foreground-cache >"$tmp/double_free.log" 2>&1; then
  set +e
  "$tmp/double_free" >"$tmp/double_free.out" 2>"$tmp/double_free.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag runtime: invalid or double free' "$tmp/double_free.err"; then
    echo "  ok  dynamic double free fails closed"; pass=$((pass + 1))
  else
    echo "  XX  dynamic double free did not fail closed (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  dynamic double free program did not compile"; sed -n '1,8p' "$tmp/double_free.log"; fail=$((fail + 1))
fi

printf '%s\n' 'fn main() i32 { let p:*i8 = _zag_malloc(32) as *i8; _zag_free(p); let q:*i8 = _zag_realloc(p, 64) as *i8; return 0; }' >"$tmp/stale_realloc.zag"
if "$ZNC" "$tmp/stale_realloc.zag" -o "$tmp/stale_realloc" --no-zagd --no-analyze --no-foreground-cache >"$tmp/stale_realloc.log" 2>&1; then
  set +e
  "$tmp/stale_realloc" >"$tmp/stale_realloc.out" 2>"$tmp/stale_realloc.err"
  rc=$?
  set -e
  if [ "$rc" -ne 0 ] && grep -q 'zag runtime: realloc of invalid or freed allocation' "$tmp/stale_realloc.err"; then
    echo "  ok  stale realloc fails closed"; pass=$((pass + 1))
  else
    echo "  XX  stale realloc did not fail closed (exit=$rc)"; fail=$((fail + 1))
  fi
else
  echo "  XX  stale realloc program did not compile"; sed -n '1,8p' "$tmp/stale_realloc.log"; fail=$((fail + 1))
fi

echo "════ allocator-lifetime pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
