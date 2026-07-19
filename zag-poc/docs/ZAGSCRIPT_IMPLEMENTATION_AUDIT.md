# Zag Script implementation audit

Status: architecture record updated through the first working Zag Script and
Linux `zagd` implementation, 2026-07-18. The sections retain the pre-change
evidence and distinguish it from later implemented behavior and remaining gaps.

## Pre-change baseline

The clean `zag-v2-machine-control` worktree was verified before implementation
with `znc 2026.07.0-dev (edition 2026)`. The required gates passed:

- `tests/run_native_authority.sh`: `pass=7 fail=0`
- `tests/run_native.sh`: `pass=133 fail=0` (native edge: `pass=33 fail=0`)
- `tests/run_native_gpu.sh`: `pass=5 fail=0`
- `tests/run_native_wasm.sh`: `pass=17 fail=0`
- `tests/run_native_total.sh`: `pass=8 fail=0`

These totals describe their actual gate boundaries. The GPU MLIR case checks
frontend structure rather than runtime launch, and the WASM gate explicitly
marks runtime scenarios unsupported where the pure-Zag WASM runtime does not
exist. They are not broader execution claims.

## Current compiler path

The supported compiler is `selfhost/native/znc.zag`. It reads a root source,
lexes and parses it, runs shared declared-type checks, semantic/effect analysis
and the static analyzer, lowers through `selfhost/native/ncodegen.zag`, encodes
instructions in `selfhost/native/x86.zag`, and writes an ELF64 executable with
`selfhost/native/elf.zag`. The supported path is self-hosted Zag and uses Linux
syscalls directly; it does not require a host C compiler, assembler, linker,
LLVM, Zig, Python, or libc.

## 1. File-level syntax

`selfhost/lex.zag` produces tokens. `resolve_src` in `selfhost/parse.zag` parses
each file's top level. It currently accepts imports, link directives, functions,
constants, structs, enums, unions, error declarations, operator contracts and
interfaces. Any executable statement at file scope reaches diagnostic E0010.
There is no parsed module object and no script-profile bit.

Required change: parse exactly one root-level `script;` declaration, retain its
source location, and represent profile and root statements explicitly. The
parser must continue rejecting top-level statements in regular modules.

## 2. AST declarations and statements

`selfhost/ast.zag` defines one tagged union, `Node`. Declaration variants include
`fn_decl`, `struct_`, `enum_`, `union_`, and `link_dir`. Statement variants
include `let_`, `ret`, `if_`, `while_`, `break_`, `continue_`, `unsafe_`,
`assign`, `estmt`, and `switch_`. Function bodies are `ArrayList[*Node]`.
`parse_program_dir` currently returns a flat `ArrayList[*Node]`, so file identity,
profile, and root statements are not preserved as first-class compilation data.

Required change: add a compilation/module representation containing profile,
declarations, root statements, root identity, and source metadata. Reuse the
existing statement nodes and `parse_stmt`; do not create a second parser or AST.

## 3. Entry discovery and lowering

`lower_program_mode` in `selfhost/native/ncodegen.zag` builds a function symbol
table and looks up the literal name `main`. It emits `_start` first, preserves
the kernel entry stack pointer in `r15`, calls `main`, places the return value in
the Linux exit status argument, and invokes syscall 60. Missing `main` is a
native-codegen error. Normal execution begins at `fn main() i32` or
`fn main() void` as specified by the v1 language specification.

Required change: before ordinary semantic and backend lowering, synthesize a
collision-proof internal script-body function and an outer process-entry
wrapper only for the selected root script. Imported script bodies must not be
merged into executable root work. A regular module must retain the current
literal-`main` behavior.

## 4. Allocation today

The language has `new`, `delete`, `zalloc`, `_zag_malloc`, `_zag_realloc`, and
`_zag_free` paths. Native support routines use raw `mmap`/`munmap`; the current
backend includes a size-class/free-list allocator and reallocating helpers.
Some older `zalloc` paths are documented in code as retaining mappings. Stack
locals occupy compiler-assigned frame slots. There is no ownership checker,
borrow checker, garbage collector, RAII, destructor system, or general lifetime
inference. Allocation failure and bounds behavior are not yet a complete
language-wide safety boundary.

Required change: a script allocator must be explicit in runtime state, bounded,
fail observably, and used only by script conveniences. The implemented bounded
bump arena retains charged payload until generated shutdown and then unmaps its
complete mapping. It does not replace explicit allocation in imported strict
libraries.

## 5. Runtime helpers

Native codegen conditionally emits syscall-based helpers for stdout/stderr,
integer and float formatting, allocation/reallocation/free, string operations,
arguments, file existence/read/write, time, environment access, and process
execution. `selfhost/std/io.zag`, `process.zag`, `collections.zag`, `strbuf.zag`,
and related modules provide ordinary Zag wrappers. Process execution currently
includes a shell-oriented wrapper; a script process API with a mandatory or
bounded timeout is not yet present.

Required change: implement the script prelude as ordinary documented Zag
declarations backed by these primitives. Do not implicitly expose all of std.

## 6. Safety properties currently enforced

The semantic pass computes transitive effect bitsets and checks claims including
`@pure`, `@noalloc`, `@realtime`, and `@total`, with witness diagnostics for
represented violations. Shared typed checks reject tested representation and
declared-type mismatches. Capturing closures are documented and checked as
stack-bound in supported cases. The native backend has regression coverage for
specific ABI, allocator, exact-width memory access, diagnostics, and semantics.
These are scoped compiler properties, not a proof of whole-language memory
safety.

## 7. Safety properties not implemented

There is no complete ownership, borrowing, provenance, alias, lifetime,
automatic reclamation, concurrency memory model, exception unwinding, or
target-complete trap specification. An arena does not establish any of these.
Script lifetime escape checking, bounded script allocation, capability policy,
timeout-enforced process execution, structured top-level error reporting, and
automatic CPU/GPU placement are not implemented. Documentation and diagnostics
must describe these gaps without converting estimates or conventions into
proofs.

## 8. Native x86-64 to ELF

`ncodegen.zag` lowers AST to the target-neutral-in-name but currently
x86-oriented `Instr` representation in `isa.zag`. Register promotion,
optimization, and peephole passes operate on that instruction list. `x86.zag`
encodes bytes. `elf.zag` writes little-endian ELF64 headers, load segments,
entry address, text, read-only data, and allocator/runtime BSS directly. No
external assembler or linker is involved on this path.

## 9. Imports and merged modules

`@import` is resolved during parsing. Ordinary unqualified imports merge
declarations into one flat stream; qualified imports rewrite names to qualified
internal forms. `std:` imports resolve to compiler-owned standard-library
locations. Circular imports are diagnosed, and `zag.mod` dependencies are
validated. Because the current result loses per-file module boundaries, script
work must preserve root-vs-import identity before merging. Public declarations
from a script module may be imported, but its root statement list must never be
spliced into the importing program's executable body.

## 10. Incremental-cache candidates

The lexer/parser, import graph construction, shared typing, semantic/effect
analysis, static analysis, function-level native lowering, encoded machine code,
and final ELF assembly are separable cache candidates. Today their APIs largely
consume mutable flat lists and process-global-style compiler state; stable
content hashes, declaration identities, dependency edges, serialized facts,
and target-keyed cache records do not yet form a correctness boundary.

Cache reuse must be validated against source hashes, compiler version, target,
feature profile, public signatures/layouts, dependencies, and relevant options.
A cache miss or corrupt cache must fall back to ordinary compilation.

## 11. Required Zag Script changes

1. Introduce explicit module/profile/root metadata without a second language.
2. Parse `script;` and root statements through the existing lexer/parser.
3. Preserve module identity across import resolution.
4. Synthesize internal script body and wrapper before normal sema/codegen.
5. Add a bounded `ScriptContext` and minimal prelude using ordinary Zag APIs.
6. Add profile-aware diagnostics, error boundary, explain, strict-check and
   conservative hardening reports.
7. Add tests for parsing, lowering, imports, runtime limits, errors and CLI.
8. Add content-addressed analysis records usable by `zagd` but never required
   for a correct foreground build.

## 12. Regular Zag invariants

Regular Zag retains declaration-only file scope, explicit `main`, current
allocator selection, explicit device and layout choices, import semantics,
effect rules, ABI, native lowering, and CLI build form. It receives no generated
entry point, implicit prelude, source rewrite, hidden long-lived script runtime,
automatic concurrency, or daemon dependency. Explicit choices always outrank
planner advice. Existing passing gates remain release requirements.

## Implementation delta

Items 1 through 4 and the initial parts of 5 through 8 now exist in the ordinary
self-hosted path: explicit Script profile metadata, root statements, generated
managed entry point, bounded `script_alloc`, root-only overrideable prelude,
error boundary, `explain`, focused strict checks, conservative hardening,
inotify snapshots and fail-closed advisory cache records. Regular Zag retains
the invariants above and planner output remains advisory.

The remaining safety boundary is explicit. Compiler-owned Script payloads now
come from one bounded mapping that is reclaimed at generated shutdown. The
Script allocation budget counts
Script collection/string/file-result/bounded-process payloads and root top-level
`new`, but not ordinary `make`, imported strict allocation, allocator metadata,
or file-reader staging.
There is no ownership/borrowing proof, reclamation for allocations outside the
Script arena, general JSON
object/array prelude, or complete source-to-runtime lifetime analysis. Named
top-level errors and source paths, bounded process capture, statically typed
Script lists, scalar JSON, project-configured supported defaults, and stable
background semantic rechecks are implemented. Restart reuse validates snapshot
metadata and declaration fingerprints but does not restore a complete semantic
caller/layout/codegen dependency graph. Adaptive/deep candidates have bounded
deterministic budgets and consume only checksum-bound proven facts; broad deep
search, PGO, SIMD tuning, and microbenchmark selection are not implemented.
