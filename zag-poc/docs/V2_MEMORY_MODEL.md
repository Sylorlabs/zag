# Zag v2 memory model (draft)

Checked references/slices remain the default.  Raw pointers are `*const T`,
`*mut T`, and `*opaque`; nullable raw pointers use `?*const T`/`?*mut T`.
Address-space qualification is part of the pointer type (`*device T`,
`*workgroup T`, `*host T`).  A raw dereference, pointer arithmetic,
integer-pointer conversion, unchecked slice construction/indexing, volatile
access, MMIO access, and provenance-erasing cast require `unsafe`.

Pointer add/subtract scales by `size_of(T)`, is defined only within one live
allocation plus one-past, and traps in checked instrumentation otherwise.
Before a checked native raw `p[i]` access, the compiler rejects signed
`i * size_of(T)` and base-plus-offset arithmetic that would wrap, before any
provenance/bounds lookup observes a wrapped address.
Raw-pointer ordering comparisons are rejected. Equality/inequality is raw
address identity; equality against null is the portable cross-allocation test,
not a proof of common allocation provenance. Misalignment is rejected or
traps; byte pointers are the explicit route for byte arithmetic. Reallocation
invalidates old pointers.  Use-after-free,
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

Current implementation note: this is a target contract, not a present effect
claim. Edition 2027 admits a linear fixed-buffer retained-owner slice:
construction, named block allocation, checked byte reads/writes, generation-
invalidating reset, and top-level `deinit`. Aliasing/escape/control-flow
lifetimes and
`@noalloc`/`@realtime` qualification remain unsupported.

In checked native output, each block access also revalidates the exact retained
backing `Allocation` tuple before deriving a byte address. This makes a
forged/direct intrinsic call after backing release trap instead of reaching
released storage; it is bounded runtime instrumentation, not a general
lifetime proof.

## Status and edition boundary

This is a v2 (`edition = "2027"`) contract, not a description of current v1
`*T` lowering. The compiler now accepts qualified and nullable raw-pointer
types, requires explicit optional unwrapping before nullable raw-pointer
dereference, indexing, or arithmetic,
rejects casts between distinct generic/host/device/workgroup address spaces,
and rejects native x86-64 dereference or indexing of `*device`/`*workgroup`
pointers until a GPU runtime owns those address spaces,
executes bounded native dereference cases, rejects dereference outside unsafe,
rejects writes through `*const`, and performs an edition-2027 static ownership
flow pass. That pass follows direct local aliases of compiler-recognized
allocations, rejects double-free and use-after-free through those aliases,
requires every discovered owner to be released or returned on every
control-flow path, and rejects an owned value passed to an uncontracted call.
Calls that receive an owner must explicitly declare `@borrows`,
`@borrows_mut`, or `@consumes`; this makes ownership transfer and retention
inspectable instead of implicit. A borrow contract tracks only its first owner
parameter and may take later builtin scalar parameters such as a length or
count. A consume contract tracks every explicit raw-pointer or `Allocation`
parameter as an owner: every such parameter must be released or transferred
on every path. Scalars remain ordinary values. Aggregates, callbacks, slices,
optionals, and error unions remain rejected because they could carry an
untracked lifetime.
An `@consumes @returns_owner` helper may instead return one exact consumed
owner as a value. This is accepted only when compiler summary analysis proves
that every owned return is the same declared consuming parameter; the caller's
direct named argument is invalidated and the bound result becomes the sole
live owner. A precisely tracked field of a local value aggregate may make the
same transfer: its field provenance is discharged and the bound result becomes
the sole owner. This now includes an opaque `Allocation` field when the helper
is non-extern, has one exact `Allocation` owner parameter, and every terminal
path returns that same parameter. Ambiguous, copied, fresh, or untracked field
paths reject. The
annotation is not authority by itself: mixed, fresh, indirect, computed, or
unproven returns reject, as do calls without this explicit contract. A
success-path `try helper(owner)` preserves this same identity; error paths
remain ordinary error propagation and never create a capability.
This is a small interprocedural identity-transfer boundary, not a
general capability or heap-graph analysis.
A separate return-lifetime check rejects
addresses of local values and local fields returned directly, through
direct aliases, or inside named pointer-carrying struct/union literals. A
direct `_zag_realloc(named_owner, size)` is modeled as an atomic ownership
transfer to the assigned result: both `let replacement = ...` and
`owner = ...` retire the old named root only when that result becomes the new
owner. This does not model failure-return ownership, aliased or computed
arguments, or general allocator APIs; those cases remain fail-closed or
unsafe-programmer responsibility.
mutation-aware pass additionally follows owner and current-frame roots
stored in named struct/union values through arbitrary source-representable
nested field paths,
field/whole-value assignment, value copies, and conservative branch joins. It
rejects proven pass, return, and non-local store escapes; an overwrite clears
only the field subtree it proves replaced. The same aggregate rules permit a
pointer inherited from the caller because that pointer does not identify the
callee's frame.

Opaque `Allocation` capabilities are stricter than ordinary raw-pointer
provenance. Storing one in a local aggregate is an affine move that makes the
original binding unavailable, and copying an aggregate cannot duplicate the
capability. Compiler-recognized `deallocate(aggregate.field)` consumes the
shared identity. A successful `resize(aggregate.field, ...)` also consumes that
old identity and binds the returned value as the one live replacement; later
use of the original binding or old aggregate path rejects before lowering.
These rules cover proven local field paths only and do not establish general
heap-container or interprocedural capability analysis.

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
it cannot defeat raw-address forgery. Checked-mode small frees are quarantined
instead of recycled, and the table rejects any later ordinary allocation at a
tombstoned address, so a stale ordinary raw address cannot be revived by
allocator ABA. This consumes one of the bounded rows for every distinct
checked allocation lifetime and fails closed on exhaustion; default unchecked
free-list reuse is unchanged. Untracked allocator families can still reuse
addresses, so this is not a general use-after-free proof. Paths deeper than the bounded
field proof retain an uncertain provenance marker and fail closed until a
proven prefix or whole container is overwritten. This establishes only named
local aggregate provenance within the checked function, not general aggregate
or heap-graph provenance. v1 pointer indexing and `new`/`delete` extensions are
not evidence that those stronger rules already hold.

The checked native `SystemAllocator` is a separate, deliberately narrow
allocator-handle boundary. It returns fallible opaque `Allocation`
capabilities. The compiler owns their native pointer, exact reserved capacity,
accepted alignment (1, 2, 4, or 8), runtime-minted generation, and allocator
registry identity; source cannot construct, cast, or read those fields.
`deallocate` and `resize` validate the complete hidden identity, so copied
released handles and stale handles after same-address reuse fail before raw
free. It supplies `allocate`, `allocate_zeroed`, `resize`, consuming
`deallocate`, and checked `allocation_read_u8`/`allocation_write_u8`. It does
not provide custom allocators or a general static lifetime analysis for
allocator values. The separate retained fixed-buffer slice is implemented
below; it is not a general allocator protocol.
For a named `Allocation`, the edition-2027 affine pass also recognizes the
receiver form `try allocator.deallocate(block)` as a consuming terminal. A
second deallocation through that name or a direct local alias is rejected
before code generation; the checked runtime's exact-record validation remains
the backstop for forged descriptors, foreign aliases, and paths outside this
still-bounded source analysis.
The same direct-local boundary recognizes `try allocator.resize(block, bytes,
alignment)` as consuming `block` after a successful replacement is bound. The
replacement remains usable; the old name and direct aliases do not. This is
not a general interprocedural transfer summary.
An `@alloc` function may return `Allocation`/`!Allocation` only as a narrow
proven producer summary: it must be a non-extern function, take no
`Allocation` parameter, and every explicit return path must directly mint from
the checked allocator receiver or transitively return another proven `@alloc`
producer. Its body may not bind arbitrary minted capabilities locally: that
would need general local ownership-flow accounting to prove they are returned
exactly once rather than leaked. The implemented straight-line local-flow case
tracks multiple private named `Allocation` bindings: each must be directly
deallocated, except for one exact binding transferred by return. A complete
`if` may transfer that sole remaining binding when every arm returns that exact
binding; assignment and all other control-flow joins remain rejected. The
annotation alone is not authority; an unproven, foreign, cyclic, mixed, or
unproven-local return is rejected at the receiving local boundary. This permits
small allocation factories without permitting an `Allocation` capability to be
silently copied, echoed, or fabricated. It is still not a general
interprocedural lifetime or allocator protocol.
Direct local `Allocation` copies, uncontracted assignment transfers, field
access, casts, and structural literals are rejected before code generation.
The current runtime record remains the native backstop for stale handles and
same-address reuse; its representation is compiler-owned rather than a public
descriptor. The public
`system_allocator()` constructor currently mints only identity `1`; the checked
register boundary rejects forged constructor identities, so this slice does
not claim a complete multi-allocator capability system.
Its compiler-private register, validate, and free hooks also reject outside
checked mode; importing the allocator module cannot silently weaken that handle
boundary into an unchecked free path.
`fixed_buffer_allocator(...)` is admitted only through the edition-2027
retained-owner lifecycle: one named live backing `Allocation`, named top-level
blocks, checked byte access, reset, and top-level `deinit` returning that exact
backing. It rejects aliases, escapes, aggregate storage, and arbitrary
control-flow lifetimes. A narrow proven loop may repeatedly allocate an
ephemeral block, use checked byte access, and reset that same named region;
this is the bounded arena steady-state and does not let a block cross an
iteration. `arena_allocator(...)` has the same bounded retained-owner
discipline with its own `ArenaAllocator`/`ArenaBlock` types; it is a checked
backing-buffer arena, not a general allocator capability or a raw-pointer
fallback.

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

## Implemented volatile/MMIO byte, halfword, dword, and word slice

Edition-2027 native x86-64 provides `@volatileLoad(ptr)` and
`@volatileStore(ptr, value)` for explicit 64-bit transactions, plus
`@volatileLoad8(ptr)`/`@volatileStore8(ptr, value)`,
`@volatileLoad16(ptr)`/`@volatileStore16(ptr, value)`, and
`@volatileLoad32(ptr)`/`@volatileStore32(ptr, value)` for explicit byte,
16-bit, and 32-bit transactions. All are legal only inside `unsafe` (or an
`unsafe fn`). The word
forms accept only
`*const i64`, `*mut i64`, `*host i64` and their `u64`/`isize`/`usize`
counterparts; byte, halfword, and dword forms accept only `*const/*mut/*host`
`u8`, `u16`, and `u32` respectively. Stores reject `*const`. Each lowers to
exactly one native memory load or store;
the compiler does not fold, coalesce, or reorder these transactions in its
native lowering. `@volatileLoad8` zero-extends its loaded byte, and
`@volatileStore8` writes only the low byte of its lowered scalar value. The
16/32-bit forms similarly zero-extend loads and write only the low 16/32 bits,
preserving the requested device-register width even though the backend's
scalar stack is 64-bit. Store preserves its checked address across
value-expression calls before issuing that
one memory transaction. They are **not atomic**, provide no memory ordering,
and do not imply a fence.

With `--safety=checked`, a volatile transaction uses the same immediate
null/alignment/live-allocation/bounds probe as an ordinary raw access. Unknown
stack, static, and foreign/MMIO addresses remain outside that registry and are
therefore the unsafe caller's responsibility. Width and alignment are
validated (`u8`/1, `u16`/2, `u32`/4, and word/8); the proof does not validate a
physical device register, device capability, concurrent access, or address
fabrication. Device/workgroup pointers remain rejected until a GPU/MMIO
capability contract exists.

`std/mmio.zag` additionally provides a bounded `MmioRegion` helper for byte
transactions. Unsafe code supplies one `*mut u8` base and a nonnegative length
to `mmio_region`; `mmio_read8` and `mmio_write8` reject negative or
out-of-range offsets with `error.OutOfRange` before deriving the byte pointer
and issuing the existing volatile operation. This is a useful source-level
range boundary around a named device window, but it is not opaque hardware
authority: unsafe code can still forge or copy raw addresses, and the helper
does not enumerate devices, validate a physical mapping, establish privilege,
or supply atomic ordering.

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

The native x86-64 default unchecked allocator marks a small allocation's size
header as freed before linking that allocation into a free list, and restores the live
mark when reusing it. Checked and sanitizer builds instead mark and quarantine
the block for the process lifetime; they never publish its address as a new
ordinary allocation. A repeated runtime `delete`/`_zag_free` of such a block
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
`zag runtime: large allocation provenance registry exhausted`. The default
unchecked path may discard a tombstone when Linux later reissues the address. Checked and
sanitizer mode additionally retain the ordinary-allocation tombstone and
terminate with `zag safety: allocator address reuse violates checked
quarantine` before returning any successor object at that address. This is
bounded fail-closed instrumentation, not identity-carrying raw pointers. A
stale dereference of a dedicated large mapping does trap at the operating
system's unmapped-page boundary; the allocator lifetime gate exercises that
behavior. Arbitrary forged addresses, untracked allocation families, and the remaining unsafe dereference cases
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
For the checked `SystemAllocator` handle boundary, a successful resize also
retires copied descriptors for the old allocation lifetime before they can be
used for a second free.
Safe code cannot create a pointer without a checked origin.  Unsafe integer
conversion creates an *untrusted* pointer that may only be dereferenced when
the unsafe caller satisfies alignment, extent, lifetime, address-space, and
access-permission preconditions.

## Operations and failures

`p.add(n)`, `p.sub(n)`, and `p[n]` use element counts.  `p.byte_add(n)` is the
explicit byte operation and is only available on byte/opaque pointers. An
`*opaque` value therefore rejects element arithmetic and indexing until an
explicit conversion supplies a pointee type and stride. A nonzero operation on
null, an operation outside `[base, one_past]`, subtracting
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
language specification.  `@repr(C)`, `@repr(packed(N))`, and explicit alignment
are target/ABI commitments and may be used only where their target restrictions
are met.  `offset_of` is available only for a named field whose representation
is fixed.  Reading a packed field is lowered as an unaligned byte operation or
requires unsafe; it is never silently emitted as an invalid aligned load.

The current executable subset is edition-2027 `@repr(C) struct` on Linux
x86-64 for integer, boolean, and raw-pointer leaves. It applies System V AMD64
natural field alignment and tail padding; `@sizeOf`, pointer stride, address-of
field offsets, and exact-width field loads/stores agree. Ordinary Zag structs
retain the established word layout. `tests/run_repr_c_layout.sh` is the native
byte/offset authority. The current aggregate contract is pointer-only: direct
by-value literals, locals, assignments, arguments, and results fail closed.
Packed layout, general `offset_of` syntax, nested or generic C-layout
aggregates, floats, and other targets remain unavailable.

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
