#!/usr/bin/env bash
# Native reference application for the bounded SQLite i64 KV adapter.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

native_platform=$(zag_native_platform)
compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-sqlite-kv.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/sqlite_kv/main.zag"
app="$tmp/sqlite-kv"
pass=0
expected_pass=6
target_args=()
link_args=()

case "$native_platform" in
    linux-x86_64)
        if ! grep -q 'libsqlite3\.so\.0' < <(ldconfig -p 2>/dev/null); then
            echo 'SQLite KV reference app: libsqlite3.so.0 unavailable' >&2
            exit 2
        fi
        link_args=(--dynamic --needed libsqlite3.so.0)
        ;;
    macos-arm64)
        target_args=(--target macos-arm64)
        link_args=(--dynamic)
        ;;
    *)
        echo "SQLite KV reference app: unsupported native platform $native_platform" >&2
        exit 2
        ;;
esac
pass=$((pass + 1))

zag_run_bounded 300 "$compiler" "$source_file" \
    "${target_args[@]}" "${link_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$app" \
    >"$tmp/build.out" 2>&1
test -x "$app"
pass=$((pass + 1))

case "$native_platform" in
    linux-x86_64)
        readelf -h "$app" >"$tmp/header.out"
        grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/header.out"
        grep -Eq 'Type:[[:space:]]+EXEC' "$tmp/header.out"
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$tmp/header.out"
        readelf -l "$app" | grep -q 'INTERP'
        test "$(readelf -d "$app" | grep -c 'NEEDED')" -eq 1
        readelf -d "$app" | grep -Eq \
            'NEEDED.*Shared library: \[libsqlite3\.so\.0\]'
        ;;
    macos-arm64)
        file "$app" | grep -q 'Mach-O 64-bit executable arm64'
        codesign --verify --strict "$app"
        otool -L "$app" >"$tmp/dylibs.out"
        grep -q '/usr/lib/libSystem.B.dylib' "$tmp/dylibs.out"
        grep -q '/usr/lib/libsqlite3.dylib' "$tmp/dylibs.out"
        test "$(grep -c '^[[:space:]]/' "$tmp/dylibs.out")" -eq 2
        ! grep -q '/Metal.framework/' "$tmp/dylibs.out"
        ! grep -q '/usr/lib/libobjc.A.dylib' "$tmp/dylibs.out"
        ;;
esac
pass=$((pass + 1))

zag_run_bounded 30 "$app" >"$tmp/app.out" 2>"$tmp/app.err"
printf 'sqlite kv inventory: rows=2 total=42\n' | cmp -s - "$tmp/app.out"
test ! -s "$tmp/app.err"
pass=$((pass + 1))

rm -f "$tmp/no-dynamic"
no_dynamic_args=()
case "$native_platform" in
    linux-x86_64) no_dynamic_args=(--needed libsqlite3.so.0) ;;
    macos-arm64) no_dynamic_args=(--target macos-arm64) ;;
esac
if zag_run_bounded 300 "$compiler" "$source_file" "${no_dynamic_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-dynamic" \
    >"$tmp/no-dynamic.log" 2>&1; then
    echo 'SQLite reference app compiled without explicit dynamic mode' >&2
    exit 1
fi
grep -q 'requires explicit --dynamic mode' "$tmp/no-dynamic.log"
test ! -e "$tmp/no-dynamic"
pass=$((pass + 1))

rm -f "$tmp/link-policy"
case "$native_platform" in
    linux-x86_64)
        if zag_run_bounded 300 "$compiler" "$source_file" --dynamic \
            --no-zagd --no-analyze --no-foreground-cache -o "$tmp/link-policy" \
            >"$tmp/link-policy.log" 2>&1; then
            echo 'SQLite reference app compiled without explicit SQLite SONAME' >&2
            exit 1
        fi
        grep -q 'dynamic requires at least one --needed SONAME' "$tmp/link-policy.log"
        ;;
    macos-arm64)
        if zag_run_bounded 300 "$compiler" "$source_file" --target macos-arm64 \
            --dynamic --needed libsqlite3.so.0 --no-zagd --no-analyze \
            --no-foreground-cache -o "$tmp/link-policy" \
            >"$tmp/link-policy.log" 2>&1; then
            echo 'SQLite reference app accepted a caller-selected macOS dylib' >&2
            exit 1
        fi
        grep -q -- '--needed is not supported; audited imports select fixed system dylibs' \
            "$tmp/link-policy.log"
        ;;
esac
test ! -e "$tmp/link-policy"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'SQLite KV reference app: pass=%d fail=0\n' "$pass"
