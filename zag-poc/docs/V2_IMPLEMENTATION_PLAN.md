# Zag v2 implementation plan

1. Add edition selection and tests that edition-2026 rejects every v2 token.
2. Introduce one typed semantic IR and route native, GPU, WASM, and effects
   through it; remove comment/skip-on-unsupported lowering paths.
3. Implement unsafe boundary and raw-pointer categories with negative tests.
4. Implement layout, allocator, checked/unchecked slice, volatile/MMIO, and
   debug allocator before atomics or FFI.
5. Implement atomics/concurrency and litmus/stress tests with timeouts.
6. Implement C ABI/object/shared-library support with bidirectional execution.
7. Implement CPU intrinsics/SIMD/asm with machine-code assertions.
8. Build Vulkan execution path and tiny CPU-vs-GPU tests; do not call MLIR a
   backend.
9. Add fuzz/differential/sanitizer suites and a single `run_v2_release_gate.sh`
   that emits pass/fail/skip reasons and a generated support matrix.

Each step requires specification mapping, positive and negative compile tests,
runtime tests where relevant, and an honest unsupported status before the next
step is claimed complete.
