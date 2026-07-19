# Linux x86 target policy

Status: target-permission foundation, 2026-07-18. The supported native x86
target today is Linux ELF64 x86-64. Generic and native CPU profiles are
implemented; optional SIMD lowering, multiversioning, and i686 are not.

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
feature set. Future multiversioning may emit a generic version and one or more
qualified versions. Runtime selection checks the same required features,
chooses deterministically and caches the selected function target. Programs are
not required to use multiversioning.

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
loads/stores, addition, subtraction, assignment, and return. It emits a real
i386 stack frame and an ELF32 `EM_386` process using the 32-bit Linux exit
syscall. Signed comparisons, `if`/`else`, `while`, `break`, and `continue` use
explicit IR labels with checked relative-branch patching. Multiple non-generic
`i32` functions use a cdecl-like boundary: arguments are pushed right-to-left,
the caller removes arguments, and results return in EAX. EBP, EBX, ESI, and EDI
are callee-saved; current generated bodies use only EAX, ECX, EBP, and the stack.
`usize` is one 32-bit word. `*i32` and `*usize` use 32-bit addresses and support
addressing initialized frame locals, indirect loads/stores, and scalar argument
passing. Uninitialized pointers, unsupported pointer element types, imports,
and Script constructs fail before artifact creation. General completion still requires broader i386
aggregate calling conventions, pointer arithmetic, smaller-register-set allocation,
32-bit Linux syscalls, explicit rejection of 64-bit assumptions, target-specific
runtime tests and execution on real or emulated 32-bit Linux. Until those gates
pass, public documentation must say Linux x86-64, not full x86-family support.
The CLI never aliases i686 requests to ELF64.

The compiler-owned `_zag_write(fd, pointer, count)` primitive lowers to Linux
i386 syscall 4. It preserves EBX across the syscall and returns the kernel result
as a 32-bit scalar; higher-level formatting and string runtime support remain
outside this milestone.

Basic local structs use declaration-order layout with each supported scalar
field occupying one 4-byte word. Struct literals must initialize every field;
field loads and stores use fixed frame offsets. Aggregate calls and returns are
rejected: aggregate sharing uses explicit pointers until a by-value ABI exists.

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
not alter the PT_LOAD bytes. This is executable metadata, not yet an `ET_REL`
object format or static-library linker.

`--target i686 --emit-obj` emits a real ELF32 `ET_REL` object. Its `_start`
stub references global `main` through `R_386_PC32`; `.rel.text`, `.symtab`,
string tables, and `.debug_line` are self-hosted output. Reference `ld -m
elf_i386` linking is an optional test only and is never a compiler dependency.
Pure-Zag archive production and multi-object resolution remain separate work.

`--emit-static` wraps the deterministic Zag object in a GNU-compatible archive.
`--link-i686` consumes either that archive or a Zag-produced object, validates
the fixed section/relocation contract, applies `R_386_PC32`, and emits a runnable
ELF32 executable without `ld`, `ar`, a C toolchain, or another compiler. Foreign
objects, multiple archive members, and relocation kinds beyond this contract
fail closed rather than entering the supported subset accidentally.

## Release evidence

Any performance report records hardware, kernel, resolved feature set, compiler
commit, source/input, exact commands, run count, distribution/variance and output
equivalence. A speed result never substitutes for generic compatibility,
self-hosting fixpoint, ABI or release-gate correctness.
