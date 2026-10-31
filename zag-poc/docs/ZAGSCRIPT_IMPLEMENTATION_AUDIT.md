# Zag Script implementation audit

Status: current architecture record, 2026-08-31. This document distinguishes
implemented behavior from bounded proof slices and unsupported roadmap work.

## Current ZagScript 1.0 release snapshot

The frozen capability matrix is generated from `tests/zagscript_1_0_capabilities.tsv`
and is intentionally not yet complete. The strict release preflight therefore exits
nonzero by design; this is not a 1.0 release claim. The bounded native reference-app
suite is a nine-member witness, not a release claim: the latest completed run on
the current `znc` image reached 6/9. CLI automation, the file indexer, package
consumer, async worker, dynamic plugin, and Zagkit contract fixture passed;
TLS/HTTP, WebSocket, and SQLite HTTP service members were blocked by this
host's ptrace/loopback sandbox restrictions. Those applications do not complete
the broader network, concurrency, package, dynamic-ABI, or security contracts.

Current source-lane evidence includes the 112/112 lossless-CST gate, including
validated 1-based byte columns on every localized recovery record, the 11/0
source-origin authority gate, the bounded ZIR authority suite (75 emitted
assertions; footer `pass=75`) plus the 10/10 typed
TaskI64 ABI gate, 36/36 reversible-view gate (including warning-free
captured-closure construction and five-, six-, and seven-parameter captureless
closure promotion/reversal across the register/stack boundary), 192/192
v2 ownership/edition checks, fresh
TaskI64 result/cancellation and async-surface checks, typed
Script maps/sets/interpolation/list checks, and resource-contract syntax/affine
checks, Script lifetime **27/0**, and strict JSON/CSV profile **PASS**. The
typed-IR contract now also binds every represented memref
allocation/load/store to an exact element-type attribute, so forged element
metadata fails closed before any native route; the authority test covers
allocation, load, store, alias, ownership, and origin rejection. The large
Script explain manifest now uses a linear growable JSON escape buffer
(633 KB output, 0.48 s, 24 MB peak RSS in the map regression) rather than
quadratic per-byte concatenation. The ZIR native admission path also rejects
forged/truncated operand, result, attribute, region, op, block, function, and
parameter arrays before indexing. The
semantic-egraph ZIR bridge now also extracts typed integer XOR/AND/OR and
exact-width signed left/arithmetic-right shifts, keeps boolean and integer
operations/rewrite identities disjoint, closes every admitted attribute
schema, and requires the terminal return to name the exact latest SSA result.
Checker-local i32/i64 reference arithmetic independently recomputes these
bounded results and rejects overflow, trap, malformed-width, and extreme-count
cases while the bridge retains non-authoritative status. The
resource affine suite also passes its positive drain/drop, retained-storage
`clear_with`, retained-storage final-element `pop_with`, indexed `take_with`,
and fail-closed negative cases. The fresh
scalar-list reuse gate also passes with resource-valued plain `clear`
rejected before artifact emission. The focused Linux filesystem-write
gate also passes descriptor-relative regular-file replacement, empty rewrite,
nonblocking/no-follow rejection, bounds, and recovery checks; it now also
proves descriptor-relative regular-file metadata (size/kind), size/name limits,
final-symlink rejection, close-on-error recovery, and an explicit directory
`fsync` success/closed-state boundary; directory-list entries are also
revalidated with descriptor-relative `fstatat(..., AT_SYMLINK_NOFOLLOW)` rather
than trusting `DT_REG`. The package
capability aggregate also
passes 11/0, including the
44/0 resolver, 37/37 ownership/generator unit evidence, and the foreground
registry-lock resolver 18/18 sidecar-retention regression. Current daemon
CLI explain evidence now binds compiler-bound Script operation witnesses to
parser-backed exact or projected source locations and explicitly reports
synthetic-wrapper locations as unavailable; the refreshed CLI gate passes.
metadata-only generation, bounded generation-worker admission (8/8),
verifier-approval, benchmark-policy, and checker-only transform-proposal gates
also pass; the latter exercises
malformed, stale-semantic, and stale-proposal envelopes and deliberately does
not authorize synthesis or executable optimizer replacement. Fresh daemon
integration also reaches the opt-in adaptive 30-second idle-deep path and
preserves stale/cancellation boundaries. Planner authority now passes 19/19
checks and the precedence witness passes 11/11 for the six documented policy
fields while retaining metadata-only foreground independence; the executable
daemon policy integration passes 3/3. The structural projection gate passes
30/30 for uniquely anchored edits, captureless closure-body origin projection
including captured scalar-value return projection, the five-parameter, two-statement, three-statement,
four-statement, and five-statement closure boundaries, and localized
conflicts, with exact compact-byte reconstruction and malformed capture-list/header/initializer/duplicate/pointer rejection. The
derivation-ledger v2 codec gate passes 18/18,
including compact-byte binding, exact inverse metadata, semantic-graph
completeness admission and incomplete-graph rejection, and fail-closed
structural-projection flags. The v2 gate can
place its temporary compilation tree under
`TMPDIR` (default `/tmp`) so the result is reproducible even when the
root filesystem is constrained. These focused checks now sit on a fresh
three-stage native bootstrap fixpoint for the current source: `znc` is
`762577e220014eabf2f5fc55019a74aa3ccd4690db2586e09cce4e7ca9a42470`
(`10,249,071` main bytes; `10,577,592` file bytes), and the current source
snapshot fingerprint for this fixed-point source image is
`b6036ee07b8d4ae7ac0a4f69d0cc5d0efe3e7bc92eacefc0843e49e980f9e953`.
The fixed-point daemon is
`dde372a9b8d71e3fcf3eb96a7461c66544526e5c4e5edb87c969a7acf17bdab0`
(`1,040,064` main bytes; `1,079,552` file bytes). The ordinary bootstrap
reached byte-identical stage 3. A current direct empty-`PATH` probe compiled
and ran three known fixtures with the fixed-point compiler without host
command lookup; the full six-check `tests/check_native_bootstrap_repro.sh`
fixpoint witness was not rerun after this source update. The optional cgroup
memory/swap guard remains unavailable because this host has no user systemd
manager; observed ordinary stage RSS was approximately 2 MiB. The strict release gate still refuses before native work because the
frozen capability matrix contains partial and unavailable rows.
The new opt-in graph-lock v2 codec
passes its focused 10/10 gate while preserving the v1 5/5 gate; its
caller-opt-in authority seam also passes 12/12 with exact graph membership,
pinned artifact checksums, retained registry artifact-signature paths, and
signed-policy fail-closed paths. It remains a
caller-owned provenance/admission codec and is not ordinary resolver admission.

The native view gate now executes the bounded direct-ZIR floating-point cast
route, not merely its textual projection: `f64 41.75 as i32` returns 41 and an
`i32 → f64 → i32` round trip returns 41. It also proves inferred local scalar
calls with exactly three, four, five, or six canonical `i32` or `i64` arguments consume direct ZIR;
seven-or-more-argument calls remain on the bridge. The emitter uses the same SSE
conversion instructions as the mature AST backend; boolean, NaN, out-of-range,
and broader contextual cast semantics remain fail-closed or on the AST bridge. The same route also includes typed non-literal f32/f64 `arith.negf` artifacts with production/AST equality and forged result-width rejection.
The authority suite additionally executes all six finite `f64` and `f32`
comparison predicates through direct `arith.cmpf`, a bounded exactly
representable `f32` add/multiply/divide differential fixture, and rejects
forged `f32`/`f64` operand-width mismatches; NaN behavior remains outside this
finite proof slice.
Typed non-literal `i32`/`i64` unary negation now lowers to the checked
`arith.negsi` operation and is consumed directly; canonical literal negation
retains its existing source-policy shape, including the MIN_INT boundary.
Typed scalar integer XOR now lowers to `arith.xori`, typed scalar integer AND
to `arith.andsi`, and typed scalar integer OR to `arith.orsi`; exact scalar
left and arithmetic-right shifts lower to `arith.shli` and `arith.shrsi`.
All five operations are consumed directly for exact `i32`/`i64` operands and
results; native shift counts are checked against the operand width and fail
closed with status 134 when invalid. Bool/non-scalar bitwise forms, broader
widths, and policy-sensitive forms remain on the checked AST bridge.
Typed signed `i32` comparisons now also have a bounded direct `arith.cmpi`
route for `eq`, `ne`, `lt`, `le`, `gt`, and `ge`; the authority suite
executes all six predicates, an `i64` signed-`ge` witness, the complete
typed-`i64` six-predicate fixture, and rejects
mismatched comparison widths. Unsupported widths and contextual comparison
forms remain fail-closed or on the checked AST bridge.
Defined typed `i32` signed division and remainder now also have a direct
`arith.divsi`/`arith.remsi` differential route for `20/3` and `20%3`, with a
forged mixed-width operand rejected before native admission; divide-by-zero,
overflowing `MIN_INT/-1`, and broader checked arithmetic policy remain on the
existing guarded boundary.

The latest daemon integration also consumes a real `zagd-candidates-v2` record
through a freshly compiled foreground fixture. Producer/consumer identity is
bound to the sibling `znc` image, the target field is single-valued, and
rejected rows carry explicit unavailable validity and reasons. This closes a
metadata-wiring gap only; candidates remain advisory and cannot authorize
native rewrites. The generation worker admission is metadata-only and
deliberately disables worker execution; operating-system namespaces,
seccomp/cgroups, and executable synthesizer/verifier replacement remain
unavailable.

The ZIR bridge now records a versioned `task_i64.v1` ABI metadata operation and
explicit `task.spawn`, `task.await`, and `task.cancel` records with owned-handle
and cancellation attributes. `tests/run_zir_task_abi.sh` proves exact origins
and rejects stale, truncated, forged, and invalid ownership evidence. Native
lowering still keeps task modules on the checked AST path until a differential
handle/scheduler backend exists. Generic futures, scheduler independence, and
flow-sensitive task ownership remain outside typed-IR authority. Closure
pointer variables captured by value likewise fail closed without an explicit
v2 lifetime contract.

The bounded error-flow slice now lowers unary `try` on `!T` into an explicit
`error.propagate` ZIR operation with exact `!T`/`T` types, propagation metadata,
and source origins. `tests/run_zir_error_flow.sh` proves valid records and
rejects forged result types, attributes, and origins. Error functions remain on
the checked AST backend; this slice does not claim native error-union ABI
authority, and `catch`/generic error transport remain incomplete.

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

## 1. File-level syntax

`selfhost/lex.zag` produces the shared token stream.
`parse_compilation_unit_dir` and `resolve_src` in `selfhost/parse.zag` parse
file-level syntax. The root parser recognizes exactly one `script;`, records
`ModuleProfile.script`, and accepts root executable statements only in that
profile. It diagnoses duplicates, ordering errors, generated-name collisions,
and a conflicting user `main`. Comments may precede activation.

CLI activation and the optional `.zs` surface inject profile activation only
into the compiler's in-memory source. They then enter this same parser; neither
path owns a second language implementation.

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
10. focused positive, negative, stress, compatibility, and resource tests;
11. a shared registry selector that intersects up to 256 canonical SemVer
    requirements and fails closed on incompatible or incomplete edge sets;
12. a bounded homogeneous UTF-8 Script text-set facade reusing the checked
    ScriptMapText key-copy, tombstone, clear, and ScriptContext ownership
    authority;
13. a bounded max-eight TaskI64 ready/value selector that observes handles
    without consuming them and validates duplicate/null/timeout inputs; and
14. a bounded local registry graph intersection and signed artifact/index
    provenance test seam, without claiming network or transitive resolution.
15. a caller-buffer UTF-8 normalization seam that composes a bounded common
    Latin NFC subset while preserving unknown marks and malformed-input status.
16. a bounded TaskI64 scope that polls parent cancellation, propagates it to
    seven caller-owned children, selects a ready child, and requires affine
    removal/await completion.
17. a bounded explicit transitive package graph walker with cycle/missing/
    conflict diagnostics and deterministic create-only graph-lock bytes.
18. a consuming TaskI64 cancellation-cleanup helper that requests cooperative
    cancellation, awaits exactly once, and writes a typed join record with
    invalid-handle/output paths.
19. an independent package graph-lock verifier that checks envelope checksum,
    canonical ordering, exact graph coverage, selected version/source/raw
    checksum, truncation, and appended-byte rejection.
20. typed CST expression-envelope recovery that rejects crossed, mismatched,
    and unterminated nested delimiters before projection.
21. an explicit caller-opt-in package graph-lock authority seam that verifies
    graph membership and pinned selection metadata without changing ordinary
    lookup behavior.
22. a bounded eight-handle TaskI64 wait-many record with completion and
    cancellation masks, per-slot values, timeout, and invalid-input rejection.
23. a policy-precedence witness covering CLI, source-boundary choices, project
    policy, defaults, malformed-policy rejection, and foreground `--no-zagd`
    independence.
24. versioned TaskI64 ABI metadata and explicit spawn/await/cancel ZIR records,
    with native admission deliberately rejected until a differential task
    backend proves the handle and scheduler ABI.
25. an explicit foreground package-import admission seam that rechecks a
    resolved registry tuple against a caller-supplied graph lock and marks
    only an exact match graph-authorized, while preserving the default
    resolver and rejecting forged, stale, malformed, and non-registry inputs.
26. an explicit typed `error.propagate` ZIR record for unary `try` on `!T`,
    with exact `!T`/`T` types, propagation metadata, source origins, and
    fail-closed malformed-flow validation while native error-union admission
    remains disabled.
27. a bounded top-level Script trailing-operator recovery record with exact
    shared-token span/origin and a no-artifact compiler rejection, while
    delimiter continuations and broader expression recovery remain deferred.
28. direct typed non-literal `i32`/`i64` unary negation through `arith.negsi`,
    with literal MIN_INT and broader arithmetic policy remaining fail-closed or
    source-policy-only.
29. direct typed `i32`/`i64` integer XOR through `arith.xori` with AST
    differential and malformed-type rejection,
    with independent native-vs-AST return-value witnesses and non-integer
    contract/backend rejection; shifts have a separate exact-width authority
    slice and non-scalar forms remain on the checked AST bridge.
30. direct typed `i32`/`i64` integer AND through `arith.andsi` with AST
    differential and malformed-type rejection, while non-scalar forms remain
    on the checked AST bridge.
31. pure semantic-egraph/ZIR extraction and checker-local recomputation for
    width-preserving integer XOR, AND, OR, and exact-width signed left and
    arithmetic-right shifts, with separated bool/integer operation admission,
    closed attribute schemas, checked signed edge cases, and terminal returns
    bound to the exact latest SSA name and e-class; this extends only the
    non-authoritative analysis domain and does not authorize executable rewrites.
32. malformed Script interpolation-brace recovery with exact offending-brace
    spans, stable origins, and fail-closed CLI/no-artifact behavior while
    complete and doubled-brace forms remain valid.
33. malformed Script unterminated-string-escape recovery with exact terminal
    backslash spans, stable origins, parser-boundary validation, and
    fail-closed CLI/no-artifact behavior.
34. direct typed `i32`/`i64` integer OR through `arith.orsi` with AST
    differential and malformed-type rejection, while non-scalar forms remain
    on the checked AST bridge.
35. validated six-field planner policy resolution carrying adaptive defaults
    and explicit CLI/source/project/default precedence; malformed policy fails
closed and no daemon policy record grants executable optimizer authority. The
freshly compiled daemon now consumes that resolution at startup: its runtime
status reflects project `.zagd.conf` values, every six-field CLI override wins,
and malformed project policy is rejected before daemon startup in the focused
3/3 integration gate.

36. executable daemon policy integration applying the validated six-field
    planner result to runtime status, with project configuration and explicit
    CLI override coverage, malformed-policy startup rejection, and no
    optimizer execution authority; source-level policy precedence remains
    independently covered by the 11/11 planner witness.

37. direct typed `i32`/`i64` left and arithmetic-right shifts through
    `arith.shli`/`arith.shrsi`, with exact width attributes, AST differential
    execution, invalid-type/width rejection, and runtime count validation;
    broader widths and optimizer-level shift rewrites remain outside the
    authority slice.

38. checksummed derivation-ledger v2 metadata validation with compact-source
    byte binding, exact inverse/projection fields, formal-equivalence flags,
    optimizer-transform counts, semantic-graph completeness admission, and
    fail-closed structural-projection/incomplete-graph rejection;
    `tests/run_derivation_ledger.sh` passes 18/18 while
    human-owned promoted source remains recoverable after cache deletion.

39. Script `clear(list)` capacity reuse with deterministic reappend and live
    prefix scrubbing, plus scalar `ArrayList.clear` capacity reuse,
    retained-storage `ArrayList.clear_with` callback/drop, live-byte zeroing,
    capacity retention, retained-storage final-element `ArrayList.pop_with`
    callback/drop with empty-list fail-closed behavior, and compiler rejection
    of resource-valued plain clears before artifact emission;
    `tests/run_script_list.sh`, `tests/run_list_clear.sh`, and
    `tests/run_resource_affine.sh` pass the Script, scalar, and resource paths
    on the refreshed compiler. The root helper resolver independently infers
    one-argument `script_list_clear[T]` calls through `&list` and keeps
    user-defined helper precedence. Indexed whole-list `take_with` remains the
    other explicit resource-element exception; general collection element
    move/drop semantics remain outside this bounded slice.

40. finite `f64` direct `arith.cmpf` coverage for all six predicates with an
    AST differential executable witness and forged `f32`/`f64` operand-width
    rejection; NaN and broader floating-point comparison semantics remain
    outside the proof domain.

41. seven-parameter captureless scalar closure materialization through the
    explicit Script view, native execution, promotion, and exact unexpansion,
    including the System V stack-argument boundary, with eight-parameter and
    non-scalar closures rejected before expansion; general closure ownership
    and escape semantics remain partial.

42. bounded descriptor-relative regular-file write/rewrite/readback on Linux
    x86-64 with `O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK`, short-write/EINTR handling,
    size and path validation, regular-file rejection, and recovery after
    invalid/traversal/closed-descriptor inputs; crash-atomic publication and
    recursive filesystem semantics remain outside this slice.

43. descriptor-relative regular-file metadata (`size` and kernel kind) with
    `O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK`, 16 MiB bound/name validation,
    final-symlink and non-regular rejection, close-on-error, and recovery;
    timestamps, ownership, permissions, and race-free lease semantics remain
    outside this slice.

44. five-parameter captureless closure-body structural projection through the
    generated origin map, exact compact reconstruction, and localized
    generated-header conflicts; arbitrary generated-wrapper edits remain
    fail-closed.

45. direct defined typed `i32` division/remainder through the ZIR/native and
    AST differential fixtures, with forged operand-width rejection; zero
    division and overflowing signed edge behavior remain guarded or bridge-only.

46. independent AST differential coverage for the defined signed `i32`
    division/remainder edge (`MIN_INT / -1`, `MIN_INT % -1`, and ordinary
    quotient/remainder), with production and AST exit-status equality and the
    existing division-by-zero trap witness; broader checked arithmetic policy
    remains outside this slice.

47. descriptor-relative directory flush through Linux `fsync`, with retained
    directory-state validation, successful post-replacement flush, and a
    closed-directory `invalid_state` rejection; crash-atomic publication and
    universal filesystem durability remain outside this slice.

48. two-statement captureless scalar closure projection (byte-identical local
    assignment plus editable final return) through generated origins, with
    local-line edits rejected and compact reconstruction exact; arbitrary
    multi-statement or ownership-sensitive generated edits remain fail-closed.

49. three-statement captureless scalar closure projection (two byte-identical
    local assignments plus an editable final return) through generated origins,
    with local-line edits rejected and compact reconstruction exact; arbitrary
    multi-statement or ownership-sensitive generated edits remain fail-closed.

50. finite `f32` direct `arith.cmpf` coverage for all six predicates with an
    independent AST differential executable witness and forged `f32`/`f64`
    operand-width rejection; NaN and broader floating-point semantics remain
    outside the proof domain.

51. five-statement captureless scalar closure projection (four byte-identical
    local assignments plus an editable final return) through generated origins,
    with local-line edits rejected and compact reconstruction exact; arbitrary
    multi-statement or ownership-sensitive generated edits remain fail-closed.

52. descriptor-relative directory-entry revalidation with `fstatat` and
    `AT_SYMLINK_NOFOLLOW` before regular-file listing results are admitted;
    symlink/non-regular entries, traversal, and broader recursive filesystem
    semantics remain outside this bounded recovery slice.

53. finite exactly representable `f32` add/multiply/divide direct-ZIR and AST
    differential witnesses with forged `f32`/`f64` operand-width rejection;
    NaN, overflow, rounding-policy, and broader floating-point arithmetic remain
    outside the proof domain.

54. valid multibyte UTF-8 scalars surrounding malformed units retain disjoint
    byte spans, physical lines, deterministic origin IDs, and fail-closed
    validation in the lossless Script CST; invalid lead classes `0xC0-0xC1`
    retain contiguous continuation bytes in one localized recovery span;
    arbitrary Unicode normalization and full parser recovery remain outside
    this slice.

55. captured scalar-value closure return projection through the derivation ledger
    reconstructs exact compact bytes and rejects malformed capture-list/header/
    initializer, duplicate-context, missing-close, and pointer-capture edits;
    general captured closure ownership and mutation edits remain incomplete.

56. typed non-literal `f32`/`f64` unary negation lowers to `arith.negf` through
    the direct production/native route with independent AST equality and forged
    result-width rejection; broader floating-point policy and contextual routes
    remain outside this proof domain.

57. bounded strict and Script homogeneous JSON `f64` arrays parse signed-zero and
    exponent spellings, reject malformed/trailing tokens, enforce byte/value
    limits, and release partial native temporaries on success and failure;
    the Script encoder now has a source-bound, allocation-free six-decimal
    formatter that preserves required fractional leading zeroes, uses a tiny
    ulp-tolerance for decimal-parser representation noise, rejects non-finite,
    out-of-range, and lossy values before reserving output, and proves
    Script-budget and aggregate-escape failures; general numeric formatting,
    dynamic JSON conversion, and broader floating-point policy remain
    incomplete.

58. validated `registry.lock` sidecars are retained as owned compilation
    resources and adopted into the semantic dependency ledger, with direct
    resolver ownership and parser/cache-record evidence in
    `tests/run_package_registry_lock_resolve.sh` (18/18). A valid v1 sidecar
    mutation with an unrelated entry changes the semantic record while leaving
    the native artifact byte-identical; public registry transport, complete
    graph solving, and revision authority remain outside this bounded
    provenance slice.

59. Script `map_clear(map)` integer-map reuse with pre-write descriptor
    validation including exact live/tombstone counts, complete retained
    key/value/state scrubbing, capacity reuse, post-clear reinsertion,
    null-target and malformed-state rejection, exact wrong-arity diagnostics,
    and user-declaration precedence; the refreshed `tests/run_script_map.sh`
    and `tests/script_map.zag` execute these paths. Context identity is
    intentionally a self-consistency check rather than a claim of
    arbitrary-pointer authentication; dynamic maps and general collection
    ownership remain incomplete.

60. Script `set_clear(set)` integer-set reuse with pre-write descriptor
    validation for non-null context, power-of-two capacity, exact
    live/tombstone counts, complete retained key/state scrubbing, capacity and
    pointer reuse, post-clear reinsertion, null-target and malformed-state
    rejection, exact wrong-arity diagnostics, and user-declaration precedence;
    the refreshed `tests/run_script_set.sh` and `tests/script_set.zag` execute
    these paths. Context identity remains a non-null descriptor invariant rather
    than arbitrary-pointer authentication; broader collection ownership remains
    incomplete.

61. Script `text_map_clear(map)` and the `text_set_clear(set)` facade now use
    all-or-nothing pre-write validation for a non-null target/context, bounded
    power-of-two capacity, backing arrays, every state byte, and exact
    live/tombstone counts. The refreshed text-map/text-set gates prove complete
    retained key/value/state scrubbing, pointer/capacity reuse, reinsertion,
    null and malformed descriptor rejection without partial writes, exact
    arity diagnostics, auto-import and user-declaration precedence, precise
    explain witnesses, and a compilable text-map-only explicit view. Payload
    mutation entry points now reject null map/set targets before dereference,
    and the ownership checker binds list/map/set ScriptContext producers to
    their exact resolver-owned module origins so direct module imports pass
    without granting same-name project functions a borrow exception. Payload
    allocations remain ScriptContext-owned until shutdown; dynamic values,
    resource elements, and arbitrary-pointer authentication remain incomplete.

62. Explicit-view module discovery now imports list literals/helpers,
    non-join path helpers, direct string-builder helpers, text-map-only calls,
    and argv-only process calls from the family predicate itself rather than
    conditioning the import on one unrelated constructor. The reversible-view
    and focused text-map gates expand, compile, and run candidates from every
    repaired family.
    Explain JSON/text also reports the complete implemented root convenience
    allowlist instead of omitting map, set, range, path, and codec bindings;
    these repairs do not widen the allowlist or claim that semantic checking
    alone proves arbitrary generated candidates natively compilable.

63. Explicit `view` and `expand` now acquire the compact root through the same
    8 MiB bounded `O_NOFOLLOW` foreground reader used by simple/native views
    and promotion. The view gate rejects both a symlinked compact root and an
    oversized sparse root before parsing or candidate output, closing the prior
    outputless harden path that followed symlinks through `_zag_read_file`.
    Dependency-graph revalidation remains the prepared-snapshot authority for
    publication; this slice does not claim general filesystem sandboxing.

`harden` remains deliberately conservative: it emits an ordinary reviewable
candidate only where conversion is established and otherwise reports an honest
partial/unsupported item.

## 12. Regular Zag invariants

A regular source still has declaration-only file scope, requires its own
`main`, retains explicit allocation/device/layout choices, and receives no
Script allocator context or prelude. The daemon never rewrites source and cannot authorize
an executable. Normal backend optimizations remain semantics-preserving and
independent of `zagd`. Regular Zag may show a configurable, evidence-backed
advisory; unsupported planner scaffolding stays silent. The shipped project
default is `notifications=advisory`, which emits at most one warning after a
supported human-review fact exists; `notifications=errors_only` makes routine
commands quiet. Neither setting grants automatic source or architecture authority.
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

## Current remaining capability boundaries

The matrix is intentionally not promoted by bounded slices. The unresolved
contract is broader than the focused evidence: the CST still has line-oriented
normalization and incomplete arbitrary-expression recovery; closures lack
general ownership and function-value escape semantics (the explicit view now
has bounded root-level immutable scalar value-capture reconstruction, including
multiple captures, plus seven-parameter captureless scalar closure materialization
across the register/stack boundary, with result-before-close cleanup); collections lack
dynamic values, automatic Script cleanup, and
resource-element move/drop rules; async
remains a bounded Linux `TaskI64` ABI with typed ZIR records but without generic
futures, scheduler integration, or a native handle backend; and the typed IR
still uses an AST bridge for contextual, effectful,
generic, and concurrency-heavy domains.

The package resolver now has bounded multi-edge and graph-wide local-index
intersection witnesses plus signed artifact/index provenance checks, and an
explicit caller-owned foreground admission check can bind a resolved registry
tuple to a verified graph lock. It is not a complete graph solver: parser-owned
graph construction is now bounded and covered by parser-owned evidence;
transitive revision selection, registry transport, and graph-wide lock
publication authority remain outside that slice. The shared parser retains
nearest-manifest registry edges and validates a conventional root graph lock
against the complete edge stream; explicit nonstandard sidecars remain
caller-selected. The remaining release
gaps are equally explicit: arbitrary structural expansion
and projection, general Script aggregate JSON/CSV ownership, full network and
security policy, general ABI/plugin/database behavior, registry/version/signature
authority, executable daemon optimizer selection, complete proof-certificate
domains, automatic optimizer-generation replacement, and a zero-gap release
matrix. These boundaries remain `partial` or `unavailable` until their named
release evidence proves the complete contract rather than only a bounded slice.
