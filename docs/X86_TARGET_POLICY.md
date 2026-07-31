# Linux x86 target policy

Status: target-permission foundation, 2026-07-24. The supported native x86
target today is Linux ELF64 x86-64. Generic, native, and runtime CPU profiles
are implemented. Optional SIMD families and general multiversioning are not;
the bounded POPCNT and BMI1 ANDN intrinsics have exact generic fallbacks and
cached CPUID-qualified runtime selection.
i686 is an isolated, explicitly limited milestone target.

## Current target

The native compiler lowers directly to an internal instruction list, encodes
x86-64 bytes, and writes static ELF64 executables that use Linux syscalls. The
encoder includes scalar integer and scalar SSE floating-point operations. The
repository also contains separate AArch64 work, but ARM changes are outside this
project phase. Existing cross-target code must not be broken.

Current output is not evidence of a fully defined host-independent x86 feature
profile. Until target selection tests establish otherwise, optional instruction
use must not be described as safely native-dispatched.

## Required x86-64 profiles

`--cpu generic` is the portable release baseline. It permits only the selected
x86-64 baseline instruction set and Linux ABI assumptions. It must not inspect
the build host to silently enable optional instructions.

`--cpu native` detects the execution host and enables only encoder/codegen
features that have dedicated correctness tests. Explicit named profiles resolve
to a documented immutable feature set. Unknown profiles or requested but
unimplemented features are hard errors.

The compiler records the resolved profile and feature set in explain/planner
metadata and keys all target-dependent cache entries by it.

## Feature discovery

Native discovery executes CPUID leaves directly. AVX-family usability also
requires OSXSAVE and XGETBV confirmation that XCR0 enables XMM/YMM state.
AVX2 additionally requires its leaf-7 feature bit. This avoids treating raw
hardware CPUID as sufficient and preserves the separation between detection
and emission permission.

Features may be detected but not advertised for code generation until their
instruction encoding, register/state handling, ABI interaction, fallback and
execution tests pass. Candidate tracked features include SSE2, SSE3, SSSE3,
SSE4.1, SSE4.2, POPCNT, AVX, AVX2, FMA, BMI1, BMI2 and selected AVX-512 families.
This list is a roadmap, not a current support claim.

## Determinism and dispatch

Given compiler version, source, options and explicit profile, emitted bytes must
be deterministic. `native` output is reproducible only for the same resolved
feature set. The implemented `--cpu=runtime` case is deliberately narrow:
`popcount(i64)` emits generic and POPCNT bodies, checks CPUID while preserving
callee-saved RBX, and caches one deterministic selection. BMI1 `andn(i64,i64)`
and `trailing_zeros(i64)` follow the same independent leaf-7 cache discipline;
the latter's generic loop defines zero as 64. No optional SIMD family currently
receives runtime multiversioning.

## ABI and ELF gate

The x86-64 gate covers integer and floating arguments/returns, aggregate and
error returns used by Zag, stack alignment at calls and syscalls, caller- and
callee-saved registers, closures and structural-interface thunks, relocations,
static library linking, debug sections, raw syscalls, large frames and error
paths. Signal safety is claimed only for individually audited routines.

Generic/native differential tests must compare observable output and exit status
before performance is considered. Disassembly or encoder inspection verifies
that generic output contains no forbidden optional opcode and that native output
uses only its resolved feature set. Tests must execute on qualifying hardware or
an emulator configured to reject unavailable instructions.

## Planner authority

An explicit `.device = .cpu`, CPU profile or layout is authoritative. Regular
Zag is never silently moved to GPU or retargeted. Zag Script may select a CPU
strategy only when source leaves it unspecified. Estimates are labeled as such;
deep mode may benchmark bounded finalists but cannot waive feature, ABI, effect
or memory constraints.

## i686 milestone

i686 remains a separate target, not part of the first Zag Script release and
not implied by x86-64 support. The isolated backend now lowers the normal parsed
AST through a target-neutral integer IR for `i32` constants, initialized locals,
loads/stores, wrapping addition/subtraction/multiplication, defined signed
division/remainder, assignment, and return. Division or remainder by zero prints
`panic: division by zero` and exits with status 134. The `INT_MIN / -1` edge
wraps to `INT_MIN`, while `INT_MIN % -1` produces zero, matching the native
x86-64 backend rather than exposing i386 `idiv` traps. It emits a real
i386 stack frame and an ELF32 `EM_386` process using the 32-bit Linux exit
syscall. Signed comparisons, `if`/`else`, `while`, `break`, and `continue` use
explicit IR labels with checked relative-branch patching. Multiple non-generic
`i32` functions use the SysV i386 boundary: arguments are pushed right-to-left,
the caller removes arguments, and results return in EAX. Scalar `f64` occupies
two naturally ordered stack words; `f32` occupies one four-byte word. Both use
x87 arithmetic and return in ST(0), with `f32` rounded through `fstps` after
each operation rather than silently retaining f64 precision.
The target guarantees the psABI baseline 4-byte stack alignment; the optional
16-byte preferred boundary used by some SSE toolchains is not promised. EBP,
EBX, ESI, and EDI
are callee-saved; ordinary generated bodies use EAX/ECX/EDX, EBP, and the
stack, while the syscall and formatting helpers save and restore any
callee-saved register they temporarily require.
`usize` is one 32-bit unsigned word, not an alias for signed `i32`. Addition,
subtraction, and multiplication wrap to 32 bits; ordering uses unsigned
conditions; division and remainder use unsigned i386 `div`. Values through
`0xffffffff` are accepted in an explicitly `usize` context, while larger
literals reject before output. `i32 as usize` and `usize as i32` preserve the
low 32-bit representation, so `(-1) as usize` is `0xffffffff` and converting
that value back to `i32` produces `-1`. Mixed non-literal `i32`/`usize`
arithmetic requires an explicit cast.

`*i32` and `*usize` use 32-bit addresses and support addressing initialized
frame locals, indirect loads/stores, scalar argument passing, and `usize`
indexing with a four-byte element stride. Index-address multiplication and
addition reject runtime wrap with a deterministic panic. General `pointer +
integer` arithmetic and pointer/integer casts remain compile-time errors, in
accordance with the v1 boundary. Byte-slice indexing uses a single unsigned
`index < len` check; this rejects both negative `i32` indices and high-bit
`usize` indices with `panic: slice index out of bounds` and status 134.
Fixed-size array syntax remains outside v1; this slice does not claim it.
Merged file imports participate in the same closed-world lowering.
The bounded runtime implements `_zag_malloc` with Linux i386 `mmap2` and
`_zag_free` with `munmap`; allocation metadata is one private leading word,
failure returns a checkable null pointer, and freeing null is a no-op. This is
explicit allocation, not tracing, ownership, or automatic reclamation.
Uninitialized pointers, unsupported pointer element types, non-integer indices,
unsupported conversions, and Script constructs fail before artifact creation.

`i64` and `u64` use explicit two-word values: the low 32-bit limb has the
lowest address in locals, cdecl arguments, and sequential aggregate leaves;
scalar calls return the low limb in EAX and the high limb in EDX. Decimal and
hexadecimal literals are range-checked without overflowing the compiler,
including the complete `u64` range and signed `i64` minimum. Locals,
assignment, casts to/from supported 32-bit and narrow integers, boolean casts,
wrapping add/subtract with carry/borrow, bitwise AND/OR/XOR, masked 0..63
shifts, wrapping multiplication, signed/unsigned division and remainder,
signed/unsigned comparisons, struct copies, by-value cdecl transport, and
hidden-sret output preserve both limbs. Signed right shift is arithmetic;
unsigned right shift is logical. Division uses a deterministic bounded 64-step
two-limb routine, reports division by zero with status 134, defines signed
remainder with the dividend's sign, and makes `INT64_MIN / -1` wrap to
`INT64_MIN` with remainder zero, matching the x86-64 backend.

The
backend has a deliberately bounded small-register strategy: EAX/ECX/EDX are
scratch registers, EBP is the frame pointer, and every expression temporary is
spilled to the process stack. A function may use at most 262144 local spill
words (1 MiB) and a call may pass at most 16384 words (64 KiB); either limit
fails before output rather than wrapping a 32-bit frame calculation. This is a
safe, deterministic stack-spill allocator for the supported subset, not a
general i386 graph-coloring allocator.

Public and cross-object i386 calls support the documented 32-bit and two-word
integer/pointer forms, x87 floats, byte slices, the scalar error pair, the
bounded struct forms below, and one-word `i8`, `u8`, `i16`, `u16`, and `bool`
parameters/results. A caller sign-extends `i8`/`i16`, zero-extends `u8`/`u16`,
and canonicalizes `bool` to zero or one before publishing each four-byte cdecl
argument word. The callee applies the same rule when observing a parameter,
which keeps the boundary deterministic for separately produced objects.
Narrow local stores truncate and immediately normalize their four-byte spill
word. Narrow callees publish a fully normalized EAX result, and callers
defensively normalize EAX after an external call. Explicit narrowing casts wrap
to the low 8 or 16 bits; a directly contextual integer literal must fit its
destination and rejects otherwise. `*u8` and `[]u8` remain byte-memory forms
and are not changed into four-byte elements by this cdecl rule.

Sequential structs may also contain `i8`, `u8`, `i16`, `u16`, and `bool`.
This bounded Zag aggregate layout deliberately assigns every narrow field one
complete four-byte word in declaration order. Acyclic nested structs recursively
inline the same checked layout. Struct-literal initialization, nested local
field assignment/load, whole-local copies, reverse-order cdecl publication,
callee parameter views, callee hidden-sret copies, and caller result views
normalize every narrow leaf at its storage or ABI boundary. That rule is
deterministic across compiler-produced ELF32 objects and avoids exposing stale
high bits. It is not packed C layout: tagged unions, packed/bitfield declarations,
and representation-special layouts remain unsupported.

Aggregate `f32` and `f64` leaves follow the SysV i386 data layout. Every field
has four-byte alignment; `f32` occupies one word and `f64` occupies two adjacent
little-endian words, so no additional eight-byte alignment hole is inserted.
Field offsets, recursively inlined children, and final struct size use the same
four-byte aggregate alignment. One cross-object witness deliberately places an
`f64` at byte offset 4 in a 20-byte mixed float struct; another recursively
flattens three struct levels into a checked 48-byte argument/result. Local
initialization, nested field assignment/load, matching copies, reverse-order
cdecl publication, callee views, and hidden-sret publication/acceptance preserve
every leaf. This is an x87 sequential-layout claim, not packed structs,
recursive by-value cycles, unions, bitfields, vector fields, or arbitrary C ABI
parity.

`tests/run_i686_release_gate.sh` is the authoritative executable boundary for
this milestone. It first proves compiler and target identity, then invokes the
focused runtime and multi-object suites sequentially with
`ZAG_I686_REFERENCE_TOOLS=0`. Thus every mandatory result is produced by
`znc`'s ELF32 emitter, archive writer, and linker; host `ld`, `ar`, `cc`,
`readelf`, and `objdump` are not authority dependencies. Optional reference
inspection remains useful during backend development but cannot turn a failed
or unavailable self-hosted result into a pass.

The executable milestone matrix is intentionally narrower than full i686
language parity:

| Milestone boundary | Evidence | Status |
| --- | --- | --- |
| Compiler/target identity | the authority gate checks the `znc` edition identity, all three i686 aliases as ELF32 `EM_386`, explicit x86-64 as ELF64 `EM_X86_64`, and artifact-free rejection of unknown targets | fail-closed |
| 32-bit pointers and `usize` | the authority gate executes high-bit unsigned operations, pointer stride/bounds checks, and artifact-free host-width rejection cases | supported subset |
| SysV i386 scalar/callee boundary | six-word calls, x87 scalar returns, two-word `i64`/`u64`, recursively flattened acyclic sequential structs with supported leaves, hidden-sret copies, caller cleanup, frame locals, and callee-saved helper behavior execute | supported subset |
| Small-register and spill allocation | pressure and 256-byte-frame fixtures execute; outgoing arguments above 64 KiB and local spill frames above 1 MiB reject before artifact output | bounded deterministic allocator |
| Linux i386 syscalls | `exit`, `write`, `mmap2`, and `munmap` use `int 0x80`; lifecycle and error-path fixtures execute | supported subset only |
| ELF32 ET_REL and static linking | compiler-produced `R_386_PC32`, `R_386_32`, deterministic archives, malformed-input rejection, and W^X linked images run without a host compiler, assembler, archiver, or linker | supported subset |
| 32-bit execution environment | every executable assertion uses host i386 compatibility first and `qemu-i386` on loader failure when available | native-or-emulated gate |
| Full i686 target | public C ABI, arbitrary aggregate ABI, dynamic/TLS linking, broader runtime/syscall surface, complete type coverage, and external 32-bit distribution validation | not complete |

Until the final row is complete, public documentation must say Linux x86-64,
not full x86-family support.
The CLI never aliases i686 requests to ELF64.

The compiler-owned `_zag_write(fd, pointer, count)` primitive lowers to Linux
i386 syscall 4. It preserves EBX across the syscall and returns the kernel result
as a 32-bit scalar; higher-level formatting and string runtime support remain
outside this milestone.

Basic local structs use declaration-order layout with each supported leaf
occupying its SysV i386 word span. Normalized narrow integers, booleans,
32-bit integers/pointers, `usize`, and `f32` occupy one four-byte slot; `f64`
occupies two four-byte-aligned words. Acyclic child structs are recursively
inlined with checked offset/size arithmetic and a declaration-count recursion
bound; direct or mutual by-value cycles reject. Struct literals must initialize
every field; nested field loads and stores use fixed frame offsets. Matching
whole-local and sub-struct copies are supported. Unions, packed/bitfield layouts,
and aggregate literals returned directly remain rejected.

The implemented SysV i386 aggregate-call subset passes basic structs containing
implemented sequential fields by value. The caller recursively pushes leaves in
reverse aggregate order, the first declared leaf appears at the lowest argument
address, and the caller removes the complete flattened argument area. Narrow
words are normalized both when published and observed; f32/f64 preserve their
one- or two-word little-endian representation. Struct parameters support nested
field loads. Struct returns use the SysV hidden result-pointer convention: the
caller supplies flattened storage, the callee returns that pointer in EAX, and
the callee pops the hidden word with `ret 4`; the caller validates each leaf
view. Recursive cycles, unions, aggregate literals returned directly, and
mutation through by-value parameters reject before artifact output.

The bounded byte-slice ABI uses two 32-bit words, pointer followed by length in
SysV stack order, and EAX/EDX for pointer/length returns. The current subset
supports `[]u8`/`String` literals, locals, arguments, returns, `.len`, and
the standard `\\`, `\"`, `\n`, `\r`, `\t`, and `\0` byte escapes, plus
`_zag_print`; literal bytes are embedded without an external linker. Slicing,
mutation, allocation, ownership transfer, and general string-library operations
remain rejected. Slice storage is borrowed/static and introduces no reclamation
claim.

`_zag_println_i32(value)` formats the complete signed 32-bit range into a
bounded stack buffer, appends a newline, and writes it without libc. Its encoder
preserves EBX, ESI, and EDI and returns the raw write result. General string
literal/data-section printing is not implied by this integer primitive.

The scalar `!i32` subset has a two-word logical ABI carried in EDX:EAX:
EDX is zero for success or a stable nonzero error code, and EAX is the success
value (zero on failure). Calls materialize both IR words, plain `catch` merges
them to one scalar, and `try` returns the same pair immediately on failure.
Error capture (`catch |e|`) and non-scalar error payloads remain unsupported.

ELF32 executables include a non-loaded section table for `.text`, `.shstrtab`,
`.strtab`, `.symtab`, and a minimal valid DWARF v2 `.debug_line`. Global `_start`
and `main` function symbols are published. These inspection/debug sections do
not alter the PT_LOAD bytes.

`--target i686 --emit-obj` emits a real ELF32 `ET_REL` object. An object that
defines `main` includes an `_start` stub which references global `main` through
`R_386_PC32`. Compiler-produced objects publish supported `pub` function
definitions as strong globals and unresolved supported `extern fn` calls as
global references with `R_386_PC32` relocations, so a main object and a separate
library object can be linked and executed without handcrafted fixture bytes.
Direct executable emission still rejects unresolved externs. `.rel.text`,
`.symtab`, string tables, and `.debug_line` are self-hosted output. Reference
`ld -m elf_i386` linking is an optional test only and is never a compiler
dependency.
`--link-i686` accepts multiple ELF32/i386 `ET_REL` inputs and deterministic
Unix archives. The pure-Zag linker merges allocatable `PROGBITS`/`NOBITS`
sections, resolves local, strong global, then weak global definitions, extracts
archive members on strong-global demand only, and applies `R_386_32` and
`R_386_PC32` relocations. A strong definition overrides every weak definition;
unresolved weak references use `S = 0` for both supported relocation formulas.
`SHN_ABS` symbols retain their absolute values for both supported relocation
kinds instead of being rebased as image-relative section symbols.
Every relocation offset and every section-defined symbol value/size is validated
against its target input section before layout or patching, so malformed objects
cannot redirect a relocation or symbol address into an adjacent merged section.

`--emit-static` wraps the deterministic Zag object in a GNU-compatible archive.
`--link-i686` emits a runnable ELF32 executable without `ld`, `ar`, a C
toolchain, or another compiler. Duplicate regular strong definitions and
unresolved non-weak symbols are hard errors naming the symbol. Bounded global
and weak `SHN_COMMON` declarations are merged by name into zero-filled RW
storage using the maximum requested nonzero size and power-of-two alignment;
alignment is capped at 4096 bytes and allocation shares the 64 MiB image cap.
An included regular strong definition wins over COMMON. Archive scanning follows
normal input order: an included strong COMMON satisfies demand, and weak COMMON
does not extract an archive member. COMDAT/groups, TLS, dynamic relocations,
linker scripts, and other relocation kinds fail closed rather than entering the
supported subset accidentally. Weak support does not add dynamic-linking, TLS,
COMDAT, or broader ELF linker semantics. Unknown relocation kinds are rejected
during input preflight, before symbol resolution; invalid symbol section indices
reject as corrupt metadata before traversal.
The bounded linker accepts at most a 64 MiB aggregate input/image and a
4096-byte maximum allocatable-section alignment; oversized input rejects before
the output image is allocated or written. These limits protect compiler memory
reliability and are part of this deliberately small static-link contract.

The milestone maps executable allocatable sections into an RX `PT_LOAD` and
non-executable allocatable sections into a page-separated RW `PT_LOAD`.
`R_386_32` and `R_386_PC32` are applied using the final split-image virtual
addresses. The regression suite executes a cross-object text-to-data reference
and, when `readelf` is available, verifies that no loadable segment is both
writable and executable. This is W^X hardening for the supported static subset,
not a claim of complete i686 linker parity.

## Release evidence

Any performance report records hardware, kernel, resolved feature set, compiler
commit, source/input, exact commands, run count, distribution/variance and output
equivalence. A speed result never substitutes for generic compatibility,
self-hosting fixpoint, ABI or release-gate correctness.
