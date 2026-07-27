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
# The authoritative gate uses the same bounded no-swap bootstrap profile that
# proves the compiler on this shared workstation.  Without an explicit cap,
# bootstrap's protective workstation reserve can reject a healthy build merely
# because unrelated desktop processes consume available RAM.
run_gate "bootstrap/rebuild" env ZAG_BOOTSTRAP_MEMORY_MAX_BYTES=1073741824 ./bootstrap.sh
run_gate "v1 semantic compatibility" bash tests/run_semantics.sh
run_gate "v1 native execution" bash tests/run_native.sh
run_gate "shared declared-type authority" bash tests/run_typed_authority.sh
run_gate "v2 edition boundary" bash tests/run_v2_edition.sh
run_gate "unsafe lexical and raw-pointer boundary" bash tests/run_v2_edition.sh
run_gate "try-wrapped borrow identity" bash tests/run_v2_try_borrow.sh
run_gate "mutation-aware aggregate provenance" bash tests/run_v2_aggregate_provenance.sh
run_gate "fixed-buffer checked runtime authority" bash tests/run_fixed_buffer_runtime.sh
run_gate "retained arena allocator authority" bash tests/run_arena_allocator.sh
run_gate "v2 atomic i64 operations" bash tests/run_v2_atomic_exchange.sh
run_gate "v2 atomic load/store memory-order validation" bash tests/run_v2_atomic_orders.sh
run_gate "compiler-reserved AtomicI64 storage" bash tests/run_v2_atomic_storage.sh
run_gate "validated Linux futex wait/wake boundary" bash tests/run_x86_atomic_futex.sh
run_gate "validated Linux thread spawn/join boundary" bash tests/run_x86_thread_spawn.sh
run_gate "fail-closed indirect effect boundary" bash tests/run_v2_effect_adversarial.sh
run_gate "fail-closed kernel host-effect boundary" bash tests/run_v2_kernel_effects.sh
run_gate "v2 option rejection" bash tests/run_v2_option_rejection.sh
run_gate "malformed-input crash corpus" bash tests/run_crash_corpus.sh
run_gate "deterministic fuzz smoke" bash tests/run_fuzz_smoke.sh
run_gate "hard errors leave no artifact" bash tests/run_no_artifact_errors.sh
run_gate "documentation consistency" bash tests/run_docs_consistency.sh
run_gate "generated support matrix" bash tests/run_v2_support_matrix.sh
run_gate "WASM emission regression (no runtime)" bash tests/run_native_wasm.sh
run_gate "GPU frontend validation (not execution)" bash tests/run_native_gpu.sh
run_gate "dynamic ELF ABI boundary" bash tests/run_dynamic_abi.sh
run_gate "x86-64 C ABI object export boundary" bash tests/run_x86_64_cabi_object.sh
run_gate "validated x86 POPCNT intrinsic" bash tests/run_x86_popcount.sh
run_gate "validated x86 BMI1 ANDN intrinsic" bash tests/run_x86_andn.sh
run_gate "validated x86 trailing-zeros intrinsic" bash tests/run_x86_trailing_zeros.sh
run_gate "validated x86 byte-swap intrinsic" bash tests/run_x86_byte_swap.sh
run_gate "validated x86 leading-zeros intrinsic" bash tests/run_x86_leading_zeros.sh
run_gate "validated x86 prefetch intrinsic" bash tests/run_x86_prefetch.sh
run_gate "validated x86 volatile MMIO widths" bash tests/run_x86_volatile_widths.sh
run_gate "bounded MMIO-region authority" bash tests/run_mmio_region.sh
run_gate "validated x86 SSE2 SIMD add" bash tests/run_x86_simd_add_i32x4.sh
run_gate "validated x86 SSE2 SIMD subtract" bash tests/run_x86_simd_sub_i32x4.sh

unsupported "pointer and memory model" "raw pointer categories and lexical checks exist, but provenance/alignment/lifetime instrumentation is incomplete"
unsupported "allocator and reclamation" "opaque checked SystemAllocator capabilities and bounded retained fixed-buffer/arena regions exist, but custom/debug allocators and a general lifetime model are incomplete"
unsupported "volatile/MMIO" "checked native 8/16/32-bit and word transactions plus bounded byte MmioRegion access exist, but physical device validation, opaque hardware authority, and the complete MMIO contract are incomplete"
unsupported "atomics and concurrency" "compiler-reserved unsafe AtomicI64 receiver operations, raw Linux i32 futex wait/wake, literal-validated load/store/RMW/CAS/fence orders, and a direct captureless join-only Linux thread slice with one copied i64 worker argument exist, but language-wide fence semantics, general thread arguments/detach, litmus evidence, and a v2 concurrency model remain incomplete"
unsupported "C ABI and dynamic linking" "checked v2 @cabi scalar plus bounded f64 dynamic imports, a direct captureless scalar/pointer callback, and scalar @cabi_export ET_REL objects with self-contained output or direct PLT32 import relocations exist, but general bidirectional ABI, relocation/static archive/shared-object conformance, and unload/lifetime contracts are incomplete"
unsupported "CPU intrinsics/SIMD/inline assembly" "validated x86 scalar intrinsics and bounded unsafe SSE2 i32x4 add/subtract exist, but vector types/ABI, additional SIMD, inline-assembly constraints/clobbers, and full target-feature/effect checking are incomplete"
unsupported "effect adversarial suite" "opaque aggregate/computed indirect calls and host effects in @kernel now fail closed, but verified aggregate rows, device-helper propagation, and distinct Atomic/FFI/GPU effect models remain incomplete"
unsupported "physical GPU execution" "no runtime enumerate/allocate/dispatch/readback path"
unsupported "sanitizers" "bounded native --sanitize=memory has exact requested-length bounds, deterministic free poisoning, and a coarse trailing guard page for dedicated large allocations, but red zones, allocation-site reports, and custom allocator coverage are incomplete"
unsupported "documentation verification map" "verification matrix exists but records incomplete required capabilities"

echo "════ v2-release pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
