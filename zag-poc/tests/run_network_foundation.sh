#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

. tests/portable.sh

native_platform=$(zag_native_platform)
znc_bin=${ZNC:-$(zag_native_compiler "$PWD")}
case "$znc_bin" in
    /*) ;;
    *) znc_bin="$PWD/${znc_bin#./}" ;;
esac
target_args=()
case "$native_platform" in
    linux-arm64) target_args=(--target arm64) ;;
    macos-arm64) target_args=(--target macos-arm64) ;;
esac
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-network-foundation.XXXXXX")
trap 'rm -rf "$work_dir"' EXIT

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

record "public IPv4 module type-checks" \
    zag_run_bounded 120 "$znc_bin" check std/net_ipv4.zag \
        "${target_args[@]}" --no-zagd --no-analyze --no-foreground-cache
record "public DNS module type-checks" \
    zag_run_bounded 120 "$znc_bin" check std/dns_ipv4.zag \
        "${target_args[@]}" --no-zagd --no-analyze --no-foreground-cache

if zag_run_bounded 180 "$znc_bin" tests/net_ipv4_loopback.zag \
        "${target_args[@]}" -o "$work_dir/net-ipv4-loopback" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    record "TCP and UDP IPv4 loopback execute" \
        zag_run_bounded 15 "$work_dir/net-ipv4-loopback"
    record "network probe is a native executable" \
        zag_assert_native_executable "$work_dir/net-ipv4-loopback"
else
    echo "  XX  TCP and UDP IPv4 loopback compile"
    fail=$((fail + 1))
fi

if zag_run_bounded 180 "$znc_bin" tests/net_ipv4_udp_truncation.zag \
        "${target_args[@]}" -o "$work_dir/net-ipv4-udp-truncation" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    record "oversized UDP datagram reports truncation and is consumed" \
        zag_run_bounded 15 "$work_dir/net-ipv4-udp-truncation"
    record "UDP truncation probe is a native executable" \
        zag_assert_native_executable "$work_dir/net-ipv4-udp-truncation"
else
    echo "  XX  bounded UDP truncation contract compiles"
    fail=$((fail + 1))
fi

if zag_run_bounded 180 "$znc_bin" tests/net_ipv4_accept_timeout.zag \
        "${target_args[@]}" -o "$work_dir/net-ipv4-accept-timeout" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    record "accept honors its explicit timeout without a client" \
        zag_run_bounded 15 "$work_dir/net-ipv4-accept-timeout"
    record "accept timeout probe is a native executable" \
        zag_assert_native_executable "$work_dir/net-ipv4-accept-timeout"
else
    echo "  XX  bounded accept timeout contract compiles"
    fail=$((fail + 1))
fi

if zag_run_bounded 180 "$znc_bin" tests/dns_ipv4_wire.zag \
        "${target_args[@]}" -o "$work_dir/dns-ipv4-wire" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    record "bounded DNS A wire corpus executes" \
        zag_run_bounded 15 "$work_dir/dns-ipv4-wire"
    record "DNS probe is a native executable" \
        zag_assert_native_executable "$work_dir/dns-ipv4-wire"
else
    echo "  XX  bounded DNS A wire corpus compiles"
    fail=$((fail + 1))
fi

echo "Network foundation: pass=$pass fail=$fail"
test "$fail" -eq 0
