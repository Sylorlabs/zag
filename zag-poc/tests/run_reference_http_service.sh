#!/usr/bin/env bash
# Native bounded HTTP/1.1 loopback reference service.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-reference-http-service.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/http_service/main.zag"

build_one() {
    local output=$1
    (
        cd "$tmp"
        timeout 240 "$compiler" "$source_file" -o "$output" \
            --no-zagd --no-analyze --no-foreground-cache
    ) >"$tmp/build.out" 2>"$tmp/build.err"
}

static_elf() {
    local artifact=$1
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64' &&
        file "$artifact" | grep -q 'statically linked' &&
        readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC' &&
        ! readelf -l "$artifact" | grep -q 'INTERP' &&
        ! readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'
}

build_one "$tmp/http-service-a"
build_one "$tmp/http-service-b"
test -x "$tmp/http-service-a"
static_elf "$tmp/http-service-a"
cmp -s "$tmp/http-service-a" "$tmp/http-service-b"
timeout 30 "$tmp/http-service-a" >"$tmp/app.out" 2>"$tmp/app.err"
printf 'http service: status=200 body=42 negatives=4\n' | cmp -s - "$tmp/app.out"
test ! -s "$tmp/app.err"

echo 'HTTP service reference app: pass=6 fail=0'
