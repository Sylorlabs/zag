# Zag v2 allocator guide (draft)

The v2 allocator interface is specified but not implemented.  Allocation is
fallible, explicit, and effectful; reclamation is included in `Alloc` because a
deallocator can call an allocator or OS service.  An allocator handle describes
the backing resource, alignment capability, ownership of returned allocations,
and whether an operation can block.

Arena and fixed-buffer allocators are useful only when their lifetime/reset
semantics are explicit.  A fixed-buffer allocation may satisfy `@noalloc` or
`@realtime` only after the compiler proves it does not fall through to a heap
or OS path; an exhausted buffer returns its documented failure, not a hidden
heap allocation.  `resize` preserves the old allocation on failure and
invalidates old derived pointers on a moving success.

Debug allocator evidence must cover double/invalid free, use-after-free where
practical, red-zone overflow, metadata corruption, and leaks.  It is diagnostic
instrumentation, not a claim of static raw-pointer safety.
