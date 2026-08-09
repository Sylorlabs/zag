# Zag v2 language specification (draft)

Status: design contract; no feature in this document is implemented merely by
being specified.  V2 is a new edition and does not change edition-2026/v1.

## Edition and portability

`edition = "2027"` in the nearest ancestor `zag.mod` selects v2.  A source
without this field stays edition 2026.  The command-line edition/safety/sanitize
and target-feature spellings are rejected until their documented implementation
exists; they are never silently ignored.  V2 core semantics are portable only
where this specification says so; CPU instructions, OS APIs, linker formats,
and GPU backends are target extensions and require an explicit target/capability
declaration.

## Language tiers

1. Checked Zag: bounds, null, alignment, type, effect, and capability rules are
   enforced.
2. Explicit low-level Zag: layout/address-space/allocator operations with a
   statically checkable contract.
3. `unsafe { ... }`: lexically delimited operations whose dynamic validity is
   the programmer's responsibility.  Ordinary typing, effect checking, and
   target checks remain active.
4. `asm` and named target intrinsics: unsafe target extensions with explicit
   operands and clobbers.

## Core additions

V2 adds `unsafe` blocks/functions, raw pointer types, address-space qualifiers,
explicit allocator handles, atomics, volatile operations, `extern` ABI
declarations, target feature declarations, and kernel declarations.  Every
addition is rejected in edition 2026 with a diagnostic naming the required
edition.  Detailed normative rules live in the memory, unsafe, ABI,
concurrency, GPU, effect, and safety-tooling documents.

The implemented explicit-layout spelling is `@repr(C) struct Name { ... }`
(or `pub @repr(C) struct ...`). It is edition-2027-only and currently lowers
only integer/boolean/raw-pointer leaves for pointer access on Linux x86-64.
Direct by-value aggregate literals, locals, assignments, arguments, and results,
other representations, field categories, and targets reject before artifact
output; an ordinary `struct` does not inherit C layout. The exact boundary and
native evidence are specified in `V2_ABI.md`.

The current vertical slice implements dedicated lexical `unsafe { ... }` AST
nodes, direct `unsafe fn` declarations/calls, and the raw-pointer qualifier
forms `*const`, `*mut`, `*opaque`, `*device`, `*workgroup`, and `*host`. Raw
dereference is rejected outside unsafe, mutation through `*const` is rejected
in every scope, and calling an unsafe function requires an unsafe call site.
Unsafe blocks and direct calls infer the `Unsafe` effect, which `@pure` and
`@realtime` reject. Nullable raw pointers require explicit unwrapping before
dereference, and direct casts between generic, host, device, and workgroup
address spaces are rejected. Native x86-64 has a bounded unsafe volatile/MMIO
slice (`@volatileLoad`/`Store` and explicit 8/16/32-bit companions) with
checked width/alignment probes; full device capability validation remains
unsupported. Fixed unsafe i64 atomics, raw Linux `@atomicWait32`/`@atomicWake32`
futex building blocks, and a literal-validated load/store/RMW/CAS memory-order
subset are implemented, but atomic storage, typed fence order selection,
threads, and a complete concurrency model remain
unsupported. The only packed-SIMD operations are unsafe four-lane `i32`
addition, subtraction, AND, OR, and XOR through raw pointers on native x86-64;
vector value types, wider SIMD, and target-selected ISA variants remain
unsupported. Inline `asm` remains
fail-closed. Pointer provenance identity, bounds and alignment
instrumentation, source-span audit records, the complete device capability
model, and the complete
unsafe-operation inventory are not yet implemented.

## Error policy

Unsupported source is a hard diagnostic with nonzero exit status and no output
artifact.  Checked operations trap with a specified message/code where a static
rejection is impossible.  Unsafe operations are either defined, checked/trap,
or explicitly undefined by their owning specification; there is no ambient C
undefined behavior.

## Integer and conversion semantics

Fixed-width signed and unsigned integer arithmetic is checked by default.
Overflow, invalid shift count, and division by zero are compile-time errors when
constant and otherwise specified traps in checked and release builds.  Explicit
`wrapping_*`, `saturating_*`, and `checked_*` operations state the desired
alternative: wrapping is modulo 2^N, saturating clamps to the destination
range, and checked returns an error/optional result.  The optimizer may replace
a check only when it preserves the same value-or-trap behavior.

Narrowing conversion is checked; bit reinterpretation is a named, unsafe
operation when it can expose invalid representation or target byte order.
Signed values use two's-complement representation.  Floating-point operations
retain the target's specified IEEE behavior where implemented, while conversion
to an integer checks range and NaN unless an explicit unsafe/wrapping operation
is selected.

## Target selection and diagnostics

Target extensions are selected explicitly by target triple, CPU feature set, or
GPU backend name.  Selecting a feature does not promise runtime availability:
feature detection or an explicit deployment contract is required before use.
An unsupported target, instruction, ABI form, or device operation is a hard
diagnostic with its source span and target name; emitting comments, a placeholder
binary, or a syntactically valid but unexecuted intermediate file is not support.

Diagnostics include the source location, relevant type/operation, violated
rule, and a smallest intentional alternative where one exists (for example,
`unsafe`, `wrapping_add`, or a checked slice operation).  Capability diagnostics
also include their complete effect witness chain.
