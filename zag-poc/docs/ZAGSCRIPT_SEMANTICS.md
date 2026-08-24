# Zag Script semantics

Status: semantics contract with an implemented foundation, 2026-07-24. Profile
activation, root lowering, managed shutdown, bounded allocator policies, the small
documented prelude, explain, conservative hardening, and strict rejection have
focused tests. Arguments, typed collections, bounded process capture, typed JSON,
and the documented Script-default allocation paths are implemented. General
ownership, borrowing, and accounting inside explicitly strict imported code
remain outside the Script profile's guarantees.

## Profile activation

Zag Script is a compilation profile of Zag, not a separate language. A root
`.zag` file activates it with exactly one declaration:

```zag
script;
```

`znc script file.zag` selects the same internal profile. If source and CLI
selection disagree, selection remains script and the compiler reports the
redundancy in `explain`; it must not create two script bodies.

The optional `.zs` suffix also selects that same profile. It may omit the
physical `script;` marker; the compiler activates the profile in memory and
does not rewrite the file. The indentation-oriented surface first enters a
lossless CST that retains exact bytes, CRLF/LF choice, comments, trailing
whitespace, indentation, byte spans, and deterministic origin IDs. A projection
with complete generated-range coverage then emits ordinary Zag tokens for the
existing parser. It does not introduce a second AST, type system, module graph,
package ecosystem, or backend. Parser nodes project through that ledger into
compact-source byte ranges across root and imported modules. Byte-identical
segments carry `exact=1`; rewritten indentation constructs carry `exact=0` and
a sound enclosing compact range. Compiler-synthesized wrappers remain
explicitly unlocated rather than receiving invented source locations.

`script;` may follow comments and file directives but must precede executable
root statements. A duplicate is an error. A script root that declares a
user-visible process `main` is rejected until an explicit, unambiguous coexistence
rule is designed. Except for the explicit `.zs` convenience, filenames do not
select semantics.

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

The compiler-owned native context explicitly records process argument metadata,
a read-only environment-view policy, capability bits, memory/process limits,
the selected allocator/CPU/device/layout policy ids, allocator accounting and
policy-specific backing state, runtime state, and the uncaught-error reporter policy. Foreground
compilation derives the capability bits from project policy and the execution
ids from resolved defaults or explicit CLI choices. Native initialization
rejects unknown policy ids before allocating the context.

This metadata is not a dynamic object environment. Arguments remain available
through the implemented argument helpers. `env("NAME")` is the one narrow
Script convenience: `NAME` must be a literal simple identifier and be present
exactly in the root project's `environment_allow` list. The default empty list
denies all environment lookup. Its returned read-only process-environment view
is capped at 4096 bytes; unset or oversized values are empty. It allocates no
Script-arena bytes and does not add an implicit environment API to imported
strict libraries. Network and device capability bits remain disabled because no
Script prelude operation implements them.

The memory limit and allocator state are consumed by current native Script
allocation paths. Filesystem/process permissions are enforced by the foreground
compiler for compiler-bound root conveniences; the stored bits are not a
sandbox for arbitrary strict-library calls or raw syscalls. The process-count
and default-timeout fields are policy metadata, while the implemented process
convenience enforces its explicit per-call timeout and output bound. CPU,
device, and layout ids do not imply GPU placement, parallel execution, or a
layout rewrite.

The default `script_process_arena` policy is a bounded Script-lifetime bump
arena. Charged payload remains retained until the generated shutdown boundary,
which unmaps the whole arena deterministically. The supported explicit
`script_bounded_heap` policy instead creates one compiler-tracked native block
per successful Script allocation and returns every complete block to the native
allocator at generated shutdown. Select it with
`--script-allocator script_bounded_heap` or
`allocator=script_bounded_heap` in `.zagd.conf`; the command-line choice wins.
Its budget charges requested payload plus a 16-byte ownership header for every
allocation, including a zero-length request, so tiny requests cannot bypass the
limit. Native size-class slack remains visible in native allocator telemetry
but is not included in `script_alloc_used()`. Both policies retain Script
values until shutdown and expose no individual Script free operation.

Under the default arena, the configured limit covers explicit `script_alloc`,
Script collections/builders/string concatenation, returned `read_file` data, and
bounded-process setup, capture capacity, arena-resident result handles, and
compiler-owned `new`
in root top-level statements. The bounded heap routes those same
compiler-bound allocation calls through its tracked blocks and adds the
per-block header charge, including the 32-byte process-result handle (48 charged
bytes and one tracked native block). Ordinary `make` in a Script root is rejected
because it cannot be charged; use a Script collection/builder, `script_alloc`,
or an explicit strict-Zag allocator. Allocator metadata, imported strict
`make`, and imported strict `new` remain outside the Script budget and are
never silently redirected. `read_file` first rejects non-regular files and a
size above the Script slice limit, then allocates exactly one charged Script
destination and reads directly into it. It never stages full file contents in
the ordinary native allocator. Its only native temporary is a NUL-terminated
path bridge of at most 4097 bytes; it is released immediately after each
`open(2)` and is deliberately outside Script payload accounting. A read which
fails after the Script destination was acquired leaves that charged allocation
owned by the Script context until generated shutdown, as every Script arena
allocation does. A direct
allocation beyond the limit returns null; prelude file/process operations also
emit an operation-specific diagnostic. Imported strict code receives no implicit
allocator. A supported explicit command-line allocator choice wins over the
project Script default.

Values originating from either Script allocator policy have a distinct
compiler-tracked provenance in root Script statements. They must not be passed
to `delete` or `_zag_free`: an arena address has no native allocation header,
and a bounded-heap value points after a compiler-owned ownership header rather
than at the native allocation boundary. The compiler rejects that operation;
generated Script shutdown is the sole owner of policy-specific reclamation.
This is a specific provenance check, not a general ownership or use-after-free
system.

This policy does not make Zag memory-safe. Pointer validity, aliasing, ownership,
and many lifetime obligations remain the programmer's responsibility. Escape
diagnostics may claim only the specific cases the compiler checks and must have
negative tests.

Outside the Script context, the native allocator exposes allocation-event,
current-live-payload, and peak-live-payload observers used by regression and
benchmark suites. Headerless `zalloc` and cache-aligned mappings are paired
with a bounded pointer/size registry. A copied descriptor's second free, a
corrupt size, registry exhaustion, or failed unmap terminates with a diagnostic
instead of silently unmapping twice or underflowing those counters. This is
runtime instrumentation for supported native allocation paths, not arbitrary
pointer provenance or a language-wide ownership proof.

The compiler computes bounded, monotone lifetime summaries for every defined
helper reachable in the merged module graph. A summary records whether a helper
returns a Script-lifetime value or may retain one through a field, pointer,
nonlocal assignment, extern/unknown call, or another escaping helper. Scalar
content such as a capacity, length, or index does not itself create address
provenance; unresolved, pointer, slice, aggregate, and generic parameter types
remain conservative. This covers helper chains, returned values, and imported
source helpers. Recursion is handled by a declaration-count-bounded fixed point.
Passing a Script value to an extern or unresolved function remains a conservative
error. These summaries prove only those escape classes; they are not general
ownership or borrow checking.

Edition-2027 strict Zag additionally has an opt-in static ownership slice for
named allocation origins and explicit `@consumes`, `@borrows`, and
`@borrows_mut` contracts. It rejects tested double/use-after-free paths,
uncontracted escapes, live-owner overwrite, mixed owned/non-owned returns, and
invalid borrow aliasing across supported control-flow joins. It also rejects
the tested callee-frame addresses returned directly or through named
pointer-carrying aggregate aliases. Mutation-aware container provenance,
globals, callbacks, and arbitrary heap graphs remain outside this proof. Zag
Script does not silently turn that bounded checker into a universal guarantee.

## Prelude

The implicit prelude is a small allowlist. Each name resolves to an ordinary,
documented Zag declaration with an explicit strict-Zag equivalent. The implemented
allowlist is `print`, `println`, `say`, `input`, `env`, `read_file`,
`write_file`, `args_len`, `arg`, `args`, `path_join`, `path_basename`,
`path_dirname`, `path_extension`, `string_concat`, `script_alloc`,
`script_alloc_used`, `process_run_timeout`, `string_builder`, and `list`.
`args()` materializes a typed `ScriptList[[]u8]` charged to the Script
allocator; argument bytes continue to borrow immutable process storage.
Implicit JSON bindings are not provided: basic JSON remains an ordinary,
explicit standard-library API.

Collections remain statically typed. The compiler may infer one element type
when unambiguous. Mixed incompatible elements are rejected. Growth, copies and
allocation are reportable by `explain`; implementations must avoid undocumented
quadratic growth. No default universal `any` value is introduced.
The implemented `ScriptList[T]` grows geometrically, charges each replacement
buffer to the Script context, and retains superseded Script allocations until
generated shutdown. Construction accepts one to four values of a single
inferred type.

## Errors and effects

Normal `!T`, `try`, and `catch` semantics remain in force. The generated script
body may propagate an error to its outer wrapper. An uncaught error prints its
name, operation and best available source location or witness path, flushes
diagnostics, and exits nonzero. Errors are not silently changed to null or a
success status.

The current statement AST retains the source file but not expression line/column
spans. The wrapper therefore reports the exact root source path and, when the
failing boundary is a top-level `try call(...)`, the callee name preserved by
that AST. It explicitly says when an expression witness is unavailable and does
not fabricate a line number or stack trace.

Prelude operations carry the same ordinary effects as their strict declarations.
Filesystem, process, network and device access are capabilities, not inferred
permission. Project policy keys `allow_filesystem_read`,
`allow_filesystem_write`, and `allow_process` accept `true` or `false`.
`environment_allow` accepts a comma-separated exact list of simple names (no
wildcards, prefixes, or dynamic lookup). The
foreground compiler rejects a Script prelude operation when its policy is
false, independently of whether `zagd` is running. Defaults preserve the local
Script prelude and projects can deny each capability without source changes.
Network access remains unavailable rather than implicitly permitted.

The compiler tracks values produced by compiler-owned Script allocation calls
through root locals. It rejects obvious storage through a field, pointer, or
nonlocal target and rejects passing those values to extern or unresolved calls.
Known Script consumers and defined local helpers remain usable. This is a
bounded escape check, not a whole-program ownership or borrowing proof; strict
promotion reports ordinary root `make` allocations that remain outside Script
accounting.

## Progressive explicitness

`explain` is read-only and reports activation, generated entry behavior,
allocator, inferred types/effects, error boundary, capabilities, limits,
allocations/copies, execution plan and unresolved decisions. Each fact is tagged
`proven`, `derived`, `measured`, `estimated`, or `unknown`. JSON uses stable keys
and contains the same facts as text output.

For compiler-bound root Script calls, `explain` also emits bounded
per-operation allocation/copy witnesses. Each witness names the operation,
whether it allocates from ScriptContext (or provably allocates/copies zero),
the best supported byte fact, copy behavior, provenance, and source-location
availability. The current AST deliberately does not retain statement spans, so
these witnesses report source location as `unavailable` with an `unknown`
basis rather than guessing from text. Dynamic sizes are `unknown`; the fixed
4096-byte input reservation and zero-copy path-slice helpers are reported only
because their runtime implementations prove those facts. The walk is capped at
64 witnesses and marks truncation. It does not infer allocations or copies in
imported strict libraries.

`harden` is non-destructive by default. Its first implementation may produce a
preview, patch, candidate source, assumptions, required parity tests and honest
unsupported items. It must not pretend an incomplete conversion is strict Zag.
`--output` writes a separate create-only derived artifact and never replaces
compact source. The legacy `--apply` mode is removed and rejects before source
loading, publication, or parity-command execution. Provenance-backed `promote`
is the only workflow that creates human-owned expanded source and its ledger. A
clean Git worktree is still recommended but is not fabricated as compiler proof.

When Script-context prelude calls remain, the report marks the preview
`partial` and `candidate_compilable=false`; promotion refuses it. This is an
honest boundary until allocator and capability expansion can produce ordinary
strict Zag without guessing policy.

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
