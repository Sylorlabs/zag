# Zag v2 final verification matrix

Status: **not a release verification**.  This matrix is deliberately checked
into the repository before implementation is complete so that a missing test
or runtime proof cannot be mistaken for support.  `UNSUPPORTED` entries are
release-gate failures.  `FRONTEND ONLY` means compilation artefacts are
produced, not that a target executes them.

The authoritative command is `bash tests/run_v2_release_gate.sh`.  At the
time this matrix was written it must fail: it records the unimplemented v2
surface rather than granting a premature green release.

| Capability | Specification | Implementation evidence | Positive evidence | Negative evidence | Runtime evidence | Status |
|---|---|---|---|---|---|---|
| Edition boundary | `V2_LANGUAGE_SPEC.md` §1 | `selfhost/v2_edition.zag`; `native/znc.zag` | `tests/run_v2_edition.sh`: v1 sources continue to compile | same test rejects v2 words in edition 2026 and edition 2027 words fail closed | native compiler exits nonzero and does not compile the rejected source | IMPLEMENTED (gate only) |
| Unsafe lexical boundary | `V2_UNSAFE_MODEL.md` | none | none | edition gate rejects/blocks spelling only | none | UNSUPPORTED |
| Raw pointers, provenance, alignment, aliasing | `V2_MEMORY_MODEL.md` | v1 `*T` lowering in `native/ncodegen.zag` is not a v2 model | existing v1 pointer tests only | none for v2 rules | none | UNSUPPORTED |
| Checked and unchecked slices | `V2_MEMORY_MODEL.md` | v1 native slice lowering | `tests/run_native.sh` covers v1 checked paths | no v2 unchecked boundary test | v1 native execution only | PARTIAL / not v2 support |
| Allocation, resize, free, custom allocators | `V2_MEMORY_MODEL.md` | `_zag_malloc`, `_zag_realloc`, `_zag_free` lowering | existing v1 native tests exercise selected paths | no allocation-failure, invalid-free, or effect tests | mmap-backed native paths only | PARTIAL / not v2 support |
| Layout and ABI representations | `V2_MEMORY_MODEL.md`, `V2_ABI.md` | native size/layout code | existing native aggregate tests | no C layout differential test | no bidirectional C execution | UNSUPPORTED |
| Volatile and MMIO | `V2_MEMORY_MODEL.md` | none | none | none | none | UNSUPPORTED |
| Atomics, fences, memory orders | `V2_CONCURRENCY_MODEL.md` | isolated legacy fence lowering is not a public API | none for v2 atomics | no ordering/alignment rejection tests | no litmus execution | UNSUPPORTED |
| Threads and blocking semantics | `V2_CONCURRENCY_MODEL.md` | `native/thread_rt.zag` is runtime-oriented only | none for public v2 syntax | no realtime/effect rejection suite | no v2 spawn/join stress suite | UNSUPPORTED |
| Effect propagation | `V2_EFFECT_MODEL.md` | `selfhost/sema.zag` has v1 bitmask inference | `tests/run_semantics.sh` | lacks Unsafe/Atomic/FFI/GPU adversarial witnesses | semantic check only | PARTIAL / not v2 support |
| C ABI, static objects, dynamic libraries | `V2_ABI.md` | v1 `extern` parsing and native call lowering | selected native extern tests | no invalid-v2-ABI suite | no C-to-Zag/Zag-to-C/shared-object suite | UNSUPPORTED |
| CPU intrinsics, SIMD, inline assembly | `V2_LANGUAGE_SPEC.md`, `V2_UNSAFE_MODEL.md` | none | none | none | no machine-code assertions | UNSUPPORTED |
| GPU address spaces and kernel effects | `V2_GPU_MODEL.md`, `V2_EFFECT_MODEL.md` | MLIR/gfx bundle emitters do not have a v2 typed authority | `tests/run_native_gpu.sh` checks emitted output | no address-space/effect rejection tests | none | FRONTEND ONLY |
| GPU target binary and physical dispatch | `V2_GPU_MODEL.md` | none: no device enumeration/context/buffer/dispatch/readback path | none | no OOB/effect rejection at runtime | none | UNSUPPORTED |
| Sanitizers and debug allocator | `V2_MEMORY_MODEL.md` | none | none | none | none | UNSUPPORTED |
| Fuzzing and malformed-input corpus | `V2_IMPLEMENTATION_PLAN.md` | `tests/run_crash_corpus.sh`, `tests/run_fuzz_smoke.sh`; `tests/crash_corpus/` | crash corpus rejects ten minimized malformed sources; deterministic byte smoke has seven cases | both suites assert nonzero exit, timeout failure, no artifact, and no signal termination | compiler invocation only | PARTIAL / no coverage-guided fuzzing or sanitizers |
| Differential and performance evidence | `V2_IMPLEMENTATION_PLAN.md` | legacy differential scripts exist | `tests/run_differential.sh` is v1 evidence | no v2 semantic differential suite | no v2 benchmarks | PARTIAL / not v2 support |

## Verified v1 regression evidence, not v2 completion

The following commands remain useful regression evidence for the frozen v1
compiler.  They do not discharge a v2 row above: `./bootstrap.sh`,
`bash tests/run_semantics.sh`, `bash tests/run_native.sh`,
`bash tests/run_native_authority.sh`, `bash tests/run_native_wasm.sh`, and
`bash tests/run_native_gpu.sh`.  The GPU command validates emitted MLIR and a
restricted bundle only; it must never be cited as a physical GPU execution
test.

## Release decision

Do not release Zag v2.  A release requires every row marked `UNSUPPORTED`,
`PARTIAL`, or `FRONTEND ONLY` to gain a specification-conformant implementation
plus positive and negative tests, and runtime validation where the row calls
for execution.  The release gate intentionally returns nonzero until then.
