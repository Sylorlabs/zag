# Zag Script semantics

Status: semantics contract with an implemented foundation, 2026-07-18. Profile
activation, root lowering, managed shutdown, requested-payload limits, the small
documented prelude, explain, conservative hardening, and strict rejection have
focused tests. Statements describing arguments, typed collections, process,
JSON, ownership, or full allocation accounting remain design requirements.

## Profile activation

Zag Script is a compilation profile of Zag, not a separate language. A root
`.zag` file activates it with exactly one declaration:

```zag
script;
```

`znc script file.zag` selects the same internal profile. If source and CLI
selection disagree, selection remains script and the compiler reports the
redundancy in `explain`; it must not create two script bodies.

`script;` may follow comments and file directives but must precede executable
root statements. A duplicate is an error. A script root that declares a
user-visible process `main` is rejected until an explicit, unambiguous coexistence
rule is designed. Filename extensions do not select semantics.

## Root statements and imports

Only the selected root script executes root statements. They execute once, in
source order. An imported script contributes only importable public
declarations; importing it does not run its root statements. A regular source
file continues to reject executable file-scope statements.

The compiler lowers the root statements into a compiler-owned function whose
identity cannot collide with source identifiers. The name is not addressable,
importable, or part of the public ABI. A generated outer entry point initializes
runtime state, invokes the body, handles an uncaught error, flushes output,
reclaims safely reclaimable script resources, and exits deterministically.

## Script context and allocation

The current internal context contains allocator accounting and its limit. Process
arguments, environment/capability views, and richer error-reporting state remain
future fields; they are not fabricated as empty APIs. It is not a dynamic object
environment.

The initial default is a bounded Script-lifetime bump arena. Charged payload
remains retained until the generated shutdown boundary, which unmaps the whole
arena deterministically. The configured limit covers explicit `script_alloc`,
Script collections/builders/string concatenation, returned `read_file` data, and
bounded-process setup, capture capacity, result handles, and compiler-owned `new`
in root top-level statements. Ordinary `make`, allocator metadata, temporary
file-reader staging, and imported strict `new` remain outside it. A direct
allocation beyond the limit returns null; prelude file/process operations also
emit an operation-specific diagnostic. Imported strict code receives no implicit
allocator. An explicit allocator or resource policy in source wins over the
script default.

This policy does not make Zag memory-safe. Pointer validity, aliasing, ownership,
and many lifetime obligations remain the programmer's responsibility. Escape
diagnostics may claim only the specific cases the compiler checks and must have
negative tests.

## Prelude

The implicit prelude is a small allowlist. Each name resolves to an ordinary,
documented Zag declaration with an explicit strict-Zag equivalent. The implemented
allowlist is `print`, `println`, `read_file`, `write_file`, `args_len`, `arg`,
`string_concat`, `script_alloc`, `script_alloc_used`, `process_run_timeout`,
`string_builder`, and `list`. A materialized argument collection and implicit
JSON bindings remain candidates rather than hidden behavior.

Collections remain statically typed. The compiler may infer one element type
when unambiguous. Mixed incompatible elements are rejected. Growth, copies and
allocation are reportable by `explain`; implementations must avoid undocumented
quadratic growth. No default universal `any` value is introduced.
The implemented `ScriptList[T]` grows geometrically, charges each replacement
buffer to the Script context, and retains superseded arena buffers until process
shutdown. Construction accepts one to four values of a single inferred type.

## Errors and effects

Normal `!T`, `try`, and `catch` semantics remain in force. The generated script
body may propagate an error to its outer wrapper. An uncaught error prints its
name, operation and best available source location or witness path, flushes
diagnostics, and exits nonzero. Errors are not silently changed to null or a
success status.

Prelude operations carry the same ordinary effects as their strict declarations.
Filesystem, process, network and device access are capabilities, not inferred
permission. Project policy keys `allow_filesystem_read`,
`allow_filesystem_write`, and `allow_process` accept `true` or `false`; the
foreground compiler rejects a Script prelude operation when its policy is
false, independently of whether `zagd` is running. Defaults preserve the local
Script prelude and projects can deny each capability without source changes.
Network access remains unavailable rather than implicitly permitted.

## Progressive explicitness

`explain` is read-only and reports activation, generated entry behavior,
allocator, inferred types/effects, error boundary, capabilities, limits,
allocations/copies, execution plan and unresolved decisions. Each fact is tagged
`proven`, `derived`, `measured`, `estimated`, or `unknown`. JSON uses stable keys
and contains the same facts as text output.

`harden` is non-destructive by default. Its first implementation may produce a
preview, patch, candidate source, assumptions, required parity tests and honest
unsupported items. It must not pretend an incomplete conversion is strict Zag.
`--output` writes a separate file. `--apply` requires an unchanged source
snapshot, an explicit parity-test command, a rollback copy, and restores the
original automatically when validation fails. It never silently skips the
parity test. A clean Git worktree is still recommended but is not fabricated as
compiler proof.

`check --strict` rejects unresolved script conveniences, including implicit
allocator or capabilities, unbounded process execution, implicit randomness,
escaping script temporaries, and unresolved device choice when those constructs
occur. It does not change source.

## Planner authority

The planner may choose only details deliberately unspecified by a script, such
as bounded default allocation or compiler-owned temporary layout. An explicit
allocator, CPU/device selection, or layout always wins. Planner output cannot
change public layouts, observable ordering, effects, error behavior, or ABI
without an accepted explicit transformation and equivalence evidence.

## Compatibility boundary

Without profile activation, all existing Zag rules remain unchanged. `zagd` is
never required for parsing, checking, compiling or running. Cache state and
planner availability cannot affect program correctness.
