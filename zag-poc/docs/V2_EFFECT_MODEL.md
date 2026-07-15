# Zag v2 effect model (draft)

Effects are inferred across the typed call graph and carry source witnesses.
The v2 lattice extends v1 with `Unsafe`, `Volatile`, `Atomic`, `Thread`,
`Block`, `FFI`, `DynLoad`, `DeviceAlloc`, `DeviceTransfer`, `DeviceDispatch`,
and `Diverge`; existing `Alloc`, `IO`, `Lock`, `Panic`, and `Raises` remain.
Effects compose by set union.  Capability annotations express exclusions, not
permissions: `@noalloc` excludes `Alloc`; `@realtime` excludes `Alloc`, `Block`,
`Lock`, and OS/FFI operations unless specifically approved; `@kernel` excludes
host-only effects.  Each rejection prints the annotated function, call edge
chain, and introducing operation.

Indirect calls are checked against effect-qualified function types.  Generic
instantiations, closures, callbacks, imports, extern declarations, and device
helpers retain their latent effects; an unknown indirect/FFI contract is
conservatively effectful and unsafe.

## Inference and witnesses

Effects are monotonic: a caller's set is the union of local operations and all
callable paths it may invoke.  The compiler computes a fixed point over named
functions, then instantiates function values and generics with actual effect
rows.  An unknown function pointer cannot be assumed pure.  A diagnostic prints
the constrained declaration, each call/value-flow edge, and the source
operation at the end of the witness.

Effects describe behavior, not authority.  `Unsafe` records an unsafe operation;
`Atomic` does not imply data-race freedom; `Lock` and `Block` distinguish
synchronization from potential unbounded wait.  `FFI`, `DynLoad`, and GPU
transfer/dispatch remain visible to realtime, kernel, and sandbox constraints.

## Required adversarial checks

The v2 suite must reject effects introduced through direct calls, closures,
stored function values, generic instantiation, methods, callbacks, imported
externs, device helpers, and runtime intrinsics.  An unsafe block must not erase
`Alloc`, `Block`, `FFI`, or GPU effects.  These v2 adversarial checks are not
implemented yet.
