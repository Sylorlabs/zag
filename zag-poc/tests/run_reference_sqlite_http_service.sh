#!/usr/bin/env bash
# Bounded SQLite-backed HTTP/1.1 loopback reference service gate.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-reference-sqlite-http.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/sqlite_http_service/main.zag"
pass=0
expected_pass=10

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
    echo 'SQLite HTTP reference app: unsupported host (requires Linux x86-64)' >&2
    exit 2
fi
if ! grep -q 'libsqlite3\.so\.0' < <(ldconfig -p 2>/dev/null); then
    echo 'SQLite HTTP reference app: libsqlite3.so.0 unavailable' >&2
    exit 2
fi
pass=$((pass + 1))

build_one() {
    local output=$1
    timeout 300 "$compiler" "$source_file" --dynamic \
        --needed libsqlite3.so.0 \
        --no-zagd --no-analyze --no-foreground-cache -o "$output" \
        >"$output.build.out" 2>"$output.build.err"
    test -x "$output"
}

assert_sqlite_dynamic_elf() {
    local artifact=$1
    test -x "$artifact"
    readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
    readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC'
    readelf -h "$artifact" | \
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
    readelf -l "$artifact" | grep -q 'INTERP'
    test "$(readelf -d "$artifact" | grep -c 'NEEDED')" -eq 1
    readelf -d "$artifact" | grep -Eq \
        'NEEDED.*Shared library: \[libsqlite3\.so\.0\]'
    ldd "$artifact" | grep -q 'libsqlite3\.so\.0 => /'
}

run_sqlite_service() {
    local artifact=$1
    local label=$2
    timeout 30 "$artifact" >"$tmp/$label.out" 2>"$tmp/$label.err"
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
assert_sqlite_dynamic_elf "$tmp/sqlite-http-a"
pass=$((pass + 1))
assert_sqlite_dynamic_elf "$tmp/sqlite-http-b"
pass=$((pass + 1))
run_sqlite_service "$tmp/sqlite-http-a" app-a
pass=$((pass + 1))
run_sqlite_service "$tmp/sqlite-http-b" app-b
pass=$((pass + 1))

rm -f "$tmp/no-dynamic"
if "$compiler" "$source_file" --needed libsqlite3.so.0 \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-dynamic" \
    >"$tmp/no-dynamic.log" 2>&1; then
    echo 'SQLite HTTP reference app compiled without explicit dynamic mode' >&2
    exit 1
fi
grep -q 'requires explicit --dynamic mode' "$tmp/no-dynamic.log"
test ! -e "$tmp/no-dynamic"
pass=$((pass + 1))

rm -f "$tmp/no-soname"
if "$compiler" "$source_file" --dynamic \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-soname" \
    >"$tmp/no-soname.log" 2>&1; then
    echo 'SQLite HTTP reference app compiled without explicit SQLite SONAME' >&2
    exit 1
fi
grep -q 'dynamic requires at least one --needed SONAME' "$tmp/no-soname.log"
test ! -e "$tmp/no-soname"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'SQLite HTTP reference app: pass=%d fail=0\n' "$pass"
