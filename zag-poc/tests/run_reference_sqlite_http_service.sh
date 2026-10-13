#!/usr/bin/env bash
# Bounded SQLite-backed HTTP/1.1 loopback reference service gate.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"

native_platform=$(zag_native_platform)
compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-sqlite-http.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/sqlite_http_service/main.zag"
pass=0
expected_pass=10
target_args=()
link_args=()

case "$native_platform" in
    linux-x86_64)
        if ! grep -q 'libsqlite3\.so\.0' < <(ldconfig -p 2>/dev/null); then
            echo 'SQLite HTTP reference app: libsqlite3.so.0 unavailable' >&2
            exit 2
        fi
        link_args=(--dynamic --needed libsqlite3.so.0)
        ;;
    macos-arm64)
        target_args=(--target macos-arm64)
        link_args=(--dynamic)
        ;;
    *)
        echo "SQLite HTTP reference app: unsupported native platform $native_platform" >&2
        exit 2
        ;;
esac
pass=$((pass + 1))

build_one() {
    local output=$1
    zag_run_bounded 300 "$compiler" "$source_file" \
        "${target_args[@]}" "${link_args[@]}" \
        --no-zagd --no-analyze --no-foreground-cache -o "$output" \
        >"$output.build.out" 2>"$output.build.err"
    test -x "$output"
}

assert_sqlite_native_dynamic() {
    local artifact=$1
    test -x "$artifact"
    case "$native_platform" in
        linux-x86_64)
            readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
            readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC'
            readelf -h "$artifact" | \
                grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
            readelf -l "$artifact" | grep -q 'INTERP'
            test "$(readelf -d "$artifact" | grep -c 'NEEDED')" -eq 1
            readelf -d "$artifact" | grep -Eq \
                'NEEDED.*Shared library: \[libsqlite3\.so\.0\]'
            ldd "$artifact" | grep -q 'libsqlite3\.so\.0 => /'
            ;;
        macos-arm64)
            file "$artifact" | grep -q 'Mach-O 64-bit executable arm64'
            codesign --verify --strict "$artifact"
            otool -L "$artifact" >"$artifact.dylibs"
            grep -q '/usr/lib/libSystem.B.dylib' "$artifact.dylibs"
            grep -q '/usr/lib/libsqlite3.dylib' "$artifact.dylibs"
            test "$(grep -c '^[[:space:]]/' "$artifact.dylibs")" -eq 2
            ! grep -q '/Metal.framework/' "$artifact.dylibs"
            ! grep -q '/usr/lib/libobjc.A.dylib' "$artifact.dylibs"
            ;;
    esac
}

run_sqlite_service() {
    local artifact=$1
    local label=$2
    zag_run_bounded 30 "$artifact" >"$tmp/$label.out" 2>"$tmp/$label.err"
    printf 'sqlite http service: value=42 missing=404 method=405 requests=3 cleanup_negative=1\n' | \
        cmp -s - "$tmp/$label.out"
    test ! -s "$tmp/$label.err"
}

build_one "$tmp/sqlite-http-a"
pass=$((pass + 1))
build_one "$tmp/sqlite-http-b"
pass=$((pass + 1))
cmp -s "$tmp/sqlite-http-a" "$tmp/sqlite-http-b"
pass=$((pass + 1))
assert_sqlite_native_dynamic "$tmp/sqlite-http-a"
pass=$((pass + 1))
assert_sqlite_native_dynamic "$tmp/sqlite-http-b"
pass=$((pass + 1))
run_sqlite_service "$tmp/sqlite-http-a" app-a
pass=$((pass + 1))
run_sqlite_service "$tmp/sqlite-http-b" app-b
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
    echo 'SQLite HTTP reference app compiled without explicit dynamic mode' >&2
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
            echo 'SQLite HTTP reference app compiled without explicit SQLite SONAME' >&2
            exit 1
        fi
        grep -q 'dynamic requires at least one --needed SONAME' "$tmp/link-policy.log"
        ;;
    macos-arm64)
        if zag_run_bounded 300 "$compiler" "$source_file" --target macos-arm64 \
            --dynamic --needed libsqlite3.so.0 --no-zagd --no-analyze \
            --no-foreground-cache -o "$tmp/link-policy" \
            >"$tmp/link-policy.log" 2>&1; then
            echo 'SQLite HTTP reference app accepted a caller-selected macOS dylib' >&2
            exit 1
        fi
        grep -q -- '--needed is not supported; audited imports select fixed system dylibs' \
            "$tmp/link-policy.log"
        ;;
esac
test ! -e "$tmp/link-policy"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'SQLite HTTP reference app: pass=%d fail=0\n' "$pass"
