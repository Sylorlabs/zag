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
inspectable instead of implicit. Borrow and consume contracts track only their
first owner parameter, but may take later builtin scalar parameters such as a
length or count. Later pointers, aggregates, callbacks, slices, optionals, and error
unions remain rejected because they could carry an untracked second lifetime.
A separate return-lifetime check rejects
addresses of local values and local fields returned directly, through
direct aliases, or inside named pointer-carrying struct/union literals. A
direct `_zag_realloc(named_owner, size)` is modeled as an atomic ownership
transfer to the assigned result: both `let replacement = ...` and
`owner = ...` retire the old named root only when that result becomes the new
owner. This does not model failure-return ownership, aliased or computed
arguments, or general allocator APIs; those cases remain fail-closed or
unsafe-programmer responsibility.
bounded mutation-aware pass additionally follows owner and current-frame roots
stored in named struct/union values through 64 nested field components,
field/whole-value assignment, value copies, and conservative branch joins. It
rejects proven pass, return, and non-local store escapes; an overwrite clears
only the field subtree it proves replaced. The same aggregate rules permit a
pointer inherited from the caller because that pointer does not identify the
callee's frame.

This is still a conservative intraprocedural static analysis, not universal
runtime memory instrumentation. Its provenance identity is a compiler-tracked
local allocation root; arbitrary pointer arithmetic, heap-wide alias identity,
interprocedural summaries beyond the three contracts, arbitrary-depth or
heap-resident container provenance, and general global/callback/reference
lifetime proof remain unimplemented. In
`--safety=checked` native x86-64 builds, a bounded 3,072-entry
ordinary-allocation table
also validates null/alignment plus access width and freed-state for
`_zag_malloc`/`new`/`_zag_realloc` regions. That runtime table deliberately
passes through stack/static/foreign and untracked allocator-family pointers;
it cannot defeat raw-address forgery or same-address reuse, so it is not a
general use-after-free proof. Paths deeper than the bounded
field proof retain an uncertain provenance marker and fail closed until a
proven prefix or whole container is overwritten. This establishes only named
local aggregate provenance within the checked function, not general aggregate
or heap-graph provenance. v1 pointer indexing and `new`/`delete` extensions are
not evidence that those stronger rules already hold.

The checked native `SystemAllocator` is a separate, deliberately narrow
allocator-handle boundary. It returns fallible `Allocation` records carrying a
native pointer, exact reserved capacity, accepted alignment (1, 2, 4, or 8),
and a runtime-minted generation. `deallocate` and `resize` validate all of
those fields, so forged capacity/alignment, copied released handles, and stale
handles after same-address reuse fail before raw free. It supplies
`allocate`, `allocate_zeroed`, `resize`, and consuming `deallocate`; it does
not provide opaque language capabilities, custom/arena/fixed-buffer allocators,
or a general static lifetime analysis for allocator values.

Strict modules keep ordinary top-level `let` rejected with an explicit v2
lifetime-contract diagnostic. Edition-2027 native x86-64 additionally accepts
the narrow explicit declaration `global let name: Primitive;`: it is a
root-module-only, zero-initialized, one-word BSS cell with an explicit primitive
scalar or raw-pointer type. Pointer cells participate in ordinary named
ownership and checked allocation provenance when assigned/released through the
implemented allocator APIs. They have no dynamic initializer, optional,
callback, aggregate, import, or destructor contract. The compiler's
remaining BSS is private allocator/runtime state, and top-level `const` is a
nullary-function desugaring rather than a static object. Aggregate, callback,
and optional globals remain rejected until initialization ordering, destruction,
and lifetime/provenance contracts are implemented.

## Implemented volatile/MMIO word slice

Edition-2027 native x86-64 provides `@volatileLoad(ptr)` and
`@volatileStore(ptr, value)` for one explicit unsafe/MMIO boundary. Both are
legal only inside `unsafe` (or an `unsafe fn`) and accept only
`*const i64`, `*mut i64`, `*host i64` and their `u64`/`isize`/`usize`
counterparts. Stores reject `*const`. Each lowers to exactly one 64-bit native
memory load or store; the compiler does not fold, coalesce, or reorder these
transactions in its native lowering. Store preserves its checked address across
value-expression calls before issuing that one memory transaction. They are **not atomic**, provide no memory
ordering, and do not imply a fence.

With `--safety=checked`, a volatile transaction uses the same immediate
null/alignment/live-allocation/bounds probe as an ordinary raw access. Unknown
stack, static, and foreign/MMIO addresses remain outside that registry and are
therefore the unsafe caller's responsibility. The proof does not validate a
physical device register, concurrent access, or address fabrication.

Captureless callbacks are ordinary function values. A scalar by-value capture
uses a heap environment that is an owned v2 resource: it may be transferred by
an owned return or must be released with `close(callback)` on every path. The
native close operation clears the fat-function environment before returning it
to the allocator. Pointer captures remain rejected because they retain a
defining-frame address, and aggregate captures remain rejected because their
separate heap copies do not yet have a destruction protocol. Aggregate globals,
pointer captures, and aggregate captures therefore remain explicit unsupported
lifetime paths rather than ambient unsafe behavior. The narrow raw-pointer
global cell above is an exception with no initializer or destructor protocol;
it is not a general pointer-bearing global object model.

The native x86-64 allocator also marks a small allocation's size header as
freed before it links that allocation into a free list, and restores the live
mark when reusing it. A repeated runtime `delete`/`_zag_free` of such a block
therefore prints `zag runtime: invalid or double free` and exits nonzero rather
than corrupting the allocator. `_zag_realloc` validates the same live mark and
rejects a stale/freed input with `zag runtime: realloc of invalid or freed
allocation`.

Dedicated allocations larger than 512 KiB are unmapped on free, so their old
header cannot safely be inspected a second time. The x86-64 runtime therefore
keeps a fixed 2,048-entry `{ user_pointer, exact_size }` provenance table for
those mappings. Free and realloc probe it before reading a header; a matching
freed tombstone produces the same deterministic diagnostic rather than an
unmapped-memory fault. The entry changes to a tombstone only after `munmap`
succeeds, so a failed unmap does not corrupt allocation telemetry. The table
never allocates metadata dynamically: exhaustion terminates the process with
`zag runtime: large allocation provenance registry exhausted`. A tombstone is
discarded when the allocator acquires a later large or small object at that
exact user address. Small-arena acquisition must participate because Linux may
reuse part of an unmapped large range for an arena; retaining the old tombstone
would falsely reject the new object's valid free. Because the ABI carries only
a raw pointer, an old alias cannot be distinguished from a later live
allocation at that identical address. This is allocator-integrity
instrumentation, not general provenance or use-after-free instrumentation. A
stale dereference of a dedicated large mapping does trap at the operating
system's unmapped-page boundary; the allocator lifetime gate exercises that
behavior. It is not a typed diagnostic, does not cover small arena allocations,
and cannot distinguish an old alias from a later allocation at the same
address. Arbitrary forged addresses and the remaining unsafe dereference cases
still require the unsafe programmer to uphold their contract.

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
