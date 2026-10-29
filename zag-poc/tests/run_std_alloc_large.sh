#!/usr/bin/env bash
# std/list.zag (and the hashmap/map/database_memory tables) computed
# `count * @sizeOf[T]()` in i32, so any backing block over 2^31 bytes wrapped
# negative and aborted. Runs tests/std_alloc_large.zag in both editions.
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ZNC_BIN="${ZNC:-$ROOT/znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$ROOT/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-std-alloc.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0
for edition in 2026 2027; do
    d="$WORK/e$edition"; mkdir -p "$d"
    printf 'name = "std-alloc"\nversion = "0"\nedition = "%s"\n' "$edition" >"$d/zag.mod"
    cp "$ROOT/tests/std_alloc_large.zag" "$d/main.zag"
    if (cd "$d" && "$ZNC_BIN" main.zag --no-zagd --no-analyze -o out) >"$d/log" 2>&1; then
        (cd "$d" && timeout 60 ./out) >"$d/run" 2>&1; rc=$?
        if [ "$rc" -eq 42 ]; then echo "  ok  std large alloc edition $edition"; pass=$((pass+1));
        else echo "  XX  std large alloc edition $edition rc=$rc"; sed -n '1,5p' "$d/run"; fail=$((fail+1)); fi
    else
        echo "  XX  std large alloc edition $edition compile"; sed -n '1,12p' "$d/log"; fail=$((fail+1))
    fi
done
echo "std large alloc: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
