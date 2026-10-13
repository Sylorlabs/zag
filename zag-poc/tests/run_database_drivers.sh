#!/usr/bin/env bash
# Focused native conformance for the bounded i64 database-driver contract.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-database-drivers.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
host="$(uname -s):$(uname -m)"

pass=0
fail=0
ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

memory_format_ok=0
if "$compiler" "$root/tests/database_memory_conformance.zag" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/memory" \
    >"$tmp/memory.build" 2>&1 && test -x "$tmp/memory"; then
    case "$host" in
        Darwin:arm64)
            if file "$tmp/memory" | grep -q 'Mach-O 64-bit executable arm64' &&
                codesign --verify --strict "$tmp/memory"; then
                memory_format_ok=1
            fi
            ;;
        Linux:x86_64|Linux:amd64)
            if readelf -h "$tmp/memory" >"$tmp/memory.elf" &&
                grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/memory.elf" &&
                grep -Eq 'Type:[[:space:]]+EXEC' "$tmp/memory.elf" &&
                grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$tmp/memory.elf" &&
                ! readelf -l "$tmp/memory" | grep -q 'INTERP' &&
                ! readelf -d "$tmp/memory" 2>/dev/null | grep -q 'NEEDED'; then
                memory_format_ok=1
            fi
            ;;
        Linux:aarch64|Linux:arm64)
            if file "$tmp/memory" | grep -Eq 'ELF 64-bit.*(ARM aarch64|AArch64).*statically linked'; then
                memory_format_ok=1
            fi
            ;;
    esac
fi
if test "$memory_format_ok" -eq 1; then
    ok 'pure-Zag memory driver builds as the exact native executable format'
else
    bad 'pure-Zag memory driver native executable metadata'
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

sqlite_target_args=()
sqlite_link_args=()
case "$host" in
    Linux:x86_64|Linux:amd64)
        sqlite_link_args=(--dynamic --needed libsqlite3.so.0)
        ;;
    Darwin:arm64)
        sqlite_target_args=(--target macos-arm64)
        sqlite_link_args=(--dynamic)
        ;;
    *)
        echo "  --  native SQLite driver is not yet gated on $host; native memory driver built and executed"
        echo "database drivers: pass=$pass fail=$fail"
        test "$fail" -eq 0
        exit
        ;;
esac

if test "$host" = Darwin:arm64; then
    if "$compiler" "$root/tests/macos_sqlite_writer_contract.zag" \
        --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache \
        -o "$tmp/sqlite-writer-contract" >"$tmp/sqlite-writer-contract.build" 2>&1 &&
        file "$tmp/sqlite-writer-contract" | grep -q 'Mach-O 64-bit executable arm64' &&
        codesign --verify --strict "$tmp/sqlite-writer-contract" &&
        "$tmp/sqlite-writer-contract" "$tmp/sqlite-writer-probe" \
            >"$tmp/sqlite-writer-contract.out" 2>&1 &&
        grep -qx 'macos sqlite writer contract: exact=8 ordinals=4 closed=1' \
            "$tmp/sqlite-writer-contract.out" &&
        file "$tmp/sqlite-writer-probe" | grep -q 'Mach-O 64-bit executable arm64' &&
        codesign --verify --strict "$tmp/sqlite-writer-probe" &&
        otool -L "$tmp/sqlite-writer-probe" >"$tmp/sqlite-writer-probe.dylibs" &&
        grep -q '/usr/lib/libSystem.B.dylib' "$tmp/sqlite-writer-probe.dylibs" &&
        grep -q '/usr/lib/libsqlite3.dylib' "$tmp/sqlite-writer-probe.dylibs" &&
        test "$(grep -c '^[[:space:]]/' "$tmp/sqlite-writer-probe.dylibs")" -eq 2 &&
        xcrun llvm-objdump --macho --bind "$tmp/sqlite-writer-probe" \
            >"$tmp/sqlite-writer-probe.bind"; then
        sqlite_bind_ok=1
        for sqlite_symbol in open close prepare_v2 bind_int64 step column_int64 finalize changes; do
            if ! grep -Eq "libsqlite3[[:space:]]+_sqlite3_${sqlite_symbol}$" \
                "$tmp/sqlite-writer-probe.bind"; then
                sqlite_bind_ok=0
            fi
        done
        if test "$sqlite_bind_ok" -eq 1 &&
            test "$(grep -c 'libsqlite3.*_sqlite3_' "$tmp/sqlite-writer-probe.bind")" -eq 8; then
            ok 'Mach-O writer keeps the exact SQLite symbol family and compact ordinals closed'
        else
            bad 'Mach-O SQLite bind ordinals'
            sed -n '1,32p' "$tmp/sqlite-writer-probe.bind"
        fi
    else
        bad 'Mach-O SQLite writer contract'
        sed -n '1,24p' "$tmp/sqlite-writer-contract.build" 2>/dev/null || true
        sed -n '1,24p' "$tmp/sqlite-writer-contract.out" 2>/dev/null || true
    fi
fi

if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
    "${sqlite_target_args[@]}" "${sqlite_link_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/sqlite" \
    >"$tmp/sqlite.build" 2>&1 && test -x "$tmp/sqlite"; then
    sqlite_format_ok=0
    case "$host" in
        Linux:x86_64|Linux:amd64)
            if readelf -h "$tmp/sqlite" >"$tmp/sqlite.elf" &&
                grep -Eq 'Class:[[:space:]]+ELF64' "$tmp/sqlite.elf" &&
                grep -Eq 'Type:[[:space:]]+EXEC' "$tmp/sqlite.elf" &&
                grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' "$tmp/sqlite.elf" &&
                readelf -l "$tmp/sqlite" | grep -q 'INTERP' &&
                readelf -d "$tmp/sqlite" | grep -Eq \
                    'NEEDED.*Shared library: \[libsqlite3\.so\.0\]'; then
                sqlite_format_ok=1
            fi
            ;;
        Darwin:arm64)
            if file "$tmp/sqlite" | grep -q 'Mach-O 64-bit executable arm64' &&
                codesign --verify --strict "$tmp/sqlite" &&
                otool -L "$tmp/sqlite" >"$tmp/sqlite.dylibs" &&
                grep -q '/usr/lib/libSystem.B.dylib' "$tmp/sqlite.dylibs" &&
                grep -q '/usr/lib/libsqlite3.dylib' "$tmp/sqlite.dylibs" &&
                test "$(grep -c '^[[:space:]]/' "$tmp/sqlite.dylibs")" -eq 2 &&
                ! grep -q '/Metal.framework/' "$tmp/sqlite.dylibs" &&
                ! grep -q '/usr/lib/libobjc.A.dylib' "$tmp/sqlite.dylibs"; then
                sqlite_format_ok=1
            fi
            ;;
    esac
    if test "$sqlite_format_ok" -eq 1; then
        case "$host" in
            Darwin:arm64) ok 'SQLite driver is a signed Mach-O bound only to libSystem and /usr/lib/libsqlite3.dylib' ;;
            *) ok 'SQLite driver builds with explicit interpreter and libsqlite3.so.0 DT_NEEDED' ;;
        esac
    else
        bad 'SQLite driver native dynamic metadata'
        sed -n '1,32p' "$tmp/sqlite.build"
        sed -n '1,24p' "$tmp/sqlite.dylibs" 2>/dev/null || true
    fi
else
    bad 'SQLite driver native dynamic build'
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

case "$host" in
    Linux:x86_64|Linux:amd64)
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
        ;;
    Darwin:arm64)
        rm -f "$tmp/implicit-static"
        if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
            --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache \
            -o "$tmp/implicit-static" >"$tmp/implicit-static.log" 2>&1 ||
            test -e "$tmp/implicit-static"; then
            bad 'macOS SQLite adapter accepted an implicit dynamic dependency'
        elif grep -q 'std:sqlite_kv requires explicit --dynamic mode' \
            "$tmp/implicit-static.log"; then
            ok 'macOS SQLite adapter requires --dynamic and emits no fallback artifact'
        else
            bad 'macOS SQLite no-dynamic rejection lacks focused diagnostic'
            sed -n '1,24p' "$tmp/implicit-static.log"
        fi

        rm -f "$tmp/caller-dylib"
        if "$compiler" "$root/tests/database_sqlite_conformance.zag" \
            --target macos-arm64 --dynamic --needed libsqlite3.so.0 \
            --no-zagd --no-analyze --no-foreground-cache -o "$tmp/caller-dylib" \
            >"$tmp/caller-dylib.log" 2>&1 || test -e "$tmp/caller-dylib"; then
            bad 'macOS SQLite adapter accepted a caller-selected dylib'
        elif grep -q -- '--needed is not supported; audited imports select fixed system dylibs' \
            "$tmp/caller-dylib.log"; then
            ok 'macOS SQLite dylib selection is closed and target-owned'
        else
            bad 'macOS caller-selected dylib rejection lacks focused diagnostic'
            sed -n '1,24p' "$tmp/caller-dylib.log"
        fi

        rm -f "$tmp/abi-invalid"
        if "$compiler" "$root/tests/macos_sqlite_import_abi_negative.zag" \
            --target macos-arm64 --dynamic --no-zagd --no-analyze \
            --no-foreground-cache -o "$tmp/abi-invalid" \
            >"$tmp/abi-invalid.log" 2>&1 || test -e "$tmp/abi-invalid"; then
            bad 'macOS SQLite import allowlist accepted a near-name or mismatched ABI'
        elif grep -q 'unsupported external symbol or ABI: sqlite3_open' \
            "$tmp/abi-invalid.log" &&
            grep -q 'unsupported external symbol or ABI: sqlite3_open_v2' \
            "$tmp/abi-invalid.log"; then
            ok 'macOS SQLite import allowlist rejects ABI drift and unlisted entry points'
        else
            bad 'macOS SQLite import rejection lacks exact symbol evidence'
            sed -n '1,24p' "$tmp/abi-invalid.log"
        fi
        ;;
esac

echo "database drivers: pass=$pass fail=$fail"
test "$fail" -eq 0
