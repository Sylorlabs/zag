#!/usr/bin/env bash
# Authoritative v2 release gate.
#
# This gate is deliberately fail-closed: every required category is printed as
# PASS, FAIL, or UNSUPPORTED with a reason.  An unsupported required category is
# a failure, never a silent omission or a release pass.
set -u
cd "$(dirname "$0")/.."

pass=0
fail=0

pass_case() { echo "  ok  $1"; pass=$((pass + 1)); }
fail_case() { echo "  XX  $1"; fail=$((fail + 1)); }
run_gate() {
  local name=$1; shift
  if "$@" >/tmp/zag-v2-gate.log 2>&1; then
    pass_case "$name"
  else
    fail_case "$name"
    sed -n '1,10p' /tmp/zag-v2-gate.log
  fi
}
unsupported() {
  fail_case "$1 — UNSUPPORTED: $2"
}

echo "── Zag v2 release gate ──"
run_gate "bootstrap/rebuild" ./bootstrap.sh
run_gate "v1 semantic compatibility" bash tests/run_semantics.sh
run_gate "v1 native execution" bash tests/run_native.sh
run_gate "v2 edition boundary" bash tests/run_v2_edition.sh
run_gate "WASM regression" bash tests/run_native_wasm.sh
run_gate "GPU frontend validation (not execution)" bash tests/run_native_gpu.sh

unsupported "unsafe boundaries" "no v2 unsafe AST, type rules, or lowering"
unsupported "pointer and memory model" "no v2 provenance/alignment/lifetime implementation"
unsupported "allocator and reclamation" "no specified v2 allocator API or debug allocator"
unsupported "volatile/MMIO" "no language-level volatile operations"
unsupported "atomics and concurrency" "no public atomic API or v2 memory model implementation"
unsupported "C ABI and dynamic linking" "no bidirectional C ABI/shared-library execution suite"
unsupported "CPU intrinsics/SIMD/inline assembly" "no v2 operand/clobber checked asm interface"
unsupported "effect adversarial suite" "no Unsafe/Atomic/FFI/GPU effect propagation"
unsupported "physical GPU execution" "no runtime enumerate/allocate/dispatch/readback path"
unsupported "sanitizers and fuzzing" "no maintained v2 fuzz corpus or sanitizer modes"
unsupported "documentation verification map" "docs/V2_FINAL_VERIFICATION.md absent"

echo "════ v2-release pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
