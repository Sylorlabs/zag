# Zag v2 language specification (draft)

Status: design contract; no feature in this document is implemented merely by
being specified.  V2 is a new edition and does not change edition-2026/v1.

## Edition and portability

`edition = "2027"` in `zag.mod` selects v2.  A source without this field stays
edition 2026.  V2 core semantics are portable only where this specification says
so; CPU instructions, OS APIs, linker formats, and GPU backends are target
extensions and require an explicit target/capability declaration.

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
concurrency, GPU, and effect documents.

## Error policy

Unsupported source is a hard diagnostic with nonzero exit status and no output
artifact.  Checked operations trap with a specified message/code where a static
rejection is impossible.  Unsafe operations are either defined, checked/trap,
or explicitly undefined by their owning specification; there is no ambient C
undefined behavior.
