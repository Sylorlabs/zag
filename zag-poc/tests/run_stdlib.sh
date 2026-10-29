#!/usr/bin/env bash
# Standard-library regression tests: each program must build with the native
# compiler (ZNC, default ./znc), run, and produce the exact expected output.
cd "$(dirname "$0")/.."
ZNC_BIN="${ZNC:-./znc}"
case "$ZNC_BIN" in /*) ;; *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;; esac
WORK="$(mktemp -d /tmp/zag-stdlib.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT
pass=0; fail=0

check() { # name  expected-output(space-joined)
    local name="$1"; shift
    local want="$*"
    local got=""
    if "$ZNC_BIN" "tests/stdlib/$name.zag" -o "$WORK/$name" --no-zagd --no-analyze >"$WORK/$name.log" 2>&1; then
        got=$(timeout 60 "$WORK/$name" 2>&1 | tr '\n' ' ' | sed 's/ *$//')
    fi
    want=$(echo "$want" | sed 's/ *$//')
    if [ "$got" = "$want" ]; then echo "  ok  $name"; pass=$((pass+1))
    else echo "  XX  $name"; echo "      want: [$want]"; echo "      got:  [$got]"; fail=$((fail+1)); fi
}

echo "── stdlib: ArrayList[T] ──"
check list 10 0 81 16 81 9 999
echo "── stdlib: StringMap[V] ──"
check map 6 1 22 6 0 100 0
echo "── stdlib: rt I/O (fmt, file roundtrip, strcmp) ──"
check io 12345 "hello world" 0 roundtrip-ok 12 1 0

echo "════ stdlib pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
