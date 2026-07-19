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
if ! "$ZNC" tests/i686_reject_abi.zag --target i686 -o "$tmp/badabi" --no-analyze >"$tmp/badabi.log" 2>&1 &&
   grep -q "not a supported 32-bit scalar" "$tmp/badabi.log" && [ ! -e "$tmp/badabi" ]; then ok "unsupported floating ABI rejects before output"; else bad "unsupported ABI rejection"; fi
if "$ZNC" tests/i686_pointer.zag --target i686 -o "$tmp/pointer" --no-analyze >/dev/null; then
  set +e; "$tmp/pointer"; ptr_rc=$?; set -e
  if [ "$ptr_rc" -eq 42 ]; then ok "32-bit usize pointer address dereference and store execute"; else bad "pointer execution status=$ptr_rc"; fi
else bad "32-bit pointer program emits"; fi
echo "i686 minimal: pass=$pass fail=$fail"
test "$fail" -eq 0
