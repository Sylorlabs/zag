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
native alignment, and a runtime-minted lifetime generation. The current native
surface accepts power-of-two alignment requests 1, 2, 4, and 8; stronger
alignment remains unsupported rather than silently rounded. `deallocate`
validates all four against checked-runtime provenance before it frees: an
invalid base, copied released handle, forged length, wrong alignment, or stale
generation after address reuse terminates before allocator metadata is touched.
This requires native x86-64 `--safety=checked`; other targets and unchecked
builds reject the validation boundary rather than silently weakening it.

This is not yet the complete allocator model. The generation is compiler-
minted and runtime-checked, but not an opaque language capability; allocator
identity, custom allocators, arenas, and fixed-buffer allocators are still
unimplemented. `resize` and `allocate_zeroed` are
implemented for the checked native SystemAllocator: it returns the ordinary
minted handle after clearing its exact recorded capacity. `resize` validates
the old handle, allocates the replacement first, copies the overlap, then
consumes the old handle; a fallible replacement allocation therefore leaves the
old handle live.

In particular, a fixed-buffer allocator is intentionally rejected as a public
v2 surface for now. Its constructor must retain a caller-owned buffer while its
allocation operation mutates allocator state and accepts size/alignment; the
current typed borrow contracts are unary and cannot express that multi-argument
lifetime/mutation contract without weakening ownership checks. There is no
special-case fallback, no hidden heap path, and no claimed `@noalloc` or
`@realtime` behavior until that contract and executable exhaustion/reset tests
exist.

Arena and fixed-buffer allocators are useful only when their lifetime/reset
semantics are explicit.  A fixed-buffer allocation may satisfy `@noalloc` or
`@realtime` only after the compiler proves it does not fall through to a heap
or OS path; an exhausted buffer returns its documented failure, not a hidden
heap allocation.  `resize` preserves the old allocation on failure and
invalidates old derived pointers on a moving success.

Debug allocator evidence must cover double/invalid free, use-after-free where
practical, red-zone overflow, metadata corruption, and leaks.  It is diagnostic
instrumentation, not a claim of static raw-pointer safety.
