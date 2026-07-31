#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
I686_REFERENCE_TOOLS=${ZAG_I686_REFERENCE_TOOLS:-1}
tmp=$(mktemp -d /tmp/zag-i686.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok(){ echo "  ok  $1"; pass=$((pass+1)); }
bad(){ echo "  XX  $1"; fail=$((fail+1)); }
skip(){ echo "  --  $1"; }
# Prefer the host Linux i386 compatibility path.  A kernel without it is not
# treated as a compiler failure when qemu-i386 is available; every execution
# assertion below uses this same native-or-emulated path.
i686_exec(){
  "$@" 2>"$tmp/i686-loader.stderr"; local rc=$?
  if { [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; } && command -v qemu-i386 >/dev/null 2>&1; then
    qemu-i386 "$@"; return $?
  fi
  cat "$tmp/i686-loader.stderr" >&2
  return "$rc"
}

if "$ZNC" tests/i686_literal.zag --target i686 -o "$tmp/a.out" --no-analyze >/dev/null; then ok "literal main emits"; else bad "literal main emits"; fi
class=$(od -An -tu1 -j4 -N1 "$tmp/a.out" | tr -d ' ')
machine=$(od -An -tu1 -j18 -N2 "$tmp/a.out" | xargs)
if [ "$class" = 1 ] && [ "$machine" = "3 0" ]; then ok "artifact is ELF32 EM_386"; else bad "ELF32 identity"; fi
shnum=$(od -An -tu1 -j48 -N1 "$tmp/a.out" | tr -d ' ')
if [ "$shnum" = 6 ]; then ok "ELF32 section table is present"; else bad "ELF32 section table"; fi
if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v readelf >/dev/null 2>&1; then
  if readelf -S -s "$tmp/a.out" 2>/dev/null | grep -q '\.debug_line' && readelf -s "$tmp/a.out" 2>/dev/null | grep -q ' main$'; then ok "reference reader sees text symbols and debug line"; else bad "readelf metadata"; fi
else
  skip "reference ELF metadata inspection skipped"
fi
if "$ZNC" tests/i686_literal.zag --target i686 --emit-obj -o "$tmp/main.o" --no-analyze >/dev/null; then
  etype=$(od -An -tu1 -j16 -N1 "$tmp/main.o" | tr -d ' ')
  if [ "$etype" = 1 ]; then ok "ELF32 ET_REL object emits"; else bad "ELF32 relocatable type"; fi
  if [ "$I686_REFERENCE_TOOLS" != 1 ]; then
    skip "reference relocation inspection skipped"
  elif command -v readelf >/dev/null 2>&1; then
    if readelf -r "$tmp/main.o" 2>/dev/null | grep -q 'R_386_PC32.*main'; then ok "R_386_PC32 startup relocation is published"; else bad "ELF32 relocation metadata"; fi
  else
    skip "reference relocation inspection skipped"
  fi
  if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v ld >/dev/null 2>&1 && ld -m elf_i386 -o "$tmp/linked" "$tmp/main.o" >/dev/null 2>&1; then
    set +e; i686_exec "$tmp/linked"; linked_rc=$?; set -e
    if [ "$linked_rc" -eq 42 ]; then ok "reference linker resolves relocatable object"; else bad "linked object status=$linked_rc"; fi
  fi
else bad "ELF32 object emits"; fi
if "$ZNC" tests/i686_literal.zag --target i686 --emit-static -o "$tmp/libmain.a" --no-analyze >/dev/null &&
   "$ZNC" "$tmp/libmain.a" --target i686 --link-i686 -o "$tmp/pure-linked" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/pure-linked"; pure_rc=$?; set -e
  if [ "$pure_rc" -eq 42 ]; then ok "pure Zag archive writer and ELF32 linker execute"; else bad "pure linked status=$pure_rc"; fi
else bad "pure Zag static archive/link path"; fi
set +e
i686_exec "$tmp/a.out"; rc=$?
set -e
if [ "$rc" -eq 42 ]; then ok "native-or-qemu executes i386 int-0x80 exit"; else bad "i386 execution unavailable or failed"; fi
if ! "$ZNC" tests/i686_reject_pointer.zag --target i686 -o "$tmp/bad" --no-analyze >"$tmp/reject.log" 2>&1 &&
   grep -q "unsupported construct" "$tmp/reject.log" && [ ! -e "$tmp/bad" ]; then ok "pointer/local constructs reject before output"; else bad "unsupported construct rejection"; fi
if ! "$ZNC" tests/i686_reject_type_mismatch.zag --target i686 -o "$tmp/type-mismatch" --no-analyze >"$tmp/type-mismatch.log" 2>&1 &&
   grep -q "error\\[E0203\\]: expected \\*i32" "$tmp/type-mismatch.log" && [ ! -e "$tmp/type-mismatch" ]; then ok "shared declared-type authority rejects before output"; else bad "type-authority rejection"; fi
if ! "$ZNC" tests/i686_reject_arity.zag --target i686 -o "$tmp/arity" --no-analyze >"$tmp/arity.log" 2>&1 &&
   grep -q "passes 1 argument(s), expected 2" "$tmp/arity.log" && [ ! -e "$tmp/arity" ]; then ok "shared arity authority rejects before output"; else bad "arity-authority rejection"; fi
if ! "$ZNC" tests/i686_reject_duplicate.zag --target i686 -o "$tmp/duplicate" --no-analyze >"$tmp/duplicate.log" 2>&1 &&
   grep -q "duplicate fn definition 'answer'" "$tmp/duplicate.log" && [ ! -e "$tmp/duplicate" ]; then ok "shared duplicate authority rejects before output"; else bad "duplicate-authority rejection"; fi
if ! "$ZNC" tests/i686_reject_effect.zag --target i686 -o "$tmp/effect" --no-analyze >"$tmp/effect.log" 2>&1 &&
   grep -q "capability violation" "$tmp/effect.log" && [ ! -e "$tmp/effect" ]; then ok "shared effect authority rejects before output"; else bad "effect-authority rejection"; fi
if ! "$ZNC" tests/i686_reject_fallthrough.zag --target i686 -o "$tmp/fallthrough" --no-analyze >"$tmp/fallthrough.log" 2>&1 &&
   grep -q "function can reach its end without returning: maybe" "$tmp/fallthrough.log" && [ ! -e "$tmp/fallthrough" ]; then ok "all-path return authority rejects before output"; else bad "all-path return rejection"; fi
if "$ZNC" tests/i686_return_paths.zag --target i686 -o "$tmp/return-paths" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/return-paths"; return_paths_rc=$?; set -e
  if [ "$return_paths_rc" -eq 42 ]; then ok "exhaustive returning branches execute"; else bad "return-path execution status=$return_paths_rc"; fi
else bad "exhaustive return paths emit"; fi
if "$ZNC" tests/i686_i32_ir.zag --target i686 -o "$tmp/ir" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/ir"; ir_rc=$?; set -e
  if [ "$ir_rc" -eq 42 ]; then ok "i32 IR locals assignment add/sub execute"; else bad "i32 IR execution status=$ir_rc"; fi
else bad "i32 IR emits"; fi
if "$ZNC" tests/i686_integer_arithmetic.zag --target i686 -o "$tmp/arithmetic" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/arithmetic"; arithmetic_rc=$?; set -e
  if [ "$arithmetic_rc" -eq 42 ]; then ok "signed i32 multiply divide remainder and overflow edge execute"; else bad "i32 arithmetic status=$arithmetic_rc"; fi
else bad "signed i32 arithmetic emits"; fi
if "$ZNC" tests/i686_usize_semantics.zag --target i686 -o "$tmp/usize" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/usize"; usize_rc=$?; set -e
  if [ "$usize_rc" -eq 42 ]; then ok "32-bit usize high-bit compare divide remainder wrap and casts execute"; else bad "usize semantics status=$usize_rc"; fi
else bad "32-bit usize semantics emit"; fi
if ! "$ZNC" tests/i686_reject_usize_literal_range.zag --target i686 -o "$tmp/bad-usize-range" --no-analyze >"$tmp/bad-usize-range.log" 2>&1 &&
   grep -q "usize literal exceeds the 32-bit target range" "$tmp/bad-usize-range.log" && [ ! -e "$tmp/bad-usize-range" ]; then ok "out-of-range usize literal rejects before output"; else bad "usize literal range rejection"; fi
if ! "$ZNC" tests/i686_reject_usize_negative.zag --target i686 -o "$tmp/bad-usize-negative" --no-analyze >"$tmp/bad-usize-negative.log" 2>&1 &&
   grep -q "negative values do not implicitly convert to usize" "$tmp/bad-usize-negative.log" && [ ! -e "$tmp/bad-usize-negative" ]; then ok "negative implicit usize conversion rejects before output"; else bad "negative usize conversion rejection"; fi
if ! "$ZNC" tests/i686_reject_usize_implicit.zag --target i686 -o "$tmp/bad-usize-mixed" --no-analyze >"$tmp/bad-usize-mixed.log" 2>&1 &&
   grep -q "mixed i32/usize arithmetic requires an explicit cast" "$tmp/bad-usize-mixed.log" && [ ! -e "$tmp/bad-usize-mixed" ]; then ok "mixed signed/unsigned arithmetic requires an explicit cast"; else bad "mixed usize cast rejection"; fi
if "$ZNC" tests/i686_divide_by_zero.zag --target i686 -o "$tmp/divzero" --no-analyze >/dev/null; then
  set +e; divzero_out=$(i686_exec "$tmp/divzero" 2>&1); divzero_rc=$?; set -e
  if [ "$divzero_rc" -eq 134 ] && [ "$divzero_out" = "panic: division by zero" ]; then ok "division by zero reports and exits 134"; else bad "division-by-zero output=$divzero_out status=$divzero_rc"; fi
else bad "division-by-zero program emits"; fi
if "$ZNC" tests/i686_control_flow.zag --target i686 -o "$tmp/cf" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/cf"; cf_rc=$?; set -e
  if [ "$cf_rc" -eq 42 ]; then ok "comparisons if while break continue execute"; else bad "control-flow execution status=$cf_rc"; fi
else bad "control-flow IR emits"; fi
if "$ZNC" tests/i686_calls.zag --target i686 -o "$tmp/calls" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/calls"; call_rc=$?; set -e
  if [ "$call_rc" -eq 42 ]; then ok "cdecl-like i32 arguments returns and caller cleanup execute"; else bad "call ABI execution status=$call_rc"; fi
else bad "multiple i32 functions emit"; fi
if "$ZNC" tests/i686_abi_pressure.zag --target i686 -o "$tmp/abi-pressure" --no-analyze >/dev/null; then
  set +e; pressure_out=$(i686_exec "$tmp/abi-pressure"); pressure_rc=$?; set -e
  if [ "$pressure_rc" -eq 42 ] && [ "$pressure_out" = "21" ]; then ok "callee-saved scratch registers and stack-spilled six-word calls preserve live locals"; else bad "i386 pressure/ABI output=$pressure_out status=$pressure_rc"; fi
  if [ "$I686_REFERENCE_TOOLS" = 1 ] && command -v objdump >/dev/null 2>&1; then
    objdump -d "$tmp/abi-pressure" >"$tmp/abi-pressure.dis"
    if grep -q 'push   %ebp' "$tmp/abi-pressure.dis" && grep -q 'mov    %esp,%ebp' "$tmp/abi-pressure.dis" &&
       grep -q 'add    $0x18,%esp' "$tmp/abi-pressure.dis" &&
       grep -q 'push   %ebx' "$tmp/abi-pressure.dis" && grep -q 'pop    %ebx' "$tmp/abi-pressure.dis" &&
       grep -q 'push   %esi' "$tmp/abi-pressure.dis" && grep -q 'pop    %esi' "$tmp/abi-pressure.dis" &&
       grep -q 'push   %edi' "$tmp/abi-pressure.dis" && grep -q 'pop    %edi' "$tmp/abi-pressure.dis"; then ok "disassembly proves i386 frame caller cleanup and temporary callee-save balance"; else bad "i386 ABI disassembly"; fi
  else skip "i386 ABI disassembly skipped (objdump unavailable)"; fi
else bad "i386 pressure/ABI fixture emits"; fi
if "$ZNC" tests/i686_f32.zag --target i686 -o "$tmp/f32" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/f32"; f32_rc=$?; set -e
  if [ "$f32_rc" -eq 42 ]; then ok "SysV i386 four-byte f32 arguments arithmetic locals and x87 return execute"; else bad "f32 ABI status=$f32_rc"; fi
else bad "f32 ABI program emits"; fi
if "$ZNC" tests/i686_i64.zag --target i686 -o "$tmp/i64" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/i64"; i64_rc=$?; set -e
  if [ "$i64_rc" -eq 42 ]; then ok "two-word i64/u64 locals literals casts arithmetic division remainder bitwise shifts and comparisons execute"; else bad "i64/u64 semantics status=$i64_rc"; fi
else bad "i64/u64 two-word scalar program emits"; fi
if "$ZNC" tests/i686_i64_divide_by_zero.zag --target i686 -o "$tmp/i64-divzero" --no-analyze >/dev/null; then
  set +e; i64_divzero_out=$(i686_exec "$tmp/i64-divzero" 2>&1); i64_divzero_rc=$?; set -e
  if [ "$i64_divzero_rc" -eq 134 ] && [ "$i64_divzero_out" = "panic: division by zero" ]; then ok "i64 division by zero reports and exits 134"; else bad "i64 division-by-zero output=$i64_divzero_out status=$i64_divzero_rc"; fi
else bad "i64 division-by-zero program emits"; fi
if "$ZNC" tests/i686_i64_remainder_by_zero.zag --target i686 -o "$tmp/u64-remzero" --no-analyze >/dev/null; then
  set +e; u64_remzero_out=$(i686_exec "$tmp/u64-remzero" 2>&1); u64_remzero_rc=$?; set -e
  if [ "$u64_remzero_rc" -eq 134 ] && [ "$u64_remzero_out" = "panic: division by zero" ]; then ok "u64 remainder by zero reports and exits 134"; else bad "u64 remainder-by-zero output=$u64_remzero_out status=$u64_remzero_rc"; fi
else bad "u64 remainder-by-zero program emits"; fi
if "$ZNC" tests/i686_float.zag --target i686 -o "$tmp/float" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/float"; float_rc=$?; set -e
  if [ "$float_rc" -eq 42 ]; then ok "SysV i386 f64 stack arguments x87 return and arithmetic execute"; else bad "f64 ABI status=$float_rc"; fi
else bad "f64 ABI program emits"; fi
if "$ZNC" tests/i686_pointer.zag --target i686 -o "$tmp/pointer" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/pointer"; ptr_rc=$?; set -e
  if [ "$ptr_rc" -eq 42 ]; then ok "32-bit usize pointer address dereference and store execute"; else bad "pointer execution status=$ptr_rc"; fi
else bad "32-bit pointer program emits"; fi
if "$ZNC" tests/i686_pointer_index.zag --target i686 -o "$tmp/pointer-index" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/pointer-index"; pointer_index_rc=$?; set -e
  if [ "$pointer_index_rc" -eq 42 ]; then ok "32-bit pointer index load/store uses target element stride"; else bad "pointer index status=$pointer_index_rc"; fi
else bad "32-bit pointer index program emits"; fi
if ! "$ZNC" tests/i686_reject_pointer_arithmetic.zag --target i686 -o "$tmp/bad-pointer-arithmetic" --no-analyze >"$tmp/bad-pointer-arithmetic.log" 2>&1 &&
   grep -q "general pointer arithmetic is unsupported" "$tmp/bad-pointer-arithmetic.log" && [ ! -e "$tmp/bad-pointer-arithmetic" ]; then ok "general pointer arithmetic rejects before output"; else bad "pointer arithmetic rejection"; fi
if ! "$ZNC" tests/i686_reject_pointer_integer_cast.zag --target i686 -o "$tmp/bad-pointer-cast" --no-analyze >"$tmp/bad-pointer-cast.log" 2>&1 &&
   grep -q "pointer/integer casts are unsupported" "$tmp/bad-pointer-cast.log" && [ ! -e "$tmp/bad-pointer-cast" ]; then ok "pointer/integer cast rejects before output"; else bad "pointer/integer cast rejection"; fi
if ! "$ZNC" tests/i686_reject_pointer_index_signed.zag --target i686 -o "$tmp/bad-pointer-index-signed" --no-analyze >"$tmp/bad-pointer-index-signed.log" 2>&1 &&
   grep -q "raw pointer index must be usize on i686" "$tmp/bad-pointer-index-signed.log" && [ ! -e "$tmp/bad-pointer-index-signed" ]; then ok "signed pointer index rejects before ELF32 artifact"; else bad "signed pointer index rejection"; fi
if ! "$ZNC" tests/i686_reject_u64_range.zag --target i686 -o "$tmp/bad-u64-range" --no-analyze >"$tmp/bad-u64-range.log" 2>&1 &&
   grep -q "64-bit integer literal exceeds the unsigned i686 target range" "$tmp/bad-u64-range.log" && [ ! -e "$tmp/bad-u64-range" ]; then ok "out-of-range u64 literal rejects before output"; else bad "u64 literal range rejection"; fi
if ! "$ZNC" tests/i686_reject_i64_range.zag --target i686 -o "$tmp/bad-i64-range" --no-analyze >"$tmp/bad-i64-range.log" 2>&1 &&
   grep -q "i64 literal exceeds the signed 64-bit target range" "$tmp/bad-i64-range.log" && [ ! -e "$tmp/bad-i64-range" ]; then ok "out-of-range i64 literal rejects before output"; else bad "i64 literal range rejection"; fi
if ! "$ZNC" tests/i686_reject_u64_negative.zag --target i686 -o "$tmp/bad-u64-negative" --no-analyze >"$tmp/bad-u64-negative.log" 2>&1 &&
   grep -q "negative values do not implicitly convert to usize" "$tmp/bad-u64-negative.log" && [ ! -e "$tmp/bad-u64-negative" ]; then ok "negative implicit u64 conversion rejects before output"; else bad "negative u64 conversion rejection"; fi
if "$ZNC" tests/i686_write.zag --target i686 -o "$tmp/write" --no-analyze >/dev/null; then
  set +e; write_out=$(i686_exec "$tmp/write"); write_rc=$?; set -e
  if [ "$write_rc" -eq 42 ] && [ "$write_out" = "Z" ]; then ok "raw i386 write syscall preserves ABI and reports result"; else bad "write syscall output=$write_out status=$write_rc"; fi
else bad "raw i386 write program emits"; fi
if "$ZNC" tests/i686_large_frame.zag --target i686 -o "$tmp/large" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/large"; large_rc=$?; set -e
  if [ "$large_rc" -eq 42 ]; then ok "256-byte i386 frame preserves all local slots"; else bad "large-frame status=$large_rc"; fi
else bad "large-frame program emits"; fi
if "$ZNC" tests/i686_write_error.zag --target i686 -o "$tmp/writeerr" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/writeerr"; err_rc=$?; set -e
  if [ "$err_rc" -eq 42 ]; then ok "negative raw-syscall error path remains signed"; else bad "syscall error status=$err_rc"; fi
else bad "syscall error program emits"; fi
if "$ZNC" tests/i686_syscall_lifecycle.zag --target i686 -o "$tmp/syscall-lifecycle" --no-analyze >/dev/null; then
  set +e; lifecycle_out=$(i686_exec "$tmp/syscall-lifecycle"); lifecycle_rc=$?; set -e
  if [ "$lifecycle_rc" -eq 42 ] && [ "$lifecycle_out" = "7" ]; then ok "mmap2 write munmap lifecycle preserves the i386 syscall ABI"; else bad "syscall lifecycle output=$lifecycle_out status=$lifecycle_rc"; fi
else bad "i386 syscall lifecycle fixture emits"; fi
if "$ZNC" tests/i686_struct.zag --target i686 -o "$tmp/struct" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/struct"; struct_rc=$?; set -e
  if [ "$struct_rc" -eq 42 ]; then ok "basic sequential struct layout field load/store execute"; else bad "struct status=$struct_rc"; fi
else bad "basic struct program emits"; fi
if "$ZNC" tests/i686_print.zag --target i686 -o "$tmp/print" --no-analyze >/dev/null; then
  set +e; print_out=$(i686_exec "$tmp/print"); print_rc=$?; set -e
  if [ "$print_rc" -eq 42 ] && [ "$print_out" = "-2147483648" ]; then ok "formatted signed i32 print preserves ABI"; else bad "formatted print output=$print_out status=$print_rc"; fi
else bad "formatted print program emits"; fi
if "$ZNC" tests/i686_error_union.zag --target i686 -o "$tmp/errorunion" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/errorunion"; eu_rc=$?; set -e
  if [ "$eu_rc" -eq 42 ]; then ok "two-word scalar error ABI catch and try propagation execute"; else bad "error-union status=$eu_rc"; fi
else bad "scalar error-union program emits"; fi
if "$ZNC" tests/i686_reject_try_non_error.zag --target i686 -o "$tmp/bad-try" --no-analyze >/dev/null 2>&1; then
  bad "non-error try operand accepted"
elif [ -e "$tmp/bad-try" ]; then
  bad "non-error try rejection left an output artifact"
else
  ok "non-error try operand rejects before output"
fi
if "$ZNC" tests/i686_reject_catch_non_error.zag --target i686 -o "$tmp/bad-catch" --no-analyze >/dev/null 2>&1; then
  bad "non-error catch operand accepted"
elif [ -e "$tmp/bad-catch" ]; then
  bad "non-error catch rejection left an output artifact"
else
  ok "non-error catch operand rejects before output"
fi
if "$ZNC" tests/i686_struct_arg.zag --target i686 -o "$tmp/structarg" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/structarg"; sa_rc=$?; set -e
  if [ "$sa_rc" -eq 42 ]; then ok "SysV i386 by-value scalar struct argument executes"; else bad "struct argument status=$sa_rc"; fi
else bad "by-value struct argument emits"; fi
if "$ZNC" tests/i686_struct_return.zag --target i686 -o "$tmp/structret" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/structret"; sr_rc=$?; set -e
  if [ "$sr_rc" -eq 42 ]; then ok "SysV i386 hidden-sret aggregate return executes"; else bad "struct return status=$sr_rc"; fi
else bad "aggregate return emits"; fi
if ! "$ZNC" tests/i686_reject_struct_return.zag --target i686 -o "$tmp/badstructret" --no-analyze >"$tmp/badstructret.log" 2>&1 &&
   grep -q "aggregate returns require 32-bit scalar fields" "$tmp/badstructret.log" && [ ! -e "$tmp/badstructret" ]; then ok "unsupported aggregate return ABI rejects before output"; else bad "aggregate return rejection"; fi
if "$ZNC" tests/i686_slice_abi.zag --target i686 -o "$tmp/slice" --no-analyze >/dev/null; then
  set +e; slice_out=$(i686_exec "$tmp/slice"); slice_rc=$?; set -e
  if [ "$slice_rc" -eq 42 ] && [ "$slice_out" = "Zag" ]; then ok "two-word byte-slice argument return and print ABI executes"; else bad "slice ABI output=$slice_out status=$slice_rc"; fi
else bad "byte-slice ABI emits"; fi
if "$ZNC" tests/i686_slice_index.zag --target i686 -o "$tmp/slice-index" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/slice-index"; slice_index_rc=$?; set -e
  if [ "$slice_index_rc" -eq 42 ]; then ok "bounded byte-slice indexing executes"; else bad "slice index status=$slice_index_rc"; fi
else bad "bounded byte-slice indexing emits"; fi
if "$ZNC" tests/i686_slice_oob_negative.zag --target i686 -o "$tmp/slice-oob-negative" --no-analyze >/dev/null; then
  set +e; slice_oob_negative_out=$(i686_exec "$tmp/slice-oob-negative" 2>&1); slice_oob_negative_rc=$?; set -e
  if [ "$slice_oob_negative_rc" -eq 134 ] && [ "$slice_oob_negative_out" = "panic: slice index out of bounds" ]; then ok "negative slice index traps deterministically"; else bad "negative slice index output=$slice_oob_negative_out status=$slice_oob_negative_rc"; fi
else bad "negative slice bounds fixture emits"; fi
if "$ZNC" tests/i686_slice_oob_usize.zag --target i686 -o "$tmp/slice-oob-usize" --no-analyze >/dev/null; then
  set +e; slice_oob_usize_out=$(i686_exec "$tmp/slice-oob-usize" 2>&1); slice_oob_usize_rc=$?; set -e
  if [ "$slice_oob_usize_rc" -eq 134 ] && [ "$slice_oob_usize_out" = "panic: slice index out of bounds" ]; then ok "high-bit usize slice index traps deterministically"; else bad "usize slice index output=$slice_oob_usize_out status=$slice_oob_usize_rc"; fi
else bad "usize slice bounds fixture emits"; fi
if ! "$ZNC" tests/i686_reject_index_type.zag --target i686 -o "$tmp/bad-index-type" --no-analyze >"$tmp/bad-index-type.log" 2>&1 &&
   grep -q "index must be i32 or usize" "$tmp/bad-index-type.log" && [ ! -e "$tmp/bad-index-type" ]; then ok "non-integer slice index rejects before output"; else bad "slice index type rejection"; fi
if ! "$ZNC" tests/i686_reject_slice_mutation.zag --target i686 -o "$tmp/badslice" --no-analyze >"$tmp/badslice.log" 2>&1 &&
   grep -Eq "assignment target|byte slices expose only" "$tmp/badslice.log" && [ ! -e "$tmp/badslice" ]; then ok "unsupported byte-slice mutation rejects before output"; else bad "slice mutation rejection"; fi
if "$ZNC" tests/i686_import_runtime.zag --target i686 -o "$tmp/import-runtime" --no-analyze >/dev/null; then
  set +e; import_out=$(i686_exec "$tmp/import-runtime"); import_rc=$?; set -e
  if [ "$import_rc" -eq 42 ] && [ "$import_out" = "A" ]; then ok "imports escaped strings mmap allocation pointer access and munmap execute"; else bad "import/runtime output=$import_out status=$import_rc"; fi
else bad "imported allocation runtime emits"; fi
if "$ZNC" tests/i686_alloc_failure.zag --target i686 -o "$tmp/alloc-failure" --no-analyze >/dev/null; then
  set +e; i686_exec "$tmp/alloc-failure"; alloc_rc=$?; set -e
  if [ "$alloc_rc" -eq 42 ]; then ok "mmap allocation failure returns a checkable null pointer"; else bad "allocation failure status=$alloc_rc"; fi
else bad "allocation failure path emits"; fi
echo "i686 minimal: pass=$pass fail=$fail"
test "$fail" -eq 0
