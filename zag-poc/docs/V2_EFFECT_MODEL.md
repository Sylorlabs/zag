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
