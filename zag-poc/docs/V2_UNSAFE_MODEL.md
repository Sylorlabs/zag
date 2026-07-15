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

## Call boundary and auditability

The compiler records the lexical span of every unsafe operation.  A call to an
`unsafe fn` is itself an unsafe operation even when the callee's body is in a
different module.  Safe wrappers are ordinary functions that establish and
document the callee's preconditions; their body contains the smallest practical
unsafe region.  An unsafe block does not make calls made through callback or
generic values safe by implication: their declared effect and safety contract
remain part of the call's type.

`Unsafe` denotes that a function *performs or transitively invokes* an unsafe
operation; it is not a permission grant.  A capability such as `@safe` or a
kernel/realtime restriction may forbid the effect, and diagnostics must show
the call chain and source operation that introduced it.  Imported symbols with
no machine-checkable contract are `Unsafe + FFI` by default.

## Defined unsafe contracts versus undefined behavior

Unsafe APIs must state preconditions in terms of pointer validity, alignment,
extent, aliasing, lifetime, target feature, and synchronization.  Violating a
checked precondition traps in checked/debug builds when detectable.  Release
behavior is undefined only when the caller violates an explicit unsafe
precondition that cannot be dynamically checked.  A backend bug, unsupported
target feature, or unknown construct is never reclassified as user undefined
behavior: it is a compile-time error.
