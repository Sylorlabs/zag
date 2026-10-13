#!/usr/bin/env bash
# Native bounded RFC 6455 loopback reference service.
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
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-websocket-service.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/websocket_service/main.zag"
pass=0
expected_pass=6

build_one() {
    local output=$1
    (
        # Source-tree std: imports resolve from the checkout even when the
        # compiler under test is a staged binary in a temporary directory.
        cd "$root"
        zag_run_bounded 300 "$compiler" "$source_file" \
            "${target_args[@]}" -o "$output" \
            --no-zagd --no-analyze --no-foreground-cache
    ) >"$tmp/build.out" 2>"$tmp/build.err"
    test -x "$output"
}

build_one "$tmp/websocket-service-a"
pass=$((pass + 1))
build_one "$tmp/websocket-service-b"
pass=$((pass + 1))
zag_assert_native_executable "$tmp/websocket-service-a"
zag_assert_native_executable "$tmp/websocket-service-b"
pass=$((pass + 1))
cmp -s "$tmp/websocket-service-a" "$tmp/websocket-service-b"
pass=$((pass + 1))
zag_run_bounded 30 "$tmp/websocket-service-a" >"$tmp/app-a.out" 2>"$tmp/app-a.err"
printf 'websocket service: upgrade=101 text=ack:42 negatives=5\n' | \
    cmp -s - "$tmp/app-a.out"
test ! -s "$tmp/app-a.err"
pass=$((pass + 1))
zag_run_bounded 30 "$tmp/websocket-service-b" >"$tmp/app-b.out" 2>"$tmp/app-b.err"
cmp -s "$tmp/app-a.out" "$tmp/app-b.out"
test ! -s "$tmp/app-b.err"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'WebSocket service reference app: pass=%d fail=0\n' "$pass"
