#!/usr/bin/env bash
# Native reference application for bounded dlopen/dlsym/call/dlclose lifecycle.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
cc_bin=${CC:-cc}
tmp=$(mktemp -d /tmp/zag-reference-dynamic-plugin.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fixture="$root/tests/reference_apps/dynamic_plugin"
library="$tmp/libzag_answer_plugin.so.1"
app="$tmp/dynamic-plugin-host"
app_repro="$tmp/dynamic-plugin-host-repro"
pass=0
expected_pass=9

command -v "$cc_bin" >/dev/null
"$cc_bin" -shared -fPIC -Wl,-soname,libzag_answer_plugin.so.1 \
    "$fixture/answer_plugin.c" -o "$library"
readelf -h "$library" >"$tmp/plugin-header.out"
grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/plugin-header.out"
grep -Eq 'Type:[[:space:]]+DYN' "$tmp/plugin-header.out"
grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' \
    "$tmp/plugin-header.out"
readelf -d "$library" | grep -Eq \
    'SONAME.*Library soname: \[libzag_answer_plugin\.so\.1\]'
pass=$((pass + 1))

assert_plugin_host_elf() {
    local artifact=$1
    test -x "$artifact"
    readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
    readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC'
    readelf -h "$artifact" | \
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
    readelf -l "$artifact" | grep -q 'INTERP'
    test "$(readelf -d "$artifact" | grep -c 'NEEDED')" -eq 1
    readelf -d "$artifact" | grep -Eq \
        'NEEDED.*Shared library: \[libdl\.so\.2\]'
    ldd "$artifact" | grep -q 'libdl\.so\.2 => /'
}

run_plugin_host() {
    local artifact=$1
    local label=$2
    timeout 30 "$artifact" "$library" >"$tmp/$label.out" 2>"$tmp/$label.err"
    printf 'dynamic plugin: answer=42 unloads=1\n' | \
        cmp -s - "$tmp/$label.out"
    test ! -s "$tmp/$label.err"
}

"$compiler" "$fixture/main.zag" --dynamic --needed libdl.so.2 \
    --no-zagd --no-analyze --no-foreground-cache -o "$app" \
    >"$tmp/build.out" 2>&1
test -x "$app"
pass=$((pass + 1))
assert_plugin_host_elf "$app"
pass=$((pass + 1))
run_plugin_host "$app" success
pass=$((pass + 1))

set +e
timeout 30 "$app" "$tmp/missing-plugin.so" >"$tmp/missing.out" 2>"$tmp/missing.err"
missing_status=$?
timeout 30 "$app" "$library" definitely_missing_symbol \
    >"$tmp/symbol.out" 2>"$tmp/symbol.err"
symbol_status=$?
timeout 30 "$app" "$library" invalid-symbol \
    >"$tmp/invalid-symbol.out" 2>"$tmp/invalid-symbol.err"
invalid_symbol_status=$?
timeout 30 "$app" >"$tmp/args.out" 2>"$tmp/args.err"
args_status=$?
set -e
test "$missing_status" -eq 10
test "$symbol_status" -eq 23
test "$invalid_symbol_status" -eq 21
test "$args_status" -eq 2
test ! -s "$tmp/missing.out"
test ! -s "$tmp/symbol.out"
test ! -s "$tmp/invalid-symbol.out"
test ! -s "$tmp/args.out"
pass=$((pass + 1))

rm -f "$tmp/no-dynamic" "$tmp/no-needed"
if "$compiler" "$fixture/main.zag" --needed libdl.so.2 \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-dynamic" \
    >"$tmp/no-dynamic.log" 2>&1; then
    echo 'dynamic plugin host compiled without --dynamic' >&2
    exit 1
fi
grep -q 'requires explicit --dynamic mode' "$tmp/no-dynamic.log"
test ! -e "$tmp/no-dynamic"
pass=$((pass + 1))

if "$compiler" "$fixture/main.zag" --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-needed" \
    >"$tmp/no-needed.log" 2>&1; then
    echo 'dynamic plugin host compiled without an explicit SONAME' >&2
    exit 1
fi
grep -q 'dynamic requires at least one --needed SONAME' "$tmp/no-needed.log"
test ! -e "$tmp/no-needed"
pass=$((pass + 1))

(cd /tmp && "$compiler" "$fixture/main.zag" --dynamic \
    --needed libdl.so.2 --no-zagd --no-analyze --no-foreground-cache \
    -o "$app_repro") >"$tmp/repro.log" 2>&1
assert_plugin_host_elf "$app_repro"
cmp -s "$app" "$app_repro"
pass=$((pass + 1))
run_plugin_host "$app_repro" repro
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'Dynamic plugin reference app: pass=%d fail=0\n' "$pass"
