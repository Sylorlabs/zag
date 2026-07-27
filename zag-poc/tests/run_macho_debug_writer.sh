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

compiler=${ZNC:-./znc}
test -x "$compiler"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macho-debug.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/probe.zag" <<ZAG
@import("$PWD/selfhost/native/macho_arm64.zag")
@import("$PWD/selfhost/native/dwarf.zag")
fn main() i32 {
    let text: ArrayList[u8] = make[u8](4);
    push[u8](&text,192 as u8);push[u8](&text,3 as u8);push[u8](&text,95 as u8);push[u8](&text,214 as u8);
    let data: ArrayList[u8] = make[u8](1);
    let db: DwarfBuilder = dwarf_new("probe.zag");
    dwarf_build_abbrev(&db);dwarf_emit_compile_unit(&db);dwarf_emit_function(&db,"main",3);dwarf_finish(&db);dwarf_emit_line_program(&db);
    let ds: DwarfSections = dwarf_build(&db);
    return write_macho_arm64_data_debug("/tmp/zag-macho-debug-output",text,0,data,ds.abbrev,ds.info,ds.line_);
}
ZAG

rm -f /tmp/zag-macho-debug-output
"$compiler" "$tmp/probe.zag" --target macos-arm64 --no-zagd --no-analyze -o "$tmp/driver" >/dev/null
"$tmp/driver"
file /tmp/zag-macho-debug-output | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict /tmp/zag-macho-debug-output
otool -l /tmp/zag-macho-debug-output | grep -q '__DWARF'
dwarfdump /tmp/zag-macho-debug-output | grep -q 'DW_TAG_compile_unit'
dwarfdump /tmp/zag-macho-debug-output | grep -q 'DW_TAG_subprogram'
rm -f /tmp/zag-macho-debug-output
echo "macho debug writer: pass"
