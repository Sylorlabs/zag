#!/usr/bin/env bash
# std/rt.zag declares _zag_malloc/_zag_realloc byte counts as i64, and > 2 GiB
# allocations through std:rt work in editions 2026 and 2027.
set -u
cd "$(dirname "$0")/.."
ROOT="$PWD"
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-rt-malloc.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }
for edition in 2026 2027; do
    d="$WORK/e$edition"; mkdir -p "$d"
    printf 'name = "rt-malloc"\nversion = "0"\nedition = "%s"\n' "$edition" >"$d/zag.mod"
    cp tests/std_rt/rt_alloc_large.zag "$d/main.zag"
    if (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1; then
        (cd "$d" && ./out); rc=$?
        if [ "$rc" -eq 12 ]; then ok "edition $edition >2GiB malloc/realloc via std:rt"; else bad "edition $edition rc=$rc want 12"; fi
    else bad "edition $edition compile"; sed -n '1,8p' "$d/log"; fi
done
d="$WORK/decl"; mkdir -p "$d"
printf 'name = "rt-decl"\nversion = "0"\nedition = "2026"\n' >"$d/zag.mod"
cp tests/std_rt/rt_decl_i64.zag "$d/main.zag"
if (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1; then
    (cd "$ROOT" && "$d/out"); rc=$?
    if [ "$rc" -eq 0 ]; then ok "std/rt.zag declares i64 allocator sizes"; else bad "std/rt.zag allocator declaration (rc=$rc)"; fi
else bad "decl checker compile"; sed -n '1,8p' "$d/log"; fi
echo "std rt malloc i64: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
