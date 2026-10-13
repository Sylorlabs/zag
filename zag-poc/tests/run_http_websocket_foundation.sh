#!/usr/bin/env bash
# Focused HTTP/1.1 + RFC 6455 codec and native loopback gate.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

native_platform=$(zag_native_platform)
compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
target_args=()
case "$native_platform" in
    linux-arm64) target_args=(--target arm64) ;;
    macos-arm64) target_args=(--target macos-arm64) ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-http-websocket-foundation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

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

record 'public HTTP/1.1 codec type-checks' \
    zag_run_bounded 180 "$compiler" check "$root/std/http1.zag" \
        "${target_args[@]}" \
        --no-zagd --no-analyze --no-foreground-cache
record 'public HTTP stream adapter type-checks' \
    zag_run_bounded 180 "$compiler" check "$root/std/http1_service.zag" \
        "${target_args[@]}" \
        --no-zagd --no-analyze --no-foreground-cache
record 'public WebSocket codec type-checks' \
    zag_run_bounded 180 "$compiler" check "$root/std/websocket.zag" \
        "${target_args[@]}" \
        --no-zagd --no-analyze --no-foreground-cache

if zag_run_bounded 240 "$compiler" "$root/tests/http1_wire.zag" \
        "${target_args[@]}" -o "$tmp/http1-wire" --no-zagd --no-analyze \
        --no-foreground-cache >"$tmp/http-build.out" 2>"$tmp/http-build.err"; then
    record 'HTTP/1.1 strict wire corpus executes' \
        zag_run_bounded 30 "$tmp/http1-wire"
    record 'HTTP wire corpus is a native executable' \
        zag_assert_native_executable "$tmp/http1-wire"
else
    echo '  XX  HTTP/1.1 strict wire corpus compiles'
    fail=$((fail + 1))
fi

if zag_run_bounded 300 "$compiler" "$root/tests/websocket_wire.zag" \
        "${target_args[@]}" -o "$tmp/websocket-wire" --no-zagd --no-analyze \
        --no-foreground-cache >"$tmp/ws-build.out" 2>"$tmp/ws-build.err"; then
    record 'WebSocket handshake/frame corpus executes' \
        zag_run_bounded 30 "$tmp/websocket-wire"
    record 'WebSocket wire corpus is a native executable' \
        zag_assert_native_executable "$tmp/websocket-wire"
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
