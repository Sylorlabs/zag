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
Custom allocators, arenas, and fixed-buffer allocators are still
unimplemented. `resize` and `allocate_zeroed` are
implemented for the checked native SystemAllocator: it returns the ordinary
minted handle after clearing its exact recorded capacity. `resize` validates
the old handle, allocates the replacement first, copies the overlap, then
consumes the old handle; a fallible replacement allocation therefore leaves the
old handle live. On a successful resize, copied descriptors from the old
lifetime are retired with that old handle and reject before a second free.

In particular, `fixed_buffer_allocator(...)` and `arena_allocator(...)` are
explicitly rejected as public v2 surface spellings for now. Their constructors
must retain a caller-owned buffer while allocation mutates allocator state and
accepts size/alignment. Borrow contracts now permit scalar auxiliary
parameters, but still track only a first owner parameter and reject a
receiver/second pointer/aggregate lifetime; that does not express this
multi-argument lifetime/mutation contract without weakening ownership checks.
There is no
special-case fallback, no hidden heap path, and no claimed `@noalloc` or
`@realtime` behavior until that contract and executable exhaustion/reset tests
exist.

## Required fixed-buffer allocator slice

This is the smallest coherent implementation plan; it is **not implemented**.

1. Extend function annotations from bare strings to parsed contract metadata
   with parameter indices and a return relation. A constructor needs to say
   that its mutable receiver stores a borrow of parameter `buffer`; an
   allocation method needs to say that its result is derived from that stored
   buffer rather than owned by the heap.
2. Extend typed borrow state from one `root/mode` pair to a set of parameter
   roots plus an attached region on aggregate fields. The checker must reject
   returning the allocator or an allocation after its buffer owner is released,
   and must keep the receiver unavailable while a mutable allocation/reset
   operation is active.
3. Give fixed-buffer allocations a checked runtime descriptor
   `{ allocator_id, generation, offset, length, alignment }`. A successful
   `reset` increments the allocator generation; later access/deallocation of a
   descriptor minted before reset must fail. The descriptor is not a general
   heap `Allocation` and cannot call `_zag_free`.
4. Lower only `init`, `allocate`, and `reset` for native checked x86-64 first.
   Allocation must check cursor, requested alignment, and capacity; exhaustion
   returns its explicit error and must not fall through to `_zag_malloc`.
5. Add execution evidence for aligned allocation, exhaustion without heap
   telemetry growth, buffer/receiver lifetime rejection, reset invalidation,
   and no `@realtime`/`@noalloc` claim until the effects are independently
   proved.

Arena and fixed-buffer allocators are useful only when their lifetime/reset
semantics are explicit.  A fixed-buffer allocation may satisfy `@noalloc` or
`@realtime` only after the compiler proves it does not fall through to a heap
or OS path; an exhausted buffer returns its documented failure, not a hidden
heap allocation.  `resize` preserves the old allocation on failure and
invalidates old derived pointers on a moving success.

Debug allocator evidence must cover double/invalid free, use-after-free where
practical, red-zone overflow, metadata corruption, and leaks.  It is diagnostic
instrumentation, not a claim of static raw-pointer safety.
