#!/usr/bin/env bash
# Focused HTTP/1.1 + RFC 6455 codec and native loopback gate.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-http-websocket-foundation.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo 'HTTP/WebSocket foundation: unsupported host (requires Linux x86-64)' >&2
    exit 2
fi

pass=0
fail=0
record() {
    local label=$1
    shift
    if "$@"; then
        echo "  ok  $label"
        pass=$((pass + 1))
    else
        echo "  XX  $label"
        fail=$((fail + 1))
    fi
}

static_elf() {
    local artifact=$1
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64' &&
        file "$artifact" | grep -q 'statically linked' &&
        ! readelf -l "$artifact" 2>/dev/null | grep -q 'INTERP'
}

record 'public HTTP/1.1 codec type-checks' \
    timeout 180 "$compiler" check "$root/std/http1.zag" \
        --no-zagd --no-analyze --no-foreground-cache
record 'public HTTP stream adapter type-checks' \
    timeout 180 "$compiler" check "$root/std/http1_service.zag" \
        --no-zagd --no-analyze --no-foreground-cache
record 'public WebSocket codec type-checks' \
    timeout 180 "$compiler" check "$root/std/websocket.zag" \
        --no-zagd --no-analyze --no-foreground-cache

if timeout 240 "$compiler" "$root/tests/http1_wire.zag" \
        -o "$tmp/http1-wire" --no-zagd --no-analyze \
        --no-foreground-cache >"$tmp/http-build.out" 2>"$tmp/http-build.err"; then
    record 'HTTP/1.1 strict wire corpus executes' timeout 30 "$tmp/http1-wire"
    record 'HTTP wire corpus is static Linux x86-64' static_elf "$tmp/http1-wire"
else
    echo '  XX  HTTP/1.1 strict wire corpus compiles'
    fail=$((fail + 1))
fi

if timeout 300 "$compiler" "$root/tests/websocket_wire.zag" \
        -o "$tmp/websocket-wire" --no-zagd --no-analyze \
        --no-foreground-cache >"$tmp/ws-build.out" 2>"$tmp/ws-build.err"; then
    record 'WebSocket handshake/frame corpus executes' timeout 30 "$tmp/websocket-wire"
    record 'WebSocket wire corpus is static Linux x86-64' \
        static_elf "$tmp/websocket-wire"
else
    echo '  XX  WebSocket handshake/frame corpus compiles'
    fail=$((fail + 1))
fi

record 'native HTTP loopback reference service passes' \
    env ZNC="$compiler" bash "$root/tests/run_reference_http_service.sh"
record 'native WebSocket loopback reference service passes' \
    env ZNC="$compiler" bash "$root/tests/run_reference_websocket_service.sh"

echo "HTTP/WebSocket foundation: pass=$pass fail=$fail"
test "$fail" -eq 0
