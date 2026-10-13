#!/usr/bin/env bash
# Exercise the self-hosted Mach-O debug writer independently of a full
# compiler rebuild: real DWARF metadata, a __DWARF segment, and the embedded
# signature must coexist in a native Apple-Silicon executable.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
    echo "macho debug writer: skipped (requires Apple Silicon macOS)"
    exit 0
fi

. ./tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler "$PWD")}
test -x "$compiler"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macho-debug.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/probe.zag" <<ZAG
@import("$PWD/selfhost/native/macho_arm64.zag")
@import("$PWD/selfhost/native/dwarf.zag")
fn main() i32 {
    if (_zag_argc() != 2) { return 2; }
    let text: ArrayList[u8] = make[u8](12);
    // mov x0,#42; mov x16,#1; svc #0x80 (Darwin exit(42)).
    mo_le(&text,0xd2800540,4);mo_le(&text,0xd2800030,4);mo_le(&text,0xd4001001,4);
    let data: ArrayList[u8] = make[u8](1);
    // An empty data segment accidentally concealed mid-page debug mappings.
    push[u8](&data,7);
    let db: DwarfBuilder = dwarf_new("probe.zag");
    dwarf_build_abbrev(&db);dwarf_emit_compile_unit(&db);dwarf_emit_function(&db,"main",3);dwarf_finish(&db);dwarf_emit_line_program(&db);
    let ds: DwarfSections = dwarf_build(&db);
    return write_macho_arm64_data_debug(_zag_arg(1),text,0,data,ds.abbrev,ds.info,ds.line_);
}
ZAG

"$compiler" "$tmp/probe.zag" --target macos-arm64 --no-zagd --no-analyze -o "$tmp/driver" >/dev/null
output="$tmp/output"
"$tmp/driver" "$output"
file "$output" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$output"
otool -l "$output" | grep -q '__DWARF'
dwarfdump "$output" | grep -q 'DW_TAG_compile_unit'
dwarfdump "$output" | grep -q 'DW_TAG_subprogram'
set +e
"$output"
status=$?
set -e
test "$status" -eq 42
echo "macho debug writer: pass"
