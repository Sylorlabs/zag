#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo "Configuration and logging: unsupported host (requires Linux x86-64)" >&2
    exit 2
fi
znc_bin=${ZNC:-./znc}
work_dir=$(mktemp -d /tmp/zag-config-log.XXXXXX)
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

record "flat configuration module type-checks" \
    timeout 120 "$znc_bin" check std/config_flat.zag \
        --no-zagd --no-analyze --no-foreground-cache
record "structured logging module type-checks" \
    timeout 120 "$znc_bin" check std/log_json.zag \
        --no-zagd --no-analyze --no-foreground-cache

if timeout 180 "$znc_bin" tests/config_log_services.zag \
        -o "$work_dir/config-log" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    expected='{"ts_sec":1700000000,"ts_nsec":123456789,"level":"info","event":"service.start","message":"hello\n\"zag\""}'
    set +e
    timeout 15 "$work_dir/config-log" >"$work_dir/stdout" 2>"$work_dir/stderr"
    status=$?
    set -e
    record "bounded config and JSON logger execute" test "$status" -eq 0
    printf '%s\n' "$expected" >"$work_dir/expected"
    record "logger emits exact one-record stderr" \
        cmp -s "$work_dir/expected" "$work_dir/stderr"
    record "logger emits no stdout" test ! -s "$work_dir/stdout"
    record "config/log probe is static Linux x86-64" \
        static_elf "$work_dir/config-log"
else
    echo "  XX  bounded config/log corpus compiles"
    fail=$((fail + 1))
fi

echo "Configuration and logging: pass=$pass fail=$fail"
test "$fail" -eq 0
