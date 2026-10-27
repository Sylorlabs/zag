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
# Concurrent qualification runs must not overwrite each other's failing-suite
# evidence. A fixed /tmp filename could print another runner's diagnostics.
if ! gate_log=$(mktemp "${TMPDIR:-/tmp}/zag-v2-gate.XXXXXX"); then
  echo 'v2 release gate: unable to create isolated diagnostic log' >&2
  exit 2
fi
trap 'rm -f -- "$gate_log"' EXIT

pass_case() { echo "  ok  $1"; pass=$((pass + 1)); }
fail_case() { echo "  XX  $1"; fail=$((fail + 1)); }
run_gate() {
  local name=$1; shift
  if "$@" >"$gate_log" 2>&1; then
    pass_case "$name"
  else
    fail_case "$name"
    sed -n '1,10p' "$gate_log"
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
run_gate "v2 checked signed/unsigned integer narrowing" bash tests/run_v2_checked_narrowing.sh
run_gate "v2 shift count checks and v1 compatibility" bash tests/run_v2_shift_counts.sh
run_gate "v2 integer zero-divisor diagnostics and compatibility" bash tests/run_v2_division_zero.sh
run_gate "v2 signed division overflow and edition-2026 compatibility" bash tests/run_v2_signed_division_overflow.sh
run_gate "unsafe lexical and raw-pointer boundary" bash tests/run_v2_edition.sh
run_gate "try-wrapped borrow identity" bash tests/run_v2_try_borrow.sh
run_gate "mutation-aware aggregate provenance" bash tests/run_v2_aggregate_provenance.sh
run_gate "resource contract syntax and identity" bash tests/run_resource_contract_syntax.sh
run_gate "affine resources and retained views" bash tests/run_resource_affine.sh
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
run_gate "ARM64 C ABI object export boundary" bash tests/run_arm64_cabi_object.sh
run_gate "x86-64 explicit C struct representation" bash tests/run_repr_c_layout.sh
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
run_gate "validated x86 SSE2 SIMD bitwise" bash tests/run_x86_simd_bitwise_i32x4.sh

unsupported "pointer and memory model" "checked ordinary allocations quarantine address reuse and raw pointer categories plus lexical checks exist, but identity-carrying provenance, untracked allocator coverage, and general reference lifetimes remain incomplete"
unsupported "allocator and reclamation" "opaque checked SystemAllocator capabilities and bounded retained fixed-buffer/arena regions exist, but custom/debug allocators and a general lifetime model are incomplete"
unsupported "volatile/MMIO" "checked native 8/16/32-bit and word transactions plus bounded byte MmioRegion access exist, but physical device validation, opaque hardware authority, and the complete MMIO contract are incomplete"
unsupported "atomics and concurrency" "compiler-reserved unsafe AtomicI64 receiver operations, cross-target raw i32 wait/wake and direct captureless join-only thread slices on Linux x86-64 and Apple Silicon macOS, plus literal-validated load/store/RMW/CAS/fence orders exist, but language-wide fence semantics, general thread arguments/detach, litmus evidence, and a v2 concurrency model remain incomplete"
unsupported "C ABI and dynamic linking" "checked v2 @cabi scalar plus bounded f64 dynamic imports, a direct captureless scalar/pointer callback, and scalar @cabi_export ET_REL objects with self-contained output or direct PLT32 import relocations exist, but general bidirectional ABI, relocation/static archive/shared-object conformance, and unload/lifetime contracts are incomplete"
unsupported "CPU intrinsics/SIMD/inline assembly" "five compiler-owned scalar intrinsics execute on native x86-64 and Apple Silicon, alongside cross-target baseline prefetch and bounded unsafe i32x4 arithmetic/bitwise operations on x86-64 SSE2 and Apple-Silicon AArch64 Advanced SIMD, but vector types/ABI, broader SIMD, inline-assembly constraints/clobbers, and full target-feature/effect checking are incomplete"
unsupported "physical GPU execution" "bounded loader-backed Vulkan/OpenGL/OpenCL execution and first-class Apple gpu-metal fill/depth/blend dispatch/readback exist, but the complete typed v2 GPU capability/runtime model and Linux native-DRM submission certification remain incomplete"
unsupported "sanitizers" "bounded native --sanitize=memory has exact requested-length bounds plus 16-byte checked trailing red zones and deterministic quarantine poisoning for small allocations on x86-64/ARM64; dedicated large sanitizer allocations also use coarse trailing guard pages and pre-unmap payload poisoning, with a physically verified 16 KiB guard on Apple Silicon macOS, but allocation-site reports, stack/global instrumentation, and custom allocator coverage are incomplete"
unsupported "documentation verification map" "verification matrix exists but records incomplete required capabilities"

echo "════ v2-release pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
