#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo "Linux OS services: unsupported host (requires Linux x86-64)" >&2
    exit 2
fi

znc_bin=${ZNC:-./znc}
work_dir=$(mktemp -d /tmp/zag-os-linux.XXXXXX)
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

record "public clock/random module type-checks" \
    timeout 120 "$znc_bin" check std/os_linux.zag \
        --no-zagd --no-analyze --no-foreground-cache

if timeout 180 "$znc_bin" tests/os_linux_services.zag \
        -o "$work_dir/os-linux-services" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    record "clock and secure-randomness corpus executes" \
        timeout 15 "$work_dir/os-linux-services"
    record "clock/random probe is static Linux x86-64" \
        static_elf "$work_dir/os-linux-services"
else
    echo "  XX  clock and secure-randomness corpus compiles"
    fail=$((fail + 1))
fi

echo "Linux OS services: pass=$pass fail=$fail"
test "$fail" -eq 0
