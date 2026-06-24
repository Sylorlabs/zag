#!/usr/bin/env bash
# Standard-library regression tests: each program must build, link std/runtime.c,
# run, and produce the exact expected output.
cd "$(dirname "$0")/.."
ZAGC=./zig-out/bin/zagc
pass=0; fail=0

check() { # name  expected-output(space-joined)
    local name="$1"; shift
    local want="$*"
    $ZAGC build "tests/stdlib/$name.zag" --run >/tmp/zst 2>/dev/null
    local got
    got=$(grep -A100 -- '-- running' /tmp/zst | grep -vE 'running|exit|--' | tr '\n' ' ' | sed 's/ *$//')
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
