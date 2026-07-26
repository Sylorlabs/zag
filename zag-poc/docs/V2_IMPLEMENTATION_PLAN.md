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
| 4. Memory/allocator/volatile | pointer slice | layout goldens, allocation/reclamation execution, debug checks, MMIO codegen checks | PARTIAL: typed edition-2027 ownership flow follows direct local aliases, rejects double/use-after-free, rejects uncontracted ownership escapes, requires release/return on every control-flow path, rejects tested callee-frame addresses returned directly or through named aggregate aliases, and supports root-native zero-initialized one-word primitive-scalar and raw-pointer BSS globals. Checked native `SystemAllocator` provides fallible allocate/zeroed/resize/deallocate handles with exact capacity, alignment, runtime allocator identity, and generation validation. Native x86-64 volatile/MMIO now has checked exact-width `u8`/`u16`/`u32`/word transactions with width-specific alignment and opcode evidence. Aggregate global ownership/provenance, a general dynamic lifetime model, layout, physical device validation, and a complete MMIO capability contract remain |
| 5. Atomics/concurrency | memory rules | lowering inspection, litmus/stress tests with timeouts, realtime rejections | PARTIAL: edition-2027 fixed i64 atomics have unsafe typed checks, unconditional null/alignment traps, checked allocation probing, and locked x86-64 opcode evidence; literal-validated `@atomicLoad64Order`/`@atomicStore64Order` cover the bounded load/store order subset; storage types, RMW/CAS/fence order selection, thread APIs, and litmus/stress coverage remain |
| 6. ABI/linking | fixed layouts | C-to-Zag and Zag-to-C executable suite, object/shared/dynamic tests | PARTIAL: native x86-64 dynamic ELF loader and i686 object/archive authorities have executable evidence; a direct captureless named scalar/pointer Zag callback executes through libc `qsort`, while general bidirectional v2 C ABI, exports, shared-object conformance, and unload/lifetime contracts remain |
| 7. CPU control | unsafe/target model | asm operand/clobber validation and machine-code tests | PARTIAL: validated x86 POPCNT, BMI1 ANDN, trailing-zero, byte-swap, leading-zero, baseline prefetch, and bounded unsafe SSE2 `i32x4` add paths have machine-code/runtime evidence; vector types/ABI, additional SIMD, inline asm constraints, and full target-feature/effect contracts remain |
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
