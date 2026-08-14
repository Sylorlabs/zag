# Zag Script implementation audit

Status: current architecture record, 2026-08-06. This document distinguishes
implemented behavior from bounded proof slices and unsupported roadmap work.

## Baseline recorded before implementation

The clean `zag-v2-machine-control` worktree used
`znc 2026.07.0-dev (edition 2026)`. The requested pre-change gates reported:

- `tests/run_native_authority.sh`: `pass=7 fail=0`
- `tests/run_native.sh`: `pass=133 fail=0`
- `tests/run_native_gpu.sh`: `pass=5 fail=0`
- `tests/run_native_wasm.sh`: `pass=17 fail=0`
- `tests/run_native_total.sh`: `pass=8 fail=0`

Those are the gates' actual boundaries. The GPU suite proves frontend/bundle
structure, not physical GPU execution. The WASM suite proves emission and
records runtime cases as unsupported where no pure-Zag runtime exists.

## Supported compiler path

`selfhost/native/znc.zag` is the supported compiler. It reads source, uses the
shared lexer/parser/typed/effect authorities, lowers native x86-64 instructions,
encodes them, and writes ELF directly. The supported bootstrap and native path
uses Zag plus Linux syscalls; it does not require Python, a C compiler, LLVM,
Zig, an assembler, or a linker.

This describes the implementation boundary, not a current working-tree
certification. After source edits, the checked-in `znc` may be a stale seed;
the current-source fixpoint and native-authority gates must be rerun before a
release claim. The capability matrix keeps those rows `partial` until that
post-edit evidence exists.

## 1. File-level syntax

`selfhost/lex.zag` produces the shared token stream.
`parse_compilation_unit_dir` and `resolve_src` in `selfhost/parse.zag` parse
file-level syntax. The root parser recognizes exactly one `script;`, records
`ModuleProfile.script`, and accepts root executable statements only in that
profile. It diagnoses duplicates, ordering errors, generated-name collisions,
and a conflicting user `main`. Comments may precede activation.

CLI activation and the optional `.zs` surface inject profile activation only
into the compiler's in-memory source. Indentation-oriented input is represented
first by a lossless CST with exact raw/content byte spans, indentation, line
kind, deterministic origin IDs, bounded inconsistent/mixed-indentation and
invalid-byte recovery records,
and a byte-exact reconstruction path. Its
normalized projection records complete generated-range-to-origin coverage and
then enters this same parser; neither path owns a second language implementation.
Parser nodes project back to compact root and imported-module byte ranges.
Byte-identical ranges are marked exact; indentation rewrites retain a sound
enclosing range, while synthetic wrappers remain explicitly unlocated.
The versioned `zag-ir-v1` production contract carries those origins, function
effects, and conservative value ownership, alias-region, lifetime, and layout
fields. Every foreground x86-64 build constructs and verifies it. The contract
has structured `if`, `while`, noncapturing `switch`, and `defer` regions plus
string, embed, cast, struct, field, index, and slice operations. It publishes
`coverage_complete` and an exact `coverage_errors` count, so captures, mutation
targets, untyped-local inference, and other unsupported operations cannot
masquerade as typed SSA coverage; explicit contextual widths are preserved in
raw ZIR. Verified
explicitly declared `i32`/`bool` functions with SSA locals,
mutable stack slots, calls, returns, structured `if`/`while`, `break`/`continue`, noncapturing
integer `switch`, and signed division/remainder now lower directly from this IR
to x86-64 frame-slot instructions. Canonical signed-`i32` literal spellings are
range checked before direct selection; `i64`, untyped-local, and other contextual
width cases stay on the checked-AST bridge. The route admits pure functions and
the `Panic` effect only when the operation whitelist proves it comes from defined
`/` or `%`; division by zero preserves the foreground diagnostic and exit 134,
and the `INT_MIN / -1` and remainder edges wrap without an x86 trap. Branch
arms, mutable loop control, multi-pattern dispatch, ordinary arithmetic, both
overflow edges, and the panic path have native execution witnesses. The route
shares the established allocator, optimizer, encoder, and ELF data contract.
Allocation/I/O/locking effects, aggregates, floating point, specialized numeric
types, enum/union switch, `defer`, dynamic linking, safety instrumentation, and
object emission still use the named checked-AST oracle/fallback; retiring that
bridge remains required. Native views label `artifact_ir_consumed=1` only when
the direct route produced the displayed instructions. A checked-AST bridge view
uses `0`; its instruction stream is not claimed to derive from the preceding
structural ZIR.

## 2. AST declarations and statements

`selfhost/ast.zag` defines the single tagged `Node` union. Declaration variants
include functions and type declarations. Statement variants include local
bindings, assignments, expression statements, return, conditional, loop,
switch, and unsafe blocks.

`CompilationUnit` explicitly contains the module profile, merged declarations,
resolved module sources, and resolved import edges. During root parsing, Script
statements are retained in source order inside the compiler-owned Script-body
function; imported root statements are discarded rather than merged into that
body. Thus root executable work is ordinary statement AST, not a second AST or
a later filename inference.

## 3. Entry discovery and lowering

Regular Zag still requires the literal user declaration `main`.
`lower_program_mode_cpu` in `selfhost/native/ncodegen.zag` finds it and emits
Linux `_start`, preserving the initial process stack, calling `main`, and
exiting through syscall 60.

For a selected Script root, the parser synthesizes reserved, unaddressable
compiler functions for the Script body and uncaught-error reporter, plus a
generated `main`. The wrapper:

1. creates the bounded Script context with argument metadata, read-only
   environment policy, project capability bits, limits, validated execution
   policy ids, allocator state, and error-reporter policy;
2. invokes root statements once, in source order;
3. catches an uncaught Zag error and reports a nonzero status;
4. reaches the deterministic unbuffered-output flush boundary;
5. unmaps the default Script arena or frees every tracked bounded-heap block,
   then releases the context; and
6. returns the process status.

Source declarations cannot use the reserved compiler namespace. Imported
Script bodies never become entry points.

## 4. Allocation

The native runtime implements the ordinary `new`/`delete`,
`_zag_malloc`/`_zag_realloc`/`_zag_free`, `zalloc`/`zfree`, and
cache-aligned paths without libc. Small ordinary allocations use segregated
free lists over mmap arenas; large blocks use dedicated mappings. Live headers
and stale-realloc checks fail closed for the supported allocator boundary.

Native logical-allocation observers report allocation events, current live
payload capacity, and peak live payload capacity. Temporary returned-slice
descriptors are copied into compiler-owned frame scratch and released. Raw
word-slice mappings use a bounded pointer/size registry, so copied descriptors,
invalid size metadata, failed unmaps, and double frees do not silently corrupt
telemetry or unmap a live replacement. This registry is a runtime guard, not a
general ownership proof.

Script payloads default to one bounded process-lifetime arena. A second
supported policy, `script_bounded_heap`, allocates a compiler-tracked native
block for each successful Script allocation and frees all complete blocks at
generated shutdown. The arena charges requested payload bytes; the bounded
heap charges payload plus its 16-byte ownership header, including for
zero-length requests. The limit covers supported Script collections, builders,
strings, returned file data, bounded process results, `script_alloc`, and root
Script `new`. Superseded Script buffers remain charged until generated
shutdown. Native size-class slack and explicit imported strict-library
allocation are outside that budget. `read_file` does not use full-file staging:
it preflights a regular file and reads directly into exactly one charged Script
allocation. A temporary NUL-terminated path bridge is bounded to 4097 bytes,
released after `open(2)`, and remains outside the Script payload budget.
Root Script `make` and raw allocator use are rejected when their cost would
bypass Script accounting.

## 5. Runtime helpers

`ncodegen.zag` conditionally emits syscall-only helpers for output, arguments,
allocation, strings, files, time, environment lookup, and bounded process
execution. Ordinary modules under `selfhost/std/` expose the strict-Zag forms.
Script root `env("NAME")` is a separate compiler-bound wrapper over the
existing environment primitive: `NAME` must be a literal simple name in the
exact `environment_allow` project list, defaults deny all names, the returned
read-only view is capped at 4096 bytes, and imported strict code receives no
new implicit environment authority.

The root-only Script prelude is a small allowlist, not the full standard
library. Its conveniences map to ordinary declarations or compiler-owned
context calls. Process execution has an explicit timeout and capture bound.
Collections remain statically typed; no universal dynamic `any` value is
introduced.

## 6. Safety properties currently proven or enforced

The shared compiler currently enforces these scoped properties:

- transitive effect claims represented by `@pure`, `@noalloc`, `@realtime`,
  `@total`, and their witness diagnostics;
- declared-type, supported layout, call-arity, and duplicate-definition checks;
- policy-specific Script allocation limits and capability-policy denials;
- Script-context values cannot cross the specifically analyzed free, field,
  pointer, nonlocal, extern, or unresolved-call escape boundaries;
- reachable Script helper summaries are computed to a bounded fixed point;
- edition-2027 named allocation origins, aliases, consuming calls, owned-return
  summaries, branch joins, explicit shared/exclusive borrow contracts, and
  tested callee-frame address returns through named aggregate aliases;
- supported native allocator double-free, stale-realloc, raw-slice registry,
  bounds, and allocation-failure paths; and
- cache records must match compiler, complete source/module identity, profile,
  configuration, target, payload length, and checksums before reuse.

Each item is limited to constructs represented by its analysis or runtime
metadata. Tests include negative cases and require no output artifact after a
compile-time rejection.

## 7. Safety properties not implemented

Zag does not yet have a complete language-wide ownership/borrowing system,
arbitrary-pointer provenance metadata, automatic reclamation for all explicit
allocators, a mature concurrency memory model, exception unwinding, or a
target-complete trap specification. The edition-2027 checker is a conservative
named-origin and explicit-contract slice; it is not a proof about arbitrary
integer-derived pointers, mutation-aware aggregate/global provenance, callback
escapes, or every heap graph. An arena and a raw allocation registry do not make
the language universally memory-safe.

Automatic physical CPU/GPU repartitioning, packed-SIMD synthesis, general PGO,
and kernel tuning are unsupported. Planner records label these alternatives
unsupported and non-automatic instead of fabricating equivalence or speedups.

## 8. Native x86-64 to ELF

`ncodegen.zag` lowers AST into the `Instr` representation from `isa.zag`.
`regalloc.zag`, `optimize.zag`, and `peephole.zag` perform deterministic local
passes. `x86.zag` encodes permitted instructions. `elf.zag` writes little-endian
ELF64 headers, RX code, read-only data, and a zero-filled runtime BSS segment.

CPU profiles are explicit. `generic` permits the conservative baseline.
`native` combines CPUID with OSXSAVE/XGETBV where OS state is relevant and only
advertises optional instructions that both the encoder and tests implement.
Foreground cache hits substitute checksum-validated encoded code/data before
ELF assembly; any miss or corruption runs ordinary lowering.

## 9. Imports and merged modules

`@import` resolution remains part of the shared parser. Unqualified imports
merge declarations; qualified imports receive rewritten internal names.
`std:` resolves compiler-owned modules. Circular imports and invalid
`zag.mod` dependencies fail.

`CompilationUnit.modules` preserves path/source identity and
`CompilationUnit.imports` preserves edges even though declarations form one
lowering stream. Semantic manifests include those module hashes and edges.
Public declarations from a Script module remain importable, but its root body
does not execute when that file is imported.

## 10. Incremental-cache boundaries

Useful separable boundaries are source hashing, parsing, module edges,
declaration fingerprints, types/effects, function/caller/layout invalidation,
native lowering, encoded code/data, and ELF assembly.

`zagd` persists content-addressed snapshots, semantic/module manifests,
declaration indexes, advisory plan records, and bounded deep measurements.
Filesystem events are only hints: complete-file hashes establish identity.
Comment-only, private-body, public-shape/layout, root-profile, and target changes
have distinct conservative invalidation classes.

The foreground machine cache is a separate correctness-checked fast path.
Its v4 record binds the exact compiler image and version, project root, source
label, comment-insensitive root/import token identities, freshly validated
semantic graph, CPU feature profile, ABI/pipeline mode, and resolved
strict/Script runtime policy. The source label is required because generated
Script diagnostics embed it. Reads require real cache directories and
`O_NOFOLLOW`/`O_NONBLOCK` regular files, use same-descriptor pre/post `fstat`,
and enforce record, payload, and project-cache limits before checksum
revalidation. Unique `O_EXCL` staging files publish payloads first and the
authoritative record last. A validated hit substitutes the encoded code/data
and the lowering witness remains zero; every miss lowers exactly once. Static
archives, DWARF, hot-layout metadata, and final ELF output are still produced
fresh. The daemon counts and evicts the triplet as one unit. Neither cache is a
correctness dependency.

## 11. Changes made for Zag Script

The implementation added:

1. explicit profile/module/import metadata;
2. shared-parser `script;` and root statement support;
3. root-only generated entry and error boundary;
4. a bounded default arena, an explicit tracked-heap alternative, and a small
   prelude;
5. typed list, string-builder, path, argument, process, and basic JSON APIs;
6. `script`, `explain`, `harden`, and `check --strict`;
7. configurable allocator/CPU/device/layout/capability defaults where supported;
8. content-addressed foreground and background analysis caches;
9. inotify snapshots, stability windows, overflow recovery, and dependency
   invalidation; and
10. focused positive, negative, stress, compatibility, and resource tests.

`harden` remains deliberately conservative: it emits an ordinary reviewable
candidate only where conversion is established and otherwise reports an honest
partial/unsupported item.

## 12. Regular Zag invariants

A regular source still has declaration-only file scope, requires its own
`main`, retains explicit allocation/device/layout choices, and receives no
Script allocator context or prelude. The daemon never rewrites source and cannot authorize
an executable. Production backend passes remain independent of `zagd`, but that
is not a blanket semantics-preservation claim: the experimental `native/zopt.zag`
rewrite prototype is test-only and is not imported by `znc` because its metadata,
width, and trapping-operation contracts are incomplete. Regular Zag may show a configurable, evidence-backed
advisory; unsupported planner scaffolding stays silent. The shipped project
default is `notifications=advisory`, which emits at most one warning after a
supported human-review fact exists; `notifications=errors_only` makes routine
commands quiet. Neither setting grants automatic source or architecture authority.
The separate `const-i32-add-v1` rule has an explicit `--foreground-transform`
opt-in with an independently bound source/policy checker; it is not selected by
`zagd`, and its general proof/release row remains unavailable until fresh native
opt-in evidence is recorded.
`--no-zagd` and a missing or corrupt daemon/cache always leave foreground
checking and compilation usable.

## Verification authority

`tests/run_zagscript_release_gate.sh` is the aggregate Linux x86-64 first-release
gate. The separate i686 suites certify only their documented ELF32/i386 subset
until the broader ABI/runtime matrix passes. Self-hosted source changes also
require `bootstrap.sh`, `tests/check_native_bootstrap_repro.sh`, and the bounded
memory regression gate. Benchmark reports are evidence only when they include
the exact commit, hardware, input hashes, commands, at least 30 runs, dispersion,
and generic/native output equivalence.
