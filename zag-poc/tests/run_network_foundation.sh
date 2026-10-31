#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo "network foundation: unsupported host (requires Linux x86-64)" >&2
    exit 2
fi

znc_bin=${ZNC:-./znc}
work_dir=$(mktemp -d /tmp/zag-network-foundation.XXXXXX)
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

static_elf() {
    local artifact=$1
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64' &&
        file "$artifact" | grep -q 'statically linked' &&
        ! readelf -l "$artifact" 2>/dev/null | grep -q 'INTERP'
}

record "public IPv4 module type-checks" \
    timeout 120 "$znc_bin" check std/net_ipv4.zag --no-zagd --no-analyze
record "public DNS module type-checks" \
    timeout 120 "$znc_bin" check std/dns_ipv4.zag --no-zagd --no-analyze
record "public libc resolver module type-checks" \
    timeout 120 "$znc_bin" check std/dns_system.zag --no-zagd --no-analyze
record "public IPv6 module type-checks" \
    timeout 120 "$znc_bin" check std/net_ipv6.zag --no-zagd --no-analyze

if timeout 180 "$znc_bin" tests/net_ipv4_loopback.zag \
        -o "$work_dir/net-ipv4-loopback" --no-zagd --no-analyze >/dev/null; then
    record "TCP and UDP IPv4 loopback execute" \
        timeout 15 "$work_dir/net-ipv4-loopback"
    record "network probe is static Linux x86-64" \
        static_elf "$work_dir/net-ipv4-loopback"
else
    echo "  XX  TCP and UDP IPv4 loopback compile"
    fail=$((fail + 1))
fi

if timeout 180 "$znc_bin" tests/dns_system_resolver.zag \
        --dynamic --needed libc.so.6 --no-zagd --no-analyze \
        -o "$work_dir/dns-system-resolver" >/dev/null 2>&1; then
    record "bounded libc resolver executes" \
        timeout 15 "$work_dir/dns-system-resolver"
    record "resolver probe has explicit libc dynamic dependency" \
        sh -c "readelf -l '$work_dir/dns-system-resolver' | grep -q 'Requesting program interpreter' && readelf -d '$work_dir/dns-system-resolver' | grep -q 'libc.so.6'"
else
    echo "  XX  bounded libc resolver compiles"
    fail=$((fail + 1))
fi

if timeout 180 "$znc_bin" tests/dns_ipv4_wire.zag \
        -o "$work_dir/dns-ipv4-wire" --no-zagd --no-analyze >/dev/null; then
    record "bounded DNS A wire corpus executes" \
        timeout 15 "$work_dir/dns-ipv4-wire"
    record "DNS probe is static Linux x86-64" \
        static_elf "$work_dir/dns-ipv4-wire"
else
    echo "  XX  bounded DNS A wire corpus compiles"
    fail=$((fail + 1))
fi

if timeout 180 "$znc_bin" tests/net_ipv6_loopback.zag \
        -o "$work_dir/net-ipv6-loopback" --no-zagd --no-analyze >/dev/null; then
    record "TCP and UDP IPv6 loopback execute" \
        timeout 15 "$work_dir/net-ipv6-loopback"
    record "IPv6 probe is static Linux x86-64" \
        static_elf "$work_dir/net-ipv6-loopback"
else
    echo "  XX  TCP and UDP IPv6 loopback compiles"
    fail=$((fail + 1))
fi

echo "Network foundation: pass=$pass fail=$fail"
test "$fail" -eq 0
