#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"
znc_bin=${ZNC:-$(zag_native_compiler "$root")}
case "$znc_bin" in
    /*) ;;
    *) znc_bin="$root/${znc_bin#./}" ;;
esac
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-config-log.XXXXXX")
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

record "flat configuration module type-checks" \
    zag_run_bounded 120 "$znc_bin" check "$root/std/config_flat.zag" \
        --no-zagd --no-analyze --no-foreground-cache
record "structured logging module type-checks" \
    zag_run_bounded 120 "$znc_bin" check "$root/std/log_json.zag" \
        --no-zagd --no-analyze --no-foreground-cache

if zag_run_bounded 180 "$znc_bin" "$root/tests/config_log_services.zag" \
        -o "$work_dir/config-log" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null; then
    expected='{"ts_sec":1700000000,"ts_nsec":123456789,"level":"info","event":"service.start","message":"hello\n\"zag\""}'
    set +e
    zag_run_bounded 15 "$work_dir/config-log" >"$work_dir/stdout" 2>"$work_dir/stderr"
    status=$?
    set -e
    record "bounded config and JSON logger execute" test "$status" -eq 0
    printf '%s\n' "$expected" >"$work_dir/expected"
    record "logger emits exact one-record stderr" \
        cmp -s "$work_dir/expected" "$work_dir/stderr"
    record "logger emits no stdout" test ! -s "$work_dir/stdout"
    record "config/log probe is a native executable" \
        zag_assert_native_executable "$work_dir/config-log"
else
    echo "  XX  bounded config/log corpus compiles"
    fail=$((fail + 1))
fi

echo "Configuration and logging: pass=$pass fail=$fail"
test "$fail" -eq 0
