#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
I686_REFERENCE_TOOLS=${ZAG_I686_REFERENCE_TOOLS:-1}
tmp=$(mktemp -d /tmp/zag-i686-link.XXXXXX)
trap 'find "$tmp" -type f -delete; rmdir "$tmp"' EXIT
i686_exec(){
  "$@" 2>"$tmp/i686-loader.stderr"; local rc=$?
  if { [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; } && command -v qemu-i386 >/dev/null 2>&1; then
    qemu-i386 "$@"; return $?
  fi
  cat "$tmp/i686-loader.stderr" >&2
  return "$rc"
}

"$ZNC" tests/i686_link_driver.zag -o "$tmp/link-driver" --no-analyze --no-zagd >/dev/null
"$tmp/link-driver" --fixtures \
    "$tmp/entry.o" \
    "$tmp/helper.o" \
    "$tmp/duplicate.o" \
    "$tmp/libhelper.a" \
    "$tmp/corrupt-metadata.o" \
    "$tmp/corrupt-relocation.o" \
    "$tmp/absolute.o" \
    "$tmp/unsupported-relocation.o" \
    "$tmp/malformed-symbol.o" \
    "$tmp/over-aligned.o" \
    "$tmp/weak-only.o" \
    "$tmp/libstrong-optional.a" \
    "$tmp/strong-ref.o" \
    "$tmp/weak-answer.o" \
    "$tmp/strong-answer.o" \
    "$tmp/libweak-answer.a" \
    "$tmp/common-ref.o" \
    "$tmp/common-small.o" \
    "$tmp/common-large.o" \
    "$tmp/libcommon.a" \
    "$tmp/shared-ref.o" \
    "$tmp/shared-strong.o" \
    "$tmp/malformed-common.o" \
    "$tmp/out-of-range-symbol.o"

"$tmp/link-driver" "$tmp/multi" "$tmp/entry.o" "$tmp/helper.o"
set +e; i686_exec "$tmp/multi"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  cross-object PC32 call and R_386_32 data relocation execute"

if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -lW "$tmp/multi" >"$tmp/phdrs"
    grep -Eq 'LOAD[[:space:]].*R E[[:space:]]' "$tmp/phdrs"
    grep -Eq 'LOAD[[:space:]].*RW[[:space:]]' "$tmp/phdrs"
    if grep -Eq 'LOAD[[:space:]].*RWE' "$tmp/phdrs"; then
        echo "  XX  linker emitted a writable executable PT_LOAD"; exit 1
    fi
    echo "  ok  linked image separates RX text from RW data (W^X)"
else
    echo "  --  W^X program-header inspection skipped (readelf unavailable)"
fi

"$tmp/link-driver" "$tmp/archive" "$tmp/entry.o" "$tmp/libhelper.a"
set +e; i686_exec "$tmp/archive"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  archive extracts only the first member satisfying an unresolved symbol"

if "$tmp/link-driver" "$tmp/dup" "$tmp/entry.o" "$tmp/helper.o" "$tmp/duplicate.o" >"$tmp/dup.log" 2>&1; then
    echo "  XX  duplicate definition was accepted"; exit 1
fi
grep -q 'duplicate symbol: helper' "$tmp/dup.log"
test ! -e "$tmp/dup"
echo "  ok  duplicate global definition rejects with its symbol name"

if "$tmp/link-driver" "$tmp/missing" "$tmp/entry.o" >"$tmp/missing.log" 2>&1; then
    echo "  XX  undefined symbol was accepted"; exit 1
fi
grep -q 'undefined symbol: helper' "$tmp/missing.log"
test ! -e "$tmp/missing"
echo "  ok  missing definition rejects with its symbol name"

if "$tmp/link-driver" "$tmp/corrupt" "$tmp/corrupt-metadata.o" >"$tmp/corrupt.log" 2>&1; then
    echo "  XX  malformed symbol metadata was accepted"; exit 1
fi
grep -q 'unsupported or corrupt ELF32/i386 ET_REL input' "$tmp/corrupt.log"
test ! -e "$tmp/corrupt"
echo "  ok  malformed symbol-table metadata rejects before linker traversal"

if "$tmp/link-driver" "$tmp/corrupt-relocation" "$tmp/corrupt-relocation.o" >"$tmp/corrupt-relocation.log" 2>&1; then
    echo "  XX  out-of-section relocation offset was accepted"; exit 1
fi
grep -q 'unsupported or corrupt ELF32/i386 ET_REL input' "$tmp/corrupt-relocation.log"
test ! -e "$tmp/corrupt-relocation"
echo "  ok  relocation crossing its target section rejects before patching"

"$tmp/link-driver" "$tmp/absolute" "$tmp/absolute.o"
set +e; i686_exec "$tmp/absolute"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  SHN_ABS R_386_32 and R_386_PC32 use absolute symbol values"

if "$tmp/link-driver" "$tmp/unsupported-relocation" "$tmp/unsupported-relocation.o" >"$tmp/unsupported-relocation.log" 2>&1; then
    echo "  XX  unsupported relocation type was accepted"; exit 1
fi
grep -q 'unsupported relocation type: 99' "$tmp/unsupported-relocation.log"
test ! -e "$tmp/unsupported-relocation"
echo "  ok  unsupported relocation kind rejects before symbol resolution"

if "$tmp/link-driver" "$tmp/malformed-symbol" "$tmp/malformed-symbol.o" >"$tmp/malformed-symbol.log" 2>&1; then
    echo "  XX  out-of-range symbol section index was accepted"; exit 1
fi
grep -q 'unsupported or corrupt ELF32/i386 ET_REL input' "$tmp/malformed-symbol.log"
test ! -e "$tmp/malformed-symbol"
echo "  ok  malformed symbol section index rejects before linker traversal"

if "$tmp/link-driver" "$tmp/out-of-range-symbol" "$tmp/out-of-range-symbol.o" >"$tmp/out-of-range-symbol.log" 2>&1; then
    echo "  XX  section-escaping symbol value was accepted"; exit 1
fi
grep -q 'unsupported or corrupt ELF32/i386 ET_REL input' "$tmp/out-of-range-symbol.log"
test ! -e "$tmp/out-of-range-symbol"
echo "  ok  section-escaping symbol value rejects before layout"

"$tmp/link-driver" "$tmp/weak-only" "$tmp/weak-only.o" "$tmp/libstrong-optional.a"
set +e; i686_exec "$tmp/weak-only"; rc=$?; set -e
test "$rc" -eq 0
echo "  ok  weak-only R_386_32 and R_386_PC32 references use S=0 and do not extract archives"

"$tmp/link-driver" "$tmp/strong-overrides-weak" "$tmp/strong-ref.o" "$tmp/weak-answer.o" "$tmp/strong-answer.o"
set +e; i686_exec "$tmp/strong-overrides-weak"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  strong global definition overrides a weak definition deterministically"

if "$tmp/link-driver" "$tmp/weak-archive" "$tmp/strong-ref.o" "$tmp/libweak-answer.a" >"$tmp/weak-archive.log" 2>&1; then
    echo "  XX  archive weak definition satisfied a strong demand"; exit 1
fi
grep -q 'undefined symbol: answer' "$tmp/weak-archive.log"
test ! -e "$tmp/weak-archive"
echo "  ok  archive demand extraction considers strong globals only"

"$tmp/link-driver" "$tmp/common-direct" "$tmp/common-ref.o" "$tmp/common-small.o" "$tmp/common-large.o"
set +e; i686_exec "$tmp/common-direct"; rc=$?; set -e
test "$rc" -eq 0
echo "  ok  direct COMMON declarations merge by max size/alignment and zero-fill RW storage"

"$tmp/link-driver" "$tmp/common-archive" "$tmp/common-ref.o" "$tmp/libcommon.a"
set +e; i686_exec "$tmp/common-archive"; rc=$?; set -e
test "$rc" -eq 0
echo "  ok  a strong COMMON archive member satisfies demand and allocates zero-filled storage"

"$tmp/link-driver" "$tmp/common-overridden" "$tmp/shared-ref.o" "$tmp/common-small.o" "$tmp/shared-strong.o"
set +e; i686_exec "$tmp/common-overridden"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  an included regular strong definition overrides COMMON"

if "$tmp/link-driver" "$tmp/malformed-common" "$tmp/malformed-common.o" >"$tmp/malformed-common.log" 2>&1; then
    echo "  XX  malformed COMMON alignment was accepted"; exit 1
fi
grep -q 'unsupported or corrupt ELF32/i386 ET_REL input' "$tmp/malformed-common.log"
test ! -e "$tmp/malformed-common"
echo "  ok  malformed COMMON alignment rejects before linker traversal"

if "$tmp/link-driver" "$tmp/over-aligned" "$tmp/over-aligned.o" >"$tmp/over-aligned.log" 2>&1; then
    echo "  XX  over-aligned input was accepted"; exit 1
fi
grep -q 'section alignment exceeds the supported 4096-byte limit' "$tmp/over-aligned.log"
test ! -e "$tmp/over-aligned"
echo "  ok  over-aligned ET_REL input rejects before output allocation"

"$ZNC" tests/i686_compiler_entry.zag --target i686 --emit-obj -o "$tmp/compiler-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_compiler_helper.zag --target i686 --emit-obj -o "$tmp/compiler-helper.o" --no-analyze --no-zagd >/dev/null

if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -rW "$tmp/compiler-entry.o" >"$tmp/compiler-entry-relocs"
    readelf -sW "$tmp/compiler-entry.o" >"$tmp/compiler-entry-symbols"
    readelf -sW "$tmp/compiler-helper.o" >"$tmp/compiler-helper-symbols"
    grep -Eq 'R_386_PC32[[:space:]]+.*external_answer' "$tmp/compiler-entry-relocs"
    grep -Eq 'UND[[:space:]]+external_answer' "$tmp/compiler-entry-symbols"
    grep -Eq '[[:space:]]1[[:space:]]+external_answer' "$tmp/compiler-helper-symbols"
    echo "  ok  compiler objects publish the external call relocation and strong definition"
else
    echo "  --  compiler object metadata inspection skipped (readelf unavailable)"
fi

"$ZNC" "$tmp/compiler-entry.o" "$tmp/compiler-helper.o" --target i686 --link-i686 -o "$tmp/compiler-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/compiler-linked"; rc=$?; set -e
test "$rc" -eq 42
echo "  ok  compiler-produced objects link and execute across a function boundary"

"$ZNC" tests/i686_compiler_abi_entry.zag --target i686 --emit-obj -o "$tmp/compiler-abi-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_compiler_abi_helper.zag --target i686 --emit-obj -o "$tmp/compiler-abi-helper.o" --no-analyze --no-zagd >/dev/null
"$ZNC" "$tmp/compiler-abi-entry.o" "$tmp/compiler-abi-helper.o" --target i686 --link-i686 -o "$tmp/compiler-abi-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/compiler-abi-linked"; rc=$?; set -e
test "$rc" -eq 42
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -rW "$tmp/compiler-abi-entry.o" >"$tmp/compiler-abi-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*external_combine' "$tmp/compiler-abi-entry-relocs"
fi
echo "  ok  compiler-produced objects preserve six-word cdecl calls across an external boundary"

"$ZNC" tests/i686_narrow_abi_entry.zag --target i686 --emit-obj -o "$tmp/narrow-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_narrow_abi_helper.zag --target i686 --emit-obj -o "$tmp/narrow-helper.o" --no-analyze --no-zagd >/dev/null
"$ZNC" "$tmp/narrow-entry.o" "$tmp/narrow-helper.o" --target i686 --link-i686 -o "$tmp/narrow-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/narrow-linked"; rc=$?; set -e
test "$rc" -eq 42
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v objdump >/dev/null 2>&1; then
    # Execution proves the combined boundary. These instruction witnesses also
    # prevent caller/callee double-normalization from masking a missing half:
    # the entry must publish normalized arguments and consume normalized
    # results, while the helper must normalize parameter views and EAX returns.
    objdump -dr "$tmp/narrow-entry.o" >"$tmp/narrow-entry.dis"
    objdump -dr "$tmp/narrow-helper.o" >"$tmp/narrow-helper.dis"
    for dis in "$tmp/narrow-entry.dis" "$tmp/narrow-helper.dis"; do
        grep -Eq 'movsbl[[:space:]]+%al,%eax' "$dis"
        grep -Eq 'movzbl[[:space:]]+%al,%eax' "$dis"
        grep -Eq 'movswl[[:space:]]+%ax,%eax' "$dis"
        grep -Eq 'movzwl[[:space:]]+%ax,%eax' "$dis"
        grep -Eq 'setne[[:space:]]+%al' "$dis"
    done
fi
echo "  ok  compiler objects normalize i8/u8/i16/u16/bool cdecl arguments, parameter views, storage, and EAX returns"

"$ZNC" tests/i686_narrow_struct_abi_entry.zag --target i686 --emit-obj -o "$tmp/narrow-struct-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_narrow_struct_abi_helper.zag --target i686 --emit-obj -o "$tmp/narrow-struct-helper.o" --no-analyze --no-zagd >/dev/null
"$ZNC" "$tmp/narrow-struct-entry.o" "$tmp/narrow-struct-helper.o" --target i686 --link-i686 -o "$tmp/narrow-struct-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/narrow-struct-linked"; rc=$?; set -e
test "$rc" -eq 42
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -rW "$tmp/narrow-struct-entry.o" >"$tmp/narrow-struct-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*transform_narrow_packet' "$tmp/narrow-struct-entry-relocs"
fi
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v objdump >/dev/null 2>&1; then
    objdump -dr "$tmp/narrow-struct-entry.o" >"$tmp/narrow-struct-entry.dis"
    objdump -dr "$tmp/narrow-struct-helper.o" >"$tmp/narrow-struct-helper.dis"
    for dis in "$tmp/narrow-struct-entry.dis" "$tmp/narrow-struct-helper.dis"; do
        grep -Eq 'movsbl[[:space:]]+%al,%eax' "$dis"
        grep -Eq 'movzbl[[:space:]]+%al,%eax' "$dis"
        grep -Eq 'movswl[[:space:]]+%ax,%eax' "$dis"
        grep -Eq 'movzwl[[:space:]]+%ax,%eax' "$dis"
        grep -Eq 'setne[[:space:]]+%al' "$dis"
    done
fi
echo "  ok  flat narrow-field structs normalize local copies, cdecl words, field views, and hidden-sret output across objects"

"$ZNC" tests/i686_float_struct_abi_entry.zag --target i686 --emit-obj -o "$tmp/float-struct-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_float_struct_abi_helper.zag --target i686 --emit-obj -o "$tmp/float-struct-helper.o" --no-analyze --no-zagd >/dev/null
"$ZNC" "$tmp/float-struct-entry.o" "$tmp/float-struct-helper.o" --target i686 --link-i686 -o "$tmp/float-struct-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/float-struct-linked"; rc=$?; set -e
test "$rc" -eq 42
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -rW "$tmp/float-struct-entry.o" >"$tmp/float-struct-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*transform_float_packet' "$tmp/float-struct-entry-relocs"
fi
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v objdump >/dev/null 2>&1; then
    objdump -dr "$tmp/float-struct-entry.o" >"$tmp/float-struct-entry.dis"
    objdump -dr "$tmp/float-struct-helper.o" >"$tmp/float-struct-helper.dis"
    grep -Eq '(^|[[:space:]])flds[[:space:]]' "$tmp/float-struct-entry.dis" "$tmp/float-struct-helper.dis"
    grep -Eq '(^|[[:space:]])fldl[[:space:]]' "$tmp/float-struct-entry.dis" "$tmp/float-struct-helper.dis"
    grep -Eq 'add[l]?[[:space:]]+\$0x14,%esp' "$tmp/float-struct-entry.dis"
    grep -Eq 'ret[l]?[[:space:]]+\$0x4' "$tmp/float-struct-helper.dis"
fi
echo "  ok  mixed f32/f64 structs preserve 4-byte i386 alignment, 20-byte cdecl transport, field operations, and hidden-sret output"

"$ZNC" tests/i686_nested_struct_abi_entry.zag --target i686 --emit-obj -o "$tmp/nested-struct-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_nested_struct_abi_helper.zag --target i686 --emit-obj -o "$tmp/nested-struct-helper.o" --no-analyze --no-zagd >/dev/null
"$ZNC" "$tmp/nested-struct-entry.o" "$tmp/nested-struct-helper.o" --target i686 --link-i686 -o "$tmp/nested-struct-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/nested-struct-linked"; rc=$?; set -e
test "$rc" -eq 42
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -rW "$tmp/nested-struct-entry.o" >"$tmp/nested-struct-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*transform_envelope' "$tmp/nested-struct-entry-relocs"
fi
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v objdump >/dev/null 2>&1; then
    objdump -dr "$tmp/nested-struct-entry.o" >"$tmp/nested-struct-entry.dis"
    objdump -dr "$tmp/nested-struct-helper.o" >"$tmp/nested-struct-helper.dis"
    grep -Eq 'add[l]?[[:space:]]+\$0x30,%esp' "$tmp/nested-struct-entry.dis"
    grep -Eq 'ret[l]?[[:space:]]+\$0x4' "$tmp/nested-struct-helper.dis"
fi
echo "  ok  acyclic nested sequential structs flatten 12 checked words across cdecl arguments, field paths, copies, and hidden-sret"

"$ZNC" tests/i686_i64_abi_entry.zag --target i686 --emit-obj -o "$tmp/i64-entry.o" --no-analyze --no-zagd >/dev/null
"$ZNC" tests/i686_i64_abi_helper.zag --target i686 --emit-obj -o "$tmp/i64-helper.o" --no-analyze --no-zagd >/dev/null
"$ZNC" "$tmp/i64-entry.o" "$tmp/i64-helper.o" --target i686 --link-i686 -o "$tmp/i64-linked" --no-analyze --no-zagd >/dev/null
set +e; i686_exec "$tmp/i64-linked"; rc=$?; set -e
test "$rc" -eq 42
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
    readelf -rW "$tmp/i64-entry.o" >"$tmp/i64-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*external_wide_mix' "$tmp/i64-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*external_wide_product' "$tmp/i64-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*external_signed_divmod' "$tmp/i64-entry-relocs"
    grep -Eq 'R_386_PC32[[:space:]]+.*transform_wide_packet' "$tmp/i64-entry-relocs"
fi
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v objdump >/dev/null 2>&1; then
    objdump -dr "$tmp/i64-entry.o" >"$tmp/i64-entry.dis"
    objdump -dr "$tmp/i64-helper.o" >"$tmp/i64-helper.dis"
    grep -Eq 'adc[l]?[[:space:]]' "$tmp/i64-helper.dis"
    grep -Eq 'add[l]?[[:space:]]+\$0x14,%esp' "$tmp/i64-entry.dis"
    grep -Eq 'ret[l]?[[:space:]]+\$0x4' "$tmp/i64-helper.dis"
fi
echo "  ok  i64/u64 use two-word cdecl arguments, EDX:EAX results, full arithmetic, struct leaves, and hidden-sret across objects"

if "$ZNC" tests/i686_reject_recursive_struct.zag --target i686 -o "$tmp/bad-recursive-struct" --no-analyze --no-zagd >"$tmp/bad-recursive-struct.log" 2>&1; then
    echo "  XX  recursive by-value aggregate unexpectedly acquired a finite layout"; exit 1
fi
test ! -e "$tmp/bad-recursive-struct"
grep -q 'aggregate returns require 32-bit scalar fields' "$tmp/bad-recursive-struct.log"
echo "  ok  direct or mutual by-value aggregate cycles remain fail-closed before artifact output"

if "$ZNC" tests/i686_reject_narrow_literal.zag --target i686 -o "$tmp/bad-narrow-literal" --no-analyze --no-zagd >"$tmp/bad-narrow-literal.log" 2>&1; then
    echo "  XX  out-of-range contextual i8 literal was accepted"; exit 1
fi
test ! -e "$tmp/bad-narrow-literal"
grep -q 'i8 literal exceeds the signed 8-bit target range' "$tmp/bad-narrow-literal.log"
echo "  ok  contextual narrow literals reject truncation unless the source uses an explicit cast"

if "$ZNC" tests/i686_compiler_entry.zag --target i686 -o "$tmp/unresolved-direct" --no-analyze --no-zagd >"$tmp/unresolved-direct.log" 2>&1; then
    echo "  XX  direct executable accepted an unresolved extern"; exit 1
fi
test ! -e "$tmp/unresolved-direct"
grep -q 'external functions require --emit-obj or --emit-static' "$tmp/unresolved-direct.log"
echo "  ok  unresolved extern remains fail-closed outside object/archive emission"

echo "i686 multi-object: pass=30 fail=0"
