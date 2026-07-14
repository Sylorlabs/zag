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
