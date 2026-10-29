#!/usr/bin/env bash
# Native runtime: a large mapping re-issued at an address that already has a
# large-registry tombstone must not leave a stale duplicate tombstone that
# makes a later valid small-block free panic "invalid or double free".
set -u
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-large-tomb.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
for edition in 2026 2027; do
    d="$WORK/e$edition"; mkdir -p "$d"
    printf 'name = "large-tomb"\nversion = "0"\nedition = "%s"\n' "$edition" >"$d/zag.mod"
    cp tests/runtime_alloc/large_tombstone_dup.zag "$d/main.zag"
    if (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1; then
        out="$(cd "$d" && ./out 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ] && [ "$out" = "ok" ]; then ok "edition $edition duplicate large tombstone cleared"
        else bad "edition $edition rc=$rc out=$out"; fi
    else bad "edition $edition compile"; sed -n '1,8p' "$d/log"; fi
done
echo "runtime large tombstone: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
