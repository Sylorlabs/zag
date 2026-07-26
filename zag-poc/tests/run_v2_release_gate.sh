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
run_gate "shared declared-type authority" bash tests/run_typed_authority.sh
run_gate "v2 edition boundary" bash tests/run_v2_edition.sh
run_gate "unsafe lexical and raw-pointer boundary" bash tests/run_v2_edition.sh
run_gate "mutation-aware aggregate provenance" bash tests/run_v2_aggregate_provenance.sh
run_gate "v2 atomic i64 operations" bash tests/run_v2_atomic_exchange.sh
run_gate "v2 atomic load/store memory-order validation" bash tests/run_v2_atomic_orders.sh
run_gate "fail-closed indirect effect boundary" bash tests/run_v2_effect_adversarial.sh
run_gate "v2 option rejection" bash tests/run_v2_option_rejection.sh
run_gate "malformed-input crash corpus" bash tests/run_crash_corpus.sh
run_gate "deterministic fuzz smoke" bash tests/run_fuzz_smoke.sh
run_gate "hard errors leave no artifact" bash tests/run_no_artifact_errors.sh
run_gate "documentation consistency" bash tests/run_docs_consistency.sh
run_gate "generated support matrix" bash tests/run_v2_support_matrix.sh
run_gate "WASM emission regression (no runtime)" bash tests/run_native_wasm.sh
run_gate "GPU frontend validation (not execution)" bash tests/run_native_gpu.sh
run_gate "dynamic ELF ABI boundary" bash tests/run_dynamic_abi.sh
run_gate "validated x86 POPCNT intrinsic" bash tests/run_x86_popcount.sh
run_gate "validated x86 BMI1 ANDN intrinsic" bash tests/run_x86_andn.sh
run_gate "validated x86 trailing-zeros intrinsic" bash tests/run_x86_trailing_zeros.sh
run_gate "validated x86 byte-swap intrinsic" bash tests/run_x86_byte_swap.sh
run_gate "validated x86 leading-zeros intrinsic" bash tests/run_x86_leading_zeros.sh
run_gate "validated x86 prefetch intrinsic" bash tests/run_x86_prefetch.sh
run_gate "validated x86 volatile MMIO widths" bash tests/run_x86_volatile_widths.sh
run_gate "validated x86 SSE2 SIMD add" bash tests/run_x86_simd_add_i32x4.sh

unsupported "pointer and memory model" "raw pointer categories and lexical checks exist, but provenance/alignment/lifetime instrumentation is incomplete"
unsupported "allocator and reclamation" "checked native SystemAllocator handles now carry runtime allocator identity, but opaque language capabilities, custom/arena/fixed-buffer and debug allocators, and a general lifetime model are incomplete"
unsupported "volatile/MMIO" "checked native 8/16/32-bit and word transactions exist, but physical device validation, address capabilities, and the complete MMIO contract are incomplete"
unsupported "atomics and concurrency" "fixed unsafe x86-64 i64 operations plus literal-validated load/store orders exist, but atomic storage, orders on RMW/CAS/fences, threads, and a v2 concurrency model remain incomplete"
unsupported "C ABI and dynamic linking" "checked v2 @cabi scalar dynamic imports, ELF loading, and a direct captureless scalar/pointer callback to libc qsort exist, but general bidirectional ABI, exports, shared-object conformance, and unload/lifetime contracts are incomplete"
unsupported "CPU intrinsics/SIMD/inline assembly" "validated x86 scalar intrinsics and bounded unsafe SSE2 i32x4 add exist, but vector types/ABI, additional SIMD, inline-assembly constraints/clobbers, and full target-feature/effect checking are incomplete"
unsupported "effect adversarial suite" "opaque aggregate/computed indirect calls now fail closed, but verified aggregate rows and Atomic/FFI/GPU effect models remain incomplete"
unsupported "physical GPU execution" "no runtime enumerate/allocate/dispatch/readback path"
unsupported "sanitizers" "bounded native --sanitize=memory exists with deterministic free poisoning, but red zones, guard pages, allocation-site reports, and custom allocator coverage are incomplete"
unsupported "documentation verification map" "verification matrix exists but records incomplete required capabilities"

echo "════ v2-release pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
