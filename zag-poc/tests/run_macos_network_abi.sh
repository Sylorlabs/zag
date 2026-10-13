#!/usr/bin/env bash
# Native Darwin socket-layout, flag-translation, and inheritance boundary gate.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

if [ "$(zag_native_platform)" != macos-arm64 ]; then
    echo 'macOS network ABI: unsupported host (requires Apple Silicon macOS)' >&2
    exit 2
fi

compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
if [ ! -x "$compiler" ]; then
    echo "macOS network ABI: compiler is not executable: $compiler" >&2
    exit 2
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-network-abi.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
pass=0

run_probe() {
    local source=$1 output=$2 label=$3 status
    zag_run_bounded 240 "$compiler" "$root/tests/$source" \
        --target macos-arm64 -o "$tmp/$output" \
        --no-zagd --no-analyze --no-foreground-cache
    zag_assert_native_executable "$tmp/$output"
    set +e
    zag_run_bounded 30 "$tmp/$output"
    status=$?
    set -e
    if [ "$status" -ne 42 ]; then
        echo "  XX  $label (exit $status, expected 42)" >&2
        return 1
    fi
    echo "  ok  $label"
    pass=$((pass + 1))
}

run_probe macos_socket_cloexec.zag socket-cloexec \
    'TCP/UDP and accepted descriptors are close-on-exec'
run_probe macos_socket_abi_negative.zag socket-negative \
    'unaudited Linux-shaped socket tuples fail closed'

printf 'macOS network ABI: pass=%d fail=0\n' "$pass"
