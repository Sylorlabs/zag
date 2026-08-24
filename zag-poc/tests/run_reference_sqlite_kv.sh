#!/usr/bin/env bash
# Native reference application for the bounded SQLite i64 KV adapter.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-reference-sqlite-kv.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
source_file="$root/tests/reference_apps/sqlite_kv/main.zag"
app="$tmp/sqlite-kv"

"$compiler" "$source_file" --dynamic --needed libsqlite3.so.0 \
    --no-zagd --no-analyze --no-foreground-cache -o "$app" \
    >"$tmp/build.out" 2>&1
test -x "$app"

readelf -h "$app" >"$tmp/header.out"
grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/header.out"
grep -Eq 'Type:[[:space:]]+EXEC' "$tmp/header.out"
grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$tmp/header.out"
readelf -l "$app" | grep -q 'INTERP'
readelf -d "$app" | grep -Eq \
    'NEEDED.*Shared library: \[libsqlite3\.so\.0\]'

"$app" >"$tmp/app.out" 2>"$tmp/app.err"
printf 'sqlite kv inventory: rows=2 total=42\n' | cmp -s - "$tmp/app.out"
test ! -s "$tmp/app.err"

rm -f "$tmp/no-dynamic"
if "$compiler" "$source_file" --needed libsqlite3.so.0 \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/no-dynamic" \
    >"$tmp/no-dynamic.log" 2>&1; then
    echo 'SQLite reference app compiled without explicit dynamic mode' >&2
    exit 1
fi
grep -q 'requires explicit --dynamic mode' "$tmp/no-dynamic.log"
test ! -e "$tmp/no-dynamic"

echo 'SQLite KV reference app: pass=5 fail=0'
