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
expected_pass=10

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

# Invalid byte-bearing paths and symbols must be rejected before any dlopen
# allocation or handle publication.  This exercises the same source/runtime
# validation boundary as argv-driven failures while also proving the NUL byte
# cannot be silently truncated by the C-string adapter.
cat >"$tmp/invalid-boundary.zag" <<'ZAG'
@import("std:dynamic_plugin") as plugin
extern fn _zag_allocator_live_bytes() i64
fn main() i32 {
    let before: i64 = _zag_allocator_live_bytes();
    let helper_null: *u8 = plugin.dynamic_plugin_c_string("bad\0helper");
    if (helper_null != null as *u8) {
        _zag_free(helper_null as *i8);
        return 1;
    }
    let bad_path: plugin.DynamicPluginI64 =
        plugin.dynamic_plugin_load_i64("bad\0path", "zag_plugin_apply");
    let bad_symbol: plugin.DynamicPluginI64 =
        plugin.dynamic_plugin_load_i64("unused", "bad\0symbol");
    let forged_path: []u8 = "x";
    forged_path.data = null as *u8;
    let forged_symbol: []u8 = "x";
    forged_symbol.data = null as *u8;
    let forged_path_result: plugin.DynamicPluginI64 =
        plugin.dynamic_plugin_load_i64(forged_path, "zag_plugin_apply");
    let forged_symbol_result: plugin.DynamicPluginI64 =
        plugin.dynamic_plugin_load_i64("unused", forged_symbol);
    if (bad_path.status != plugin.dynamic_plugin_invalid() ||
        bad_path.open != 0 || bad_symbol.status != plugin.dynamic_plugin_invalid() ||
        bad_symbol.open != 0 ||
        forged_path_result.status != plugin.dynamic_plugin_invalid() ||
        forged_path_result.open != 0 ||
        forged_symbol_result.status != plugin.dynamic_plugin_invalid() ||
        forged_symbol_result.open != 0 || _zag_allocator_live_bytes() != before) {
        return 1;
    }
    _zag_println("dynamic plugin boundary: nul-rejected cleanup=ok");
    return 0;
}
ZAG
if "$compiler" "$tmp/invalid-boundary.zag" --dynamic --needed libdl.so.2 \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/invalid-boundary" \
    >"$tmp/invalid-boundary.log" 2>&1 &&
    timeout 30 "$tmp/invalid-boundary" >"$tmp/invalid-boundary.out" \
        2>"$tmp/invalid-boundary.err" &&
    printf 'dynamic plugin boundary: nul-rejected cleanup=ok\n' |
        cmp -s - "$tmp/invalid-boundary.out" &&
    test ! -s "$tmp/invalid-boundary.err"; then
    echo "dynamic plugin rejects embedded-NUL path/symbol before allocation"
    pass=$((pass + 1))
else
    echo "dynamic plugin embedded-NUL boundary failed" >&2
    sed -n '1,20p' "$tmp/invalid-boundary.log"
    sed -n '1,20p' "$tmp/invalid-boundary.out" 2>/dev/null || true
    sed -n '1,20p' "$tmp/invalid-boundary.err" 2>/dev/null || true
    exit 1
fi

test "$pass" -eq "$expected_pass"
printf 'Dynamic plugin reference app: pass=%d fail=0\n' "$pass"
