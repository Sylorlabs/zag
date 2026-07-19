#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-i686.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok(){ echo "  ok  $1"; pass=$((pass+1)); }
bad(){ echo "  XX  $1"; fail=$((fail+1)); }

if "$ZNC" tests/i686_literal.zag --target i686 -o "$tmp/a.out" --no-analyze >/dev/null; then ok "literal main emits"; else bad "literal main emits"; fi
class=$(od -An -tu1 -j4 -N1 "$tmp/a.out" | tr -d ' ')
machine=$(od -An -tu1 -j18 -N2 "$tmp/a.out" | xargs)
if [ "$class" = 1 ] && [ "$machine" = "3 0" ]; then ok "artifact is ELF32 EM_386"; else bad "ELF32 identity"; fi
shnum=$(od -An -tu1 -j48 -N1 "$tmp/a.out" | tr -d ' ')
if [ "$shnum" = 6 ]; then ok "ELF32 section table is present"; else bad "ELF32 section table"; fi
if command -v readelf >/dev/null 2>&1; then
  if readelf -S -s "$tmp/a.out" 2>/dev/null | grep -q '\.debug_line' && readelf -s "$tmp/a.out" 2>/dev/null | grep -q ' main$'; then ok "reference reader sees text symbols and debug line"; else bad "readelf metadata"; fi
fi
if "$ZNC" tests/i686_literal.zag --target i686 --emit-obj -o "$tmp/main.o" --no-analyze >/dev/null; then
  etype=$(od -An -tu1 -j16 -N1 "$tmp/main.o" | tr -d ' ')
  if [ "$etype" = 1 ]; then ok "ELF32 ET_REL object emits"; else bad "ELF32 relocatable type"; fi
  if command -v readelf >/dev/null 2>&1 && readelf -r "$tmp/main.o" 2>/dev/null | grep -q 'R_386_PC32.*main'; then ok "R_386_PC32 startup relocation is published"; else bad "ELF32 relocation metadata"; fi
  if command -v ld >/dev/null 2>&1 && ld -m elf_i386 -o "$tmp/linked" "$tmp/main.o" >/dev/null 2>&1; then
    set +e; "$tmp/linked"; linked_rc=$?; set -e
    if [ "$linked_rc" -eq 42 ]; then ok "reference linker resolves relocatable object"; else bad "linked object status=$linked_rc"; fi
  fi
else bad "ELF32 object emits"; fi
if "$ZNC" tests/i686_literal.zag --target i686 --emit-static -o "$tmp/libmain.a" --no-analyze >/dev/null &&
   "$ZNC" "$tmp/libmain.a" --target i686 --link-i686 -o "$tmp/pure-linked" --no-analyze >/dev/null; then
  set +e; "$tmp/pure-linked"; pure_rc=$?; set -e
  if [ "$pure_rc" -eq 42 ]; then ok "pure Zag archive writer and ELF32 linker execute"; else bad "pure linked status=$pure_rc"; fi
else bad "pure Zag static archive/link path"; fi
set +e
"$tmp/a.out"; rc=$?
set -e
if [ "$rc" -eq 42 ]; then ok "native kernel executes i386 int-0x80 exit";
elif command -v qemu-i386 >/dev/null 2>&1; then
  set +e; qemu-i386 "$tmp/a.out"; rc=$?; set -e
  if [ "$rc" -eq 42 ]; then ok "qemu-i386 executes int-0x80 exit"; else bad "i386 execution"; fi
else bad "i386 execution unavailable"; fi
if ! "$ZNC" tests/i686_reject_pointer.zag --target i686 -o "$tmp/bad" --no-analyze >"$tmp/reject.log" 2>&1 &&
   grep -q "unsupported construct" "$tmp/reject.log" && [ ! -e "$tmp/bad" ]; then ok "pointer/local constructs reject before output"; else bad "unsupported construct rejection"; fi
if "$ZNC" tests/i686_i32_ir.zag --target i686 -o "$tmp/ir" --no-analyze >/dev/null; then
  set +e; "$tmp/ir"; ir_rc=$?; set -e
  if [ "$ir_rc" -eq 42 ]; then ok "i32 IR locals assignment add/sub execute"; else bad "i32 IR execution status=$ir_rc"; fi
else bad "i32 IR emits"; fi
if "$ZNC" tests/i686_control_flow.zag --target i686 -o "$tmp/cf" --no-analyze >/dev/null; then
  set +e; "$tmp/cf"; cf_rc=$?; set -e
  if [ "$cf_rc" -eq 42 ]; then ok "comparisons if while break continue execute"; else bad "control-flow execution status=$cf_rc"; fi
else bad "control-flow IR emits"; fi
if "$ZNC" tests/i686_calls.zag --target i686 -o "$tmp/calls" --no-analyze >/dev/null; then
  set +e; "$tmp/calls"; call_rc=$?; set -e
  if [ "$call_rc" -eq 42 ]; then ok "cdecl-like i32 arguments returns and caller cleanup execute"; else bad "call ABI execution status=$call_rc"; fi
else bad "multiple i32 functions emit"; fi
if "$ZNC" tests/i686_f32.zag --target i686 -o "$tmp/f32" --no-analyze >/dev/null; then
  set +e; "$tmp/f32"; f32_rc=$?; set -e
  if [ "$f32_rc" -eq 42 ]; then ok "SysV i386 four-byte f32 arguments arithmetic locals and x87 return execute"; else bad "f32 ABI status=$f32_rc"; fi
else bad "f32 ABI program emits"; fi
if ! "$ZNC" tests/i686_reject_i64.zag --target i686 -o "$tmp/badi64" --no-analyze >"$tmp/badi64.log" 2>&1 &&
   grep -Eq "return i32|supported i386 scalar" "$tmp/badi64.log" && [ ! -e "$tmp/badi64" ]; then ok "64-bit scalar assumptions reject before output"; else bad "i64 ABI rejection"; fi
if "$ZNC" tests/i686_float.zag --target i686 -o "$tmp/float" --no-analyze >/dev/null; then
  set +e; "$tmp/float"; float_rc=$?; set -e
  if [ "$float_rc" -eq 42 ]; then ok "SysV i386 f64 stack arguments x87 return and arithmetic execute"; else bad "f64 ABI status=$float_rc"; fi
else bad "f64 ABI program emits"; fi
if "$ZNC" tests/i686_pointer.zag --target i686 -o "$tmp/pointer" --no-analyze >/dev/null; then
  set +e; "$tmp/pointer"; ptr_rc=$?; set -e
  if [ "$ptr_rc" -eq 42 ]; then ok "32-bit usize pointer address dereference and store execute"; else bad "pointer execution status=$ptr_rc"; fi
else bad "32-bit pointer program emits"; fi
if "$ZNC" tests/i686_write.zag --target i686 -o "$tmp/write" --no-analyze >/dev/null; then
  set +e; write_out=$("$tmp/write"); write_rc=$?; set -e
  if [ "$write_rc" -eq 42 ] && [ "$write_out" = "Z" ]; then ok "raw i386 write syscall preserves ABI and reports result"; else bad "write syscall output=$write_out status=$write_rc"; fi
else bad "raw i386 write program emits"; fi
if "$ZNC" tests/i686_large_frame.zag --target i686 -o "$tmp/large" --no-analyze >/dev/null; then
  set +e; "$tmp/large"; large_rc=$?; set -e
  if [ "$large_rc" -eq 42 ]; then ok "256-byte i386 frame preserves all local slots"; else bad "large-frame status=$large_rc"; fi
else bad "large-frame program emits"; fi
if "$ZNC" tests/i686_write_error.zag --target i686 -o "$tmp/writeerr" --no-analyze >/dev/null; then
  set +e; "$tmp/writeerr"; err_rc=$?; set -e
  if [ "$err_rc" -eq 42 ]; then ok "negative raw-syscall error path remains signed"; else bad "syscall error status=$err_rc"; fi
else bad "syscall error program emits"; fi
if "$ZNC" tests/i686_struct.zag --target i686 -o "$tmp/struct" --no-analyze >/dev/null; then
  set +e; "$tmp/struct"; struct_rc=$?; set -e
  if [ "$struct_rc" -eq 42 ]; then ok "basic sequential struct layout field load/store execute"; else bad "struct status=$struct_rc"; fi
else bad "basic struct program emits"; fi
if "$ZNC" tests/i686_print.zag --target i686 -o "$tmp/print" --no-analyze >/dev/null; then
  set +e; print_out=$("$tmp/print"); print_rc=$?; set -e
  if [ "$print_rc" -eq 42 ] && [ "$print_out" = "-2147483648" ]; then ok "formatted signed i32 print preserves ABI"; else bad "formatted print output=$print_out status=$print_rc"; fi
else bad "formatted print program emits"; fi
if "$ZNC" tests/i686_error_union.zag --target i686 -o "$tmp/errorunion" --no-analyze >/dev/null; then
  set +e; "$tmp/errorunion"; eu_rc=$?; set -e
  if [ "$eu_rc" -eq 42 ]; then ok "two-word scalar error ABI catch and try propagation execute"; else bad "error-union status=$eu_rc"; fi
else bad "scalar error-union program emits"; fi
if "$ZNC" tests/i686_struct_arg.zag --target i686 -o "$tmp/structarg" --no-analyze >/dev/null; then
  set +e; "$tmp/structarg"; sa_rc=$?; set -e
  if [ "$sa_rc" -eq 42 ]; then ok "SysV i386 by-value scalar struct argument executes"; else bad "struct argument status=$sa_rc"; fi
else bad "by-value struct argument emits"; fi
if "$ZNC" tests/i686_struct_return.zag --target i686 -o "$tmp/structret" --no-analyze >/dev/null; then
  set +e; "$tmp/structret"; sr_rc=$?; set -e
  if [ "$sr_rc" -eq 42 ]; then ok "SysV i386 hidden-sret aggregate return executes"; else bad "struct return status=$sr_rc"; fi
else bad "aggregate return emits"; fi
if ! "$ZNC" tests/i686_reject_struct_return.zag --target i686 -o "$tmp/badstructret" --no-analyze >"$tmp/badstructret.log" 2>&1 &&
   grep -q "aggregate returns require 32-bit scalar fields" "$tmp/badstructret.log" && [ ! -e "$tmp/badstructret" ]; then ok "unsupported aggregate return ABI rejects before output"; else bad "aggregate return rejection"; fi
if "$ZNC" tests/i686_slice_abi.zag --target i686 -o "$tmp/slice" --no-analyze >/dev/null; then
  set +e; slice_out=$("$tmp/slice"); slice_rc=$?; set -e
  if [ "$slice_rc" -eq 42 ] && [ "$slice_out" = "Zag" ]; then ok "two-word byte-slice argument return and print ABI executes"; else bad "slice ABI output=$slice_out status=$slice_rc"; fi
else bad "byte-slice ABI emits"; fi
if ! "$ZNC" tests/i686_reject_slice_mutation.zag --target i686 -o "$tmp/badslice" --no-analyze >"$tmp/badslice.log" 2>&1 &&
   grep -Eq "assignment target|byte slices expose only" "$tmp/badslice.log" && [ ! -e "$tmp/badslice" ]; then ok "unsupported byte-slice mutation rejects before output"; else bad "slice mutation rejection"; fi
echo "i686 minimal: pass=$pass fail=$fail"
test "$fail" -eq 0
