#!/usr/bin/env bash
# Focused native conformance for the bounded i64 database-driver contract.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-database-drivers.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

if "$compiler" "$root/tests/database_memory_conformance.zag" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/memory" \
    >"$tmp/memory.build" 2>&1 && test -x "$tmp/memory" &&
    readelf -h "$tmp/memory" >"$tmp/memory.elf" &&
    grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/memory.elf" &&
    grep -Eq 'Type:[[:space:]]+EXEC' "$tmp/memory.elf" &&
    grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$tmp/memory.elf" &&
    ! readelf -l "$tmp/memory" | grep -q 'INTERP' &&
    ! readelf -d "$tmp/memory" 2>/dev/null | grep -q 'NEEDED'; then
    ok 'pure-Zag memory driver builds as static native ELF64'
else
    bad 'pure-Zag memory driver static ELF metadata'
    sed -n '1,24p' "$tmp/memory.build"
fi

if test -x "$tmp/memory" &&
    "$tmp/memory" >"$tmp/memory.out" 2>"$tmp/memory.err" &&
    printf 'database memory conformance: pass=16 fail=0\n' |
        cmp -s - "$tmp/memory.out" && test ! -s "$tmp/memory.err"; then
    ok 'pure-Zag memory driver passes invalid, missing, limit, update, and cleanup cases'
else
    bad 'pure-Zag memory driver conformance execution'
    sed -n '1,24p' "$tmp/memory.out" 2>/dev/null || true
    sed -n '1,24p' "$tmp/memory.err" 2>/dev/null || true
fi

if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
    --dynamic --needed libsqlite3.so.0 \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/sqlite" \
    >"$tmp/sqlite.build" 2>&1 && test -x "$tmp/sqlite" &&
    readelf -h "$tmp/sqlite" >"$tmp/sqlite.elf" &&
    grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/sqlite.elf" &&
    grep -Eq 'Type:[[:space:]]+EXEC' "$tmp/sqlite.elf" &&
    grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$tmp/sqlite.elf" &&
    readelf -l "$tmp/sqlite" | grep -q 'INTERP' &&
    readelf -d "$tmp/sqlite" | grep -Eq \
        'NEEDED.*Shared library: \[libsqlite3\.so\.0\]'; then
    ok 'SQLite driver builds with explicit interpreter and libsqlite3.so.0 DT_NEEDED'
else
    bad 'SQLite driver dynamic ELF metadata'
    sed -n '1,32p' "$tmp/sqlite.build"
fi

if test -x "$tmp/sqlite" &&
    "$tmp/sqlite" >"$tmp/sqlite.out" 2>"$tmp/sqlite.err" &&
    printf 'database sqlite conformance: pass=16 fail=0\n' |
        cmp -s - "$tmp/sqlite.out" && test ! -s "$tmp/sqlite.err"; then
    ok 'SQLite adapter passes invalid, missing, limit, update, finalize, and close cases'
else
    bad 'SQLite driver conformance execution'
    sed -n '1,24p' "$tmp/sqlite.out" 2>/dev/null || true
    sed -n '1,24p' "$tmp/sqlite.err" 2>/dev/null || true
fi

rm -f "$tmp/no-dynamic"
if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
    --needed libsqlite3.so.0 --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/no-dynamic" >"$tmp/no-dynamic.log" 2>&1 ||
    test -e "$tmp/no-dynamic"; then
    bad 'SQLite SONAME request accepted without explicit dynamic mode'
else
    if grep -q 'requires explicit --dynamic mode' "$tmp/no-dynamic.log"; then
        ok 'SQLite adapter fails closed without --dynamic and emits no artifact'
    else
        bad 'SQLite no-dynamic rejection lacks focused diagnostic'
        sed -n '1,24p' "$tmp/no-dynamic.log"
    fi
fi

rm -f "$tmp/no-soname"
if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
    --dynamic --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/no-soname" >"$tmp/no-soname.log" 2>&1 ||
    test -e "$tmp/no-soname"; then
    bad 'SQLite dynamic build accepted without explicit SONAME'
else
    if grep -q 'dynamic requires at least one --needed SONAME' "$tmp/no-soname.log"; then
        ok 'SQLite adapter fails closed without libsqlite3 SONAME and emits no artifact'
    else
        bad 'SQLite missing-SONAME rejection lacks focused diagnostic'
        sed -n '1,24p' "$tmp/no-soname.log"
    fi
fi

rm -f "$tmp/implicit-static"
if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
    --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/implicit-static" >"$tmp/implicit-static.log" 2>&1 ||
    test -e "$tmp/implicit-static"; then
    bad 'SQLite adapter silently fell back to an implicit static implementation'
else
    if grep -Eq 'call to unknown function `sqlite3_open`|call to unknown function .*sqlite3_open' \
        "$tmp/implicit-static.log"; then
        ok 'SQLite adapter has no implicit static fallback and emits no artifact'
    else
        bad 'SQLite implicit-static rejection lacks SQLite boundary evidence'
        sed -n '1,24p' "$tmp/implicit-static.log"
    fi
fi

echo "database drivers: pass=$pass fail=$fail"
test "$fail" -eq 0
