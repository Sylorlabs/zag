#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-static-archive-cabi.XXXXXX")

cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "static-archive-cabi: FAIL" >&2
        for log in "$work"/*.log; do
            [ -f "$log" ] || continue
            echo "-- $(basename "$log")" >&2
            sed -n '1,120p' "$log" >&2
        done
    fi
    trap - EXIT
    rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$work/lib-valid" "$work/lib-duplicate" "$work/lib-bad-header" \
    "$work/lib-bad-elf" "$work/project" "$work/forbidden-bin"

# The implementation claim is a self-contained Zag compiler/linker path. Make
# accidental delegation to a host build tool an executable failure, not an
# inference from a quiet log.
for forbidden_tool in cc gcc g++ clang clang++ as ar ld lld mold rustc zig; do
    printf '%s\n' '#!/bin/sh' \
        'printf "%s\n" "$0" >>"$ZAG_FORBIDDEN_TOOL_LOG"' \
        'exit 125' >"$work/forbidden-bin/$forbidden_tool"
    chmod 755 "$work/forbidden-bin/$forbidden_tool"
done
export ZAG_FORBIDDEN_TOOL_LOG="$work/forbidden-tools.log"
export PATH="$work/forbidden-bin:$PATH"

# Prove the source-level relocation formula independently of archive parsing,
# member selection, executable layout, and call lowering. This catches the
# historical double subtraction of the four-byte call immediate directly.
"$compiler" "$root/tests/fixtures/elf_obj_plt32_oracle.zag" \
    -o "$work/plt32-oracle" --no-zagd --no-analyze --no-foreground-cache \
    >"$work/plt32-oracle-build.log" 2>&1
"$work/plt32-oracle" >"$work/plt32-oracle-run.log" 2>&1

# Compile a pure-Zag fixture tool, then use Zag's ELF writer plus a minimal GNU
# ar symbol table to create the input archive. No cc, as, ar, ld, or host object
# generator participates in this regression.
"$compiler" "$root/tests/fixtures/static_archive_cabi_generator.zag" \
    -o "$work/generator" --no-zagd --no-analyze --no-foreground-cache \
    >"$work/generator-build.log" 2>&1
"$work/generator" "$work/probe.o" "$work/lib-valid/libprobe.a" \
    "$work/lib-duplicate/libprobe.a" "$work/lib-bad-header/libprobe.a" \
    "$work/lib-bad-elf/libprobe.a" \
    >"$work/generator-run.log" 2>&1
test -s "$work/probe.o"
test -s "$work/lib-valid/libprobe.a"

printf 'name = "static_archive_cabi"\nversion = "0"\nedition = "2027"\n' \
    >"$work/project/zag.mod"
cp "$root/tests/fixtures/static_archive_cabi_main.zag" \
    "$work/project/main.zag"
cp "$root/tests/fixtures/static_archive_cabi_generic_bad.zag" \
    "$work/project/generic-bad.zag"

# A pre-feature seed is expected to fail here with an unknown static @cabi
# import. That is a real regression failure, not a skip or an accepted result.
if ! "$compiler" "$work/project/main.zag" -L "$work/lib-valid" \
    -o "$work/app" --no-zagd --no-analyze --no-foreground-cache \
    >"$work/consumer-build.log" 2>&1; then
    echo "static-archive-cabi: compiler rejected bounded static @cabi import" \
        >&2
    exit 1
fi

test -x "$work/app"
grep -Eq '\+ [1-9][0-9]* bytes libs' "$work/consumer-build.log"

# The final 50 bytes are the selected object's .text. Its file/virtual start
# must honor the writer's 16-byte sh_addralign even when main text does not.
rx_filesz=$(readelf -lW "$work/app" | awk '$1 == "LOAD" && $7 == "R" && $8 == "E" { print $5; exit }')
if [ -z "$rx_filesz" ] || [ $((rx_filesz - 50)) -lt 0 ] ||
    [ $(((rx_filesz - 50) % 16)) -ne 0 ]; then
    echo "static-archive-cabi: selected object text is not 16-byte aligned" >&2
    exit 1
fi
set +e
"$work/app"
app_rc=$?
set -e
if [ "$app_rc" -ne 42 ]; then
    echo "static-archive-cabi: linked executable exited $app_rc, expected 42" \
        >&2
    exit 1
fi

expect_reject() {
    label=$1
    source=$2
    libdir=$3
    pattern=$4
    output="$work/rejected-$label"
    log="$work/rejected-$label.log"
    if "$compiler" "$source" -L "$libdir" -o "$output" \
        --no-zagd --no-analyze --no-foreground-cache >"$log" 2>&1; then
        echo "static-archive-cabi: $label was accepted" >&2
        return 1
    fi
    if [ -e "$output" ]; then
        echo "static-archive-cabi: $label left an output artifact" >&2
        return 1
    fi
    if ! grep -Eq "$pattern" "$log"; then
        echo "static-archive-cabi: $label missed its fail-closed diagnostic" >&2
        return 1
    fi
}

expect_reject duplicate "$work/project/main.zag" "$work/lib-duplicate" \
    'symbol table contains duplicate definitions'
expect_reject malformed-header "$work/project/main.zag" "$work/lib-bad-header" \
    'missing a valid GNU symbol table'
expect_reject malformed-elf "$work/project/main.zag" "$work/lib-bad-elf" \
    'unsupported or malformed ELF64/x86-64 member'
expect_reject generic-import "$work/project/generic-bad.zag" "$work/lib-valid" \
    'generic @cabi imports are unsupported'

if [ -s "$ZAG_FORBIDDEN_TOOL_LOG" ]; then
    echo "static-archive-cabi: compiler invoked a forbidden host build tool" >&2
    sed -n '1,40p' "$ZAG_FORBIDDEN_TOOL_LOG" >&2
    exit 1
fi

echo "static-archive-cabi: PASS (7 typed calls, aligned pure-Zag archive, 4 fail-closed negatives, no host build tools)"
