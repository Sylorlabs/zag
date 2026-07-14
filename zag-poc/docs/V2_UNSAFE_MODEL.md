# Zag v2 unsafe model (draft)

Unsafe is lexical and compositional.  `unsafe {}` permits only the operations
listed by the language; it does not suppress type errors, effect errors,
address-space checks, edition checks, or target checks.  An `unsafe fn` requires
an unsafe call site unless it exposes a checked wrapper contract.

Required unsafe operations are raw dereference/arithmetic, pointer fabrication
or incompatible casts, unchecked indexing, volatile/MMIO, mutable global
access without synchronization, raw FFI lacking a checked wrapper, inline asm,
and target intrinsics marked unsafe.  Diagnostics name the exact operation and
suggest the smallest enclosing unsafe boundary.  `Unsafe` is an inferred effect
and propagates through direct calls, function values, closures, generics,
callbacks, and FFI.  It is not erased by entering an unsafe block.

Unsafe code may rely on the documented contracts of a target extension.  It may
not rely on undocumented aliasing, provenance, layout, or optimizer behavior.
