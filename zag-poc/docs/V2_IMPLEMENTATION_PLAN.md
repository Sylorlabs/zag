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

## Sequencing and exit evidence

| Milestone | Entry condition | Exit evidence | Current status |
|---|---|---|---|
| 0. Audit/baseline | dirty-tree-safe snapshot and all named v1 gates | audit, preserved logs, contradiction inventory | COMPLETE as a forensic baseline only |
| 1. Edition/spec boundary | frozen v1 preserved | v1 rejects v2 syntax/options; v2 unsupported syntax fails closed; normative drafts | PARTIAL: gate and drafts exist |
| 2. Typed semantic authority | edition boundary | one typed IR consumed by effects and every backend; no skip/comment lowering | PARTIAL: shared declaration and conservative expression-category checks gate every target; complete expression typing and backend lowering still use local string inference |
| 3. Unsafe/pointer vertical slice | typed authority | lexical unsafe, pointer categories/provenance, positive driver case and safe negative cases | PARTIAL: dedicated unsafe AST nodes, unsafe functions/direct-call checks, the `Unsafe` effect, cross-target lowering, qualified/nullable pointer categories, explicit nullable unwrapping, and address-space cast separation are implemented; safe dereference and const mutation fail closed; source-span auditing, indirect-call propagation, provenance identity, bounds, and alignment instrumentation remain |
| 4. Memory/allocator/volatile | pointer slice | layout goldens, allocation/reclamation execution, debug checks, MMIO codegen checks | PARTIAL: typed edition-2027 ownership flow follows direct local aliases, rejects double/use-after-free, rejects uncontracted ownership escapes, requires release/return on every control-flow path, rejects tested callee-frame addresses returned directly or through named aggregate aliases, and supports only root-native zero-initialized primitive scalar BSS globals; allocator API, pointer/aggregate global ownership/provenance, mutation-aware aggregate provenance, dynamic lifetime instrumentation, layout, and volatile/MMIO remain |
| 5. Atomics/concurrency | memory rules | lowering inspection, litmus/stress tests with timeouts, realtime rejections | NOT STARTED |
| 6. ABI/linking | fixed layouts | C-to-Zag and Zag-to-C executable suite, object/shared/dynamic tests | NOT STARTED |
| 7. CPU control | unsafe/target model | asm operand/clobber validation and machine-code tests | NOT STARTED |
| 8. GPU runtime | typed device semantics | bounded physical dispatch, readback, CPU comparison, cleanup and timeout test | NOT STARTED |
| 9. Hardening/release | all prior milestones | fuzz/differential/sanitizers/benchmarks and zero required release failures | NOT STARTED |

The current release gate and generated support matrix are control-plane
infrastructure, not substitutes for any milestone's implementation evidence.

## Non-negotiable implementation constraints

- A v2 parser/lowering change must be edition-gated before it can alter v1.
- A capability is not marked supported until a negative test proves misuse is
  rejected and a runtime test proves the supported target behavior where
  execution is claimed.
- GPU compilation, validation, target-binary production, runtime loading,
  dispatch, result validation, and synchronization are separate milestones.
- Optional C/Vulkan/toolchain modes may use external tooling only when selected;
  `./bootstrap.sh` and default static x86-64 native output retain no such
  dependency.
