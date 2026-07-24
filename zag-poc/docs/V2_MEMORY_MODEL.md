# Zag v2 memory model (draft)

Checked references/slices remain the default.  Raw pointers are `*const T`,
`*mut T`, and `*opaque`; nullable raw pointers use `?*const T`/`?*mut T`.
Address-space qualification is part of the pointer type (`*device T`,
`*workgroup T`, `*host T`).  A raw dereference, pointer arithmetic,
integer-pointer conversion, unchecked slice construction/indexing, volatile
access, MMIO access, and provenance-erasing cast require `unsafe`.

Pointer add/subtract scales by `size_of(T)`, is defined only within one live
allocation plus one-past, and traps in checked instrumentation otherwise.
Difference/comparison across allocations is rejected except equality against
null.  Misalignment is rejected or traps; byte pointers are the explicit route
for byte arithmetic.  Reallocation invalidates old pointers.  Use-after-free,
double-free, and invalid-free are undefined in release unsafe code but detected
by the debug allocator where practical.

`size_of`, `align_of`, `offset_of`, explicit representation, field alignment,
packed representation, and endian conversion are compile-time operations with
target-specific layout only under an explicit ABI representation.  Padding is
initialized before safe observation; packed field access is lowered safely or
requires unsafe.

Allocation is through an explicit `Allocator` value: allocate, allocate_zeroed,
resize, and deallocate.  Failure returns an error union.  `Alloc` covers both
allocation and reclamation because either may call allocator/OS code; arenas and
fixed-buffer allocators may be `@noalloc` after construction.  `@realtime`
rejects allocator calls unless a statically identified fixed-buffer allocator
is used and its operation is proven nonblocking.

## Status and edition boundary

This is a v2 (`edition = "2027"`) contract, not a description of current v1
`*T` lowering. The compiler now accepts qualified and nullable raw-pointer
types, requires explicit optional unwrapping before nullable dereference,
rejects casts between distinct generic/host/device/workgroup address spaces,
executes bounded native dereference cases, rejects dereference outside unsafe,
rejects writes through `*const`, and performs an edition-2027 static ownership
flow pass. That pass follows direct local aliases of compiler-recognized
allocations, rejects double-free and use-after-free through those aliases,
requires every discovered owner to be released or returned on every
control-flow path, and rejects an owned value passed to an uncontracted call.
Calls that receive an owner must explicitly declare `@borrows`,
`@borrows_mut`, or `@consumes`; this makes ownership transfer and retention
inspectable instead of implicit.

This is still a conservative intraprocedural static analysis, not universal
runtime memory instrumentation. Its provenance identity is a compiler-tracked
local allocation root; dynamic bounds, arbitrary pointer arithmetic, heap-wide
alias identity, alignment checks, allocator handles, interprocedural summaries
beyond the three contracts, and runtime use-after-free detection remain
unimplemented. v1 pointer indexing and `new`/`delete` extensions are not
evidence that those stronger rules already hold.

## Pointer categories and lifetime

`*const T` observes an object but does not permit mutation through that pointer;
`*mut T` permits mutation subject to the aliasing contract; `*opaque` carries an
address but cannot be dereferenced without an explicit checked conversion.
Function pointers are separate from data pointers.  Slices are `{ data, len }`
and always retain a length; they are neither nullable pointers nor C strings.
The optional form `?*mut T` represents null explicitly.  An address-space is a
semantic qualifier, not a castable annotation.

Every pointer derives from a live allocation, static object, or a documented
target object such as an MMIO region.  Derived pointers retain that allocation's
provenance and bounds.  A pointer becomes invalid when its allocation is freed;
all derived pointers become invalid on a successful resize that moves storage.
Safe code cannot create a pointer without a checked origin.  Unsafe integer
conversion creates an *untrusted* pointer that may only be dereferenced when
the unsafe caller satisfies alignment, extent, lifetime, address-space, and
access-permission preconditions.

## Operations and failures

`p.add(n)`, `p.sub(n)`, and `p[n]` use element counts.  `p.byte_add(n)` is the
explicit byte operation and is only available on byte/opaque pointers.  A
nonzero operation on null, an operation outside `[base, one_past]`, subtracting
or ordering pointers from distinct allocations, and a pointer difference that
does not fit the result type are rejected in checked builds and trap in
instrumented unsafe code.  Equality is defined for any two pointers; ordering
is defined only within one allocation.  Zero-sized types, if admitted, have no
implicit address stride: their indexing contract must be explicitly specified
by the type implementation before support is claimed.

Raw dereference validates neither lifetime nor dynamic bounds in a release
unsafe build.  A misaligned access, invalid provenance, or use after free is
therefore *unsafe programmer responsibility*, not ambient safe-language
undefined behavior.  Checked/debug modes trap before the access where the
implementation can prove or instrument the violation.  The language reserves
true undefined behavior for violating an explicitly documented unsafe contract;
ordinary safe operations instead reject or trap.

## Layout, representation, and byte order

The default representation is portable only at the level promised by the v2
language specification.  `repr(C)`, `repr(packed(N))`, and explicit alignment
are target/ABI commitments and may be used only where their target restrictions
are met.  `offset_of` is available only for a named field whose representation
is fixed.  Reading a packed field is lowered as an unaligned byte operation or
requires unsafe; it is never silently emitted as an invalid aligned load.

Exact-width integers use two's-complement representation.  Endian conversion
is explicit (`to_le`, `from_be`, and equivalents); native byte order may not be
inferred from an FFI declaration.  Safe construction initializes every
observable field and padding is not a readable semantic value.  FFI exports
must initialize any ABI-observable padding according to the selected ABI
contract.

## Allocation and bulk memory operations

An allocator operation returns `!Allocation`/`!void` rather than null-on-error.
`resize` has a single ownership-neutral contract: on failure the old allocation
remains live and owned by the caller; on success it returns the sole current
allocation handle.  `deallocate` consumes that handle.  `copy` permits overlap
and has memmove semantics; `copy_nonoverlap` requires unsafe and rejects overlap
in debug instrumentation.  Slice indexing traps with a stable bounds diagnostic;
`get_unchecked` requires unsafe.  These choices allow optimizers to remove a
check only after proving the same trap-or-value behavior.
