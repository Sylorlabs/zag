# Zag v2 allocator guide (draft)

The native x86-64 checked-mode `SystemAllocator` is implemented as the first
v2 allocator surface. Allocation is fallible, explicit, and effectful;
reclamation is included in `Alloc` because a deallocator can call an allocator
or OS service. The implemented handle describes the native backing resource,
exact reserved capacity, and alignment.

The planned source surface is deliberately explicit:

```zag
@import("std/allocator.zag")
let allocator: SystemAllocator = system_allocator();
let block: Allocation = try allocator.allocate(bytes, 8);
try allocator.deallocate(block);
```

The implemented `Allocation` carries a pointer, exact native capacity, chosen
native alignment, a runtime-minted lifetime generation, and the checked
allocator identity that minted it. `resize` and `deallocate` first bind that
identity to their `SystemAllocator` receiver and return `InvalidAllocator` on
a mismatch, before any provenance validation, allocation, copy, or free. The current native
surface accepts power-of-two alignment requests 1, 2, 4, and 8; stronger
alignment remains unsupported rather than silently rounded. `deallocate`
validates the complete five-field identity tuple against checked-runtime
provenance before it frees: an
invalid base, copied released handle, forged length, wrong alignment, or stale
generation after address reuse terminates before allocator metadata is touched.
For named handles and direct local aliases, edition-2027 additionally treats
`try allocator.deallocate(block)` as an affine consuming terminal: a repeated
source-level deallocation is rejected before code generation. This is not yet
an opaque general capability or a proof for arbitrary aliases; exact-record
runtime validation remains required and active.
The same exact-tuple check rejects a live cross-handle splice: a second live
pointer/capacity/alignment combined with another handle's generation or
allocator identity is not a valid identity.
This requires native x86-64 `--safety=checked`; other targets and unchecked
builds reject the validation boundary rather than silently weakening it. The
v2 compiler gate proves that an unchecked call reports that requirement and
does not leave an executable artifact. The compiler-private
`_zag_allocation_register`, `_zag_allocation_validate`, and
`_zag_allocation_free` hooks are also checked-mode-only, so an imported helper
spelling cannot silently open an unchecked handle-free path.

The same gate proves the native telemetry boundary for a checked handle: a
24-byte request increments the lifetime allocation count once, records its
exact 32-byte size-class capacity as live bytes, and raises (but never lowers)
the peak. Consuming that handle restores live bytes while retaining the
monotonic allocation count. These counters describe native payload capacity
only; they are not a general leak detector or allocator identity API.

The handle gate also forges a live descriptor with only `allocator_id` changed,
and invokes `resize`/`deallocate` through a mismatched receiver; both paths
return `InvalidAllocator` before native free. This proves allocator identity is
bound to both the handle and its consuming receiver rather than being
documentation-only metadata, while the single public SystemAllocator identity
remains a bounded slice rather than a complete custom-allocator capability
system.

This is not yet the complete allocator model. The generation and allocator
identity are runtime-checked tokens, but they are not yet opaque language
capabilities and the public constructor currently exposes only identity `1`;
the checked register boundary rejects forged constructor identities until a
second allocator family has its own descriptor and lifetime contract.
Custom allocators remain unimplemented. The fixed-buffer slice
now permits construction from one named live `Allocation`, named top-level
`FixedBufferBlock` allocations, checked byte reads/writes, reset with
generation invalidation, and top-level `deinit` into one fresh named
`Allocation`. It still rejects aliases, aggregate storage, escapes, and
control-flow lifetimes. `resize` and
`allocate_zeroed` are
implemented for the checked native SystemAllocator: it returns the ordinary
minted handle after clearing its exact recorded capacity. `resize` validates
the old handle, allocates the replacement first, copies the overlap, then
consumes the old handle; a fallible replacement allocation therefore leaves the
old handle live. On a successful resize, copied descriptors from the old
lifetime are retired with that old handle and reject before a second free.

`arena_allocator(...)` now provides the same bounded retained-owner discipline
through distinct `ArenaAllocator` and `ArenaBlock` types: one live checked
backing, named top-level blocks, checked byte access, reset invalidation, and
top-level deinit handoff. It is not a general allocator capability. The
fixed-buffer slice
makes no `@noalloc` or `@realtime` claim. Reset advances a compiler-tracked
generation and rejects every pre-reset block name; runtime also retires the
old bounded block rows. Checked block reads and writes revalidate the exact
retained backing handle at runtime before deriving an address, so a direct
intrinsic call after backing release traps. Exhaustive block/lifetime coverage
remains unsupported.
There is no special-case fallback or hidden heap path.

## Fixed-buffer boundary

The implemented fixed-buffer slice has a compiler-tracked retained backing,
opaque runtime block tokens, checked byte access, bounded registry reuse, and
generation invalidation on `reset`. A block access revalidates the retained
backing handle before deriving an address, so released backing storage cannot
be reached through a stale direct intrinsic call. Exhaustion returns
`OutOfMemory` and never falls through to `_zag_malloc`.

This is deliberately not a general allocator protocol: aliases, aggregate
storage, escaping blocks/allocators, control-flow lifecycles, arbitrary typed
allocation, custom allocator allocation, and `@noalloc`/`@realtime` qualification
remain unsupported.

Arena and fixed-buffer allocators are useful only when their lifetime/reset
semantics are explicit.  A fixed-buffer allocation may satisfy `@noalloc` or
`@realtime` only after the compiler proves it does not fall through to a heap
or OS path; an exhausted buffer returns its documented failure, not a hidden
heap allocation.  `resize` preserves the old allocation on failure and
invalidates old derived pointers on a moving success.

Debug allocator evidence must cover double/invalid free, use-after-free where
practical, red-zone overflow, metadata corruption, and leaks.  It is diagnostic
instrumentation, not a claim of static raw-pointer safety.
