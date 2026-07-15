# Zag v2 machine-control forensic audit

Status: Phase 0 baseline.  This is an audit, not a claim that v2 exists.

Audit date: 2026-07-14.  Repository commit at audit start:
`76cc520a17a29bad8cadf335e307e2ab229a763b`.  The checkout was on
`wip/retire-c-backend-2026-06-30` and already had extensive uncommitted edits
to the compiler, seed binary, tests, and new untracked sources.  The audit
branch is `zag-v2-machine-control`.  Results therefore describe the current
dirty worktree, not a reproducible clean-commit baseline.  Bootstrap and test
commands were run in `/tmp/zag-v2-baseline`, an exact working-copy snapshot, so
they could not overwrite the user's modified seed or sources.

## 1. Current architecture

The supported path is `./znc`, a committed static x86-64 Linux seed.  It
rebuilds itself from `selfhost/native/znc.zag` without a host compiler.  The
driver reads a source file, checks it, parses declarations, lowers to the
native instruction representation, encodes x86-64, and writes an ELF directly.
The native lowering is concentrated in `selfhost/native/ncodegen.zag`
(10,400 lines), with instruction encoding in `x86.zag`, ELF writing in
`elf.zag`, ARM64 lowering in `acodegen.zag`/`aarch64.zag`, and WASM binary
writing in `wasm.zag`.

There is also a self-hosted front-end library: `selfhost/lex.zag`, `ast.zag`,
`parse.zag`, and `sema.zag`.  It represents types principally as strings and
computes effects as an `i32` bitmask.  `mlir.zag` is a textual MLIR emitter with
its own lightweight type propagation.  This duplication is an architectural
risk: native lowering, MLIR emission, and semantic analysis do not consume one
authoritative typed IR.

The runtime is emitted inline by native codegen.  It uses Linux syscalls and
mmap-backed allocation.  Supporting runtime sources include numeric, network,
signal, and thread helpers; their existence does not establish that the public
language syntax, semantic checks, lowering, and runtime behavior form a
complete feature.

## 2. Implemented paths, verified scope

| Area | Evidence | Current truthful status |
|---|---|---|
| Native x86-64 ELF | `native/ncodegen.zag`, `x86.zag`, `elf.zag`; authority and native gates | Executable static ELF path, verified by current tests. |
| Self-hosting/no host toolchain | `bootstrap.sh`, `tests/run_native_authority.sh` | Verified on the snapshot; stage-2 compiler and smoke ELF passed. |
| Parser/AST/effect checker | `lex.zag`, `parse.zag`, `ast.zag`, `sema.zag` | v1 constructs and the existing effect annotations are implemented; no v2 unsafe/memory/concurrency model. |
| Heap allocation | `cg_lower_new`, `_zag_malloc`, `_zag_realloc`, `_zag_free` paths | Allocation and a deallocation call path exist, but no specified allocator contract, ownership model, safety instrumentation, or v2 raw-allocation API. |
| Checked slice indexing | native `cg_lower_expr` emits an OOB panic path | Existing execution tests cover ordinary slices; trap policy is not a complete target-independent memory model. |
| Current effects | `sema.zag` bitmask: Alloc, Panic, IO, Lock, Raises | Transitive direct-call analysis exists; no formal v2 lattice for unsafe, volatile, atomics, FFI, threads, or GPU runtime actions. |
| ARM64 | `acodegen.zag`, `aarch64.zag`, separate tests | Experimental only; source contains explicit unsupported lowering cases. |
| WASM | `native/wasm.zag`, `tests/run_native_wasm.sh` | Binary emission and runtime invocation tests exist. |
| GPU frontend | `mlir.zag`, `gfx1010.zag`, `tests/run_native_gpu.sh` | MLIR text and a deterministic restricted bundle are emitted.  No physical GPU execution was performed or implemented. |

## 3. Documented claims that are not completed implementations

1. Root README calls the GPU path a "GPU backend" and some GPU test labels say
   "real launch_func".  The audit found `build_gpu` only writes `.mlir`; the
   gfx1010 path only writes a bundle.  Neither path enumerates a device,
   creates a context, allocates device memory, dispatches, waits, reads output,
   or validates results.  This is frontend emission, not an operational GPU
   backend.
2. `thread_rt.zag` contains Linux clone/futex-oriented code, but v1 explicitly
   excludes language-level threads, atomics, and a concurrency memory model.
   No public grammar, semantic model, codegen integration, or execution gate
   establishes the requested v2 threading feature.
3. `COMPATIBILITY.md` documents an ABI but calls it unstable and documents
   deviations from SysV.  There is no complete C ABI surface, C-call/C-callback
   conformance suite, shared-library build path, dynamic loader, or ABI version
   strategy implemented as a language feature.
4. `new`/`delete` and `_zag_free` exist in current native lowering, while the
   frozen v1 spec says reclamation is not portable v1.  The implementation is
   an extension and must not be described as portable v1 memory reclamation.
5. `@memoryFence` emits `mfence`, but this is not a complete atomic API or
   concurrency model and has no defined memory-order interface.

## 4. Implemented but insufficiently documented

- Native codegen has a syscall-backed runtime surface (`_zag_*`) and intercepts
  it in lowering; the v1 specification does not define its full safety,
  allocation, or ABI contract.
- `thread_rt.zag`, `net_rt.zag`, and `signal_rt.zag` exist as runtime-oriented
  sources but are outside the frozen portable v1 contract.
- `--target amdgpu-gfx1010` produces a deliberately restricted bundle.  The
  public docs must label it experimental compilation output, not dispatch.

## 5. Contradictions and release-critical risks

- The root README says the native compiler's GPU output is an integrated
  backend, but `build_gpu` proves it stops at textual MLIR.
- `tests/run_native_gpu.sh` is primarily string/file/byte-layout validation:
  grep for MLIR fragments, marker absence, brace counts, a fixed 100-byte
  bundle size, and a hash.  It does not execute any GPU work.  It is not a
  substitute for runtime validation.
- `mlir.zag` comments identify the emitter as type-unaware/lightweight;
  unsupported bases can be emitted as comments, and `mlir_fatal` is used for
  selected unsupported fields.  This cannot be treated as a verified target
  compiler.
- `ncodegen.zag` deliberately produces a trivial valid exit binary after a
  missing `main` while returning an error.  The driver must continue to ensure
  no artifact is retained/published after any hard error; v2 gates need an
  explicit no-output assertion for every hard-error class.
- The baseline bootstrap printed 29 analyzer warnings but completed successfully
  when run to completion in the isolated snapshot.  Warnings must be classified
  before any release claim.

## 6. Existing unsafe, undefined, and unspecified behavior

The frozen v1 spec explicitly leaves pointer validity to the programmer and
does not specify complete null/bounds trap behavior on every target.  There is
no provenance, aliasing, lifetime, alignment, volatile, atomic, allocation
failure, use-after-free, or stale-pointer semantics.  `*T` presently conflates
typed pointer uses without const, nullable, address-space, volatile, atomic,
or bounds distinctions.  Pointer arithmetic is unsupported by v1; indexing
accepts selected pointer/slice shapes in native lowering, so its exact
low-level behavior is not a safe v2 foundation yet.

Integer division by zero has a documented native trap.  Other overflow and
conversion behavior is distributed across lowering and specialized numeric
families rather than a single portable v2 rule.  Concurrent access, barriers,
and FFI calls have no defined language semantics.

## 7. Crash, silent-miscompile, and weak-test audit

No maintained malformed-input fuzz corpus was found at baseline.  The v2 work
now adds `tests/run_crash_corpus.sh` with minimized malformed sources.  It
initially exposed signal termination for `missing_block_end.zag` and
`unterminated_string.zag`; the lexer and parser EOF guard were fixed and the
current corpus rejects all ten inputs without an artifact.  This is a small
regression corpus, not evidence of broad robustness: no systematic parser,
sema, codegen, object-writer, or GPU-emitter fuzz target exists.

Native codegen deliberately records many unsupported forms through `cg_err`
and the driver aborts on a nonzero lowering error.  That is the correct
direction, but source inspection found several `skipping unsupported` paths
(notably unsupported top-level declarations in native/ARM64 lowering) which
need adversarial no-output tests.  ARM64 has many explicit unsupported cases.
MLIR has comment-emission paths for unsupported constructs.  These are
potential silent-miscompile risks until every path is made a hard diagnostic.

Weak tests identified: GPU gate string matching/brace counting/fixed bytes;
WASM structural string/section inspection (supplemented by Node/wasmtime
execution where available); and selected source grep checks in authority.
They remain useful subchecks but cannot be release evidence for hardware or
semantic behavior.

## 8. Baseline commands and results

All logs are preserved in repository-root `artifacts/baseline/`.

| Command (from `zag-poc`) | Result |
|---|---|
| `./bootstrap.sh` | PASS after 29 analyzer warnings; see `bootstrap.log`. |
| `bash tests/run_native_authority.sh` | PASS, 7 pass / 0 fail. |
| `bash tests/run_native.sh` | PASS, 132 pass / 0 fail. |
| `bash tests/run_semantics.sh` | PASS, 14 pass / 0 fail, 0 known gaps. |
| `bash tests/run_native_gpu.sh` | PASS, 5 pass / 0 fail; compilation/format validation only. |
| `bash tests/run_native_wasm.sh` | PASS, 31 pass / 0 fail. |
| `bash tests/run_native_total.sh` | PASS, 8 pass / 0 fail. |
| `bash run_tests.sh` | Not run: file is absent.  Recorded as explicit unsupported, not pass. |

The requested commands were named from repository root, but the executable
project root is `zag-poc/`; this document records the actual working directory
for reproducibility.

## 9. Dependency graph

```text
edition selection + parser/AST locations
  -> typed semantic IR (single source of truth)
     -> unsafe boundary + pointer/address-space types
        -> defined allocation/layout/slices/volatile
           -> atomics + concurrency + realtime effect constraints
           -> C ABI/object/linker/shared-library support
           -> CPU intrinsics/SIMD/inline assembly
        -> GPU kernel type/effect/address-space validation
           -> target binary generation
              -> host runtime, bounded dispatch, checked readback
  -> effect witness propagation through direct/indirect/generic/FFI calls
  -> sanitizer/fuzz/differential harnesses
  -> authoritative v2 release gate and generated support matrix
```

## 10. Audit decision

Do not add isolated syntax directly to the current string-typed, duplicated
paths.  v2 begins with an edition-gated parser/typed semantic representation
and a single capability/effect authority.  GPU runtime work is blocked on that
semantic boundary and on a safe, opt-in Vulkan/AMD execution harness.  The
next phase is specification and test-first implementation; no claimed v2
feature is complete until it has positive, negative, and executable tests.
