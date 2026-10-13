#!/usr/bin/env bash
# Host-neutral HTTP/1.1, WebSocket, and DNS wire-codec release evidence.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac

if [ ! -x "$compiler" ]; then
    echo "protocol codecs: native compiler is not executable: $compiler" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-protocol-codecs.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

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
        --no-zagd --no-analyze --no-foreground-cache
record 'public WebSocket codec type-checks' \
    zag_run_bounded 180 "$compiler" check "$root/std/websocket.zag" \
        --no-zagd --no-analyze --no-foreground-cache
record 'public DNS codec type-checks' \
    zag_run_bounded 180 "$compiler" check "$root/std/dns_ipv4.zag" \
        --no-zagd --no-analyze --no-foreground-cache

run_wire_probe() {
    local source=$1 artifact=$2 label=$3
    if zag_run_bounded 240 "$compiler" "$source" -o "$artifact" \
        --no-zagd --no-analyze --no-foreground-cache; then
        record "$label is a native executable" zag_assert_native_executable "$artifact"
        record "$label executes" zag_run_bounded 30 "$artifact"
    else
        echo "  XX  $label compiles"
        fail=$((fail + 1))
    fi
}

run_wire_probe "$root/tests/http1_wire.zag" "$tmp/http1-wire" \
    'HTTP/1.1 strict wire corpus'
run_wire_probe "$root/tests/websocket_wire.zag" "$tmp/websocket-wire" \
    'WebSocket handshake/frame corpus'
run_wire_probe "$root/tests/dns_ipv4_wire.zag" "$tmp/dns-ipv4-wire" \
    'bounded DNS A wire corpus'

# The same WebSocket graph once passed with a relative root but crashed with
# its absolute spelling: different allocation traffic exposed a stale large
# allocation tombstone inside a reused small arena. Both invocations must
# compile and execute; neither spelling is an acceptable workaround.
if (cd "$root" && zag_run_bounded 240 "$compiler" tests/websocket_wire.zag \
    -o "$tmp/websocket-relative" --no-zagd --no-analyze --no-foreground-cache); then
    record 'relative-root WebSocket corpus is a native executable' \
        zag_assert_native_executable "$tmp/websocket-relative"
    record 'relative-root WebSocket corpus executes' \
        zag_run_bounded 30 "$tmp/websocket-relative"
    record 'absolute and relative WebSocket roots produce identical artifacts' \
        cmp -s "$tmp/websocket-wire" "$tmp/websocket-relative"
else
    echo '  XX  relative-root WebSocket corpus compiles'
    fail=$((fail + 1))
fi

echo "Protocol codecs: pass=$pass fail=$fail"
test "$fail" -eq 0
