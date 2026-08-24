#!/usr/bin/env bash
# Native bounded RFC 6455 loopback reference service.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-reference-websocket-service.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/websocket_service/main.zag"
pass=0
expected_pass=6

build_one() {
    local output=$1
    (
        cd "$tmp"
        timeout 300 "$compiler" "$source_file" -o "$output" \
            --no-zagd --no-analyze --no-foreground-cache
    ) >"$tmp/build.out" 2>"$tmp/build.err"
    test -x "$output"
}

static_elf() {
    local artifact=$1
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64' &&
        file "$artifact" | grep -q 'statically linked' &&
        readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC' &&
        ! readelf -l "$artifact" | grep -q 'INTERP' &&
        ! readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'
}

build_one "$tmp/websocket-service-a"
pass=$((pass + 1))
build_one "$tmp/websocket-service-b"
pass=$((pass + 1))
static_elf "$tmp/websocket-service-a"
static_elf "$tmp/websocket-service-b"
pass=$((pass + 1))
cmp -s "$tmp/websocket-service-a" "$tmp/websocket-service-b"
pass=$((pass + 1))
timeout 30 "$tmp/websocket-service-a" >"$tmp/app-a.out" 2>"$tmp/app-a.err"
printf 'websocket service: upgrade=101 text=ack:42 negatives=5\n' | \
    cmp -s - "$tmp/app-a.out"
test ! -s "$tmp/app-a.err"
pass=$((pass + 1))
timeout 30 "$tmp/websocket-service-b" >"$tmp/app-b.out" 2>"$tmp/app-b.err"
cmp -s "$tmp/app-a.out" "$tmp/app-b.out"
test ! -s "$tmp/app-b.err"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'WebSocket service reference app: pass=%d fail=0\n' "$pass"
