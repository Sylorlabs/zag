# Zag v2 effect model (draft)

Effects are inferred across the typed call graph. The implemented lattice is
`Alloc`, `Panic`, `IO`, `Lock`, `Raises`, and `Unsafe`; this is not yet the
broader planned v2 lattice for `Volatile`, `Atomic`, `Thread`, `Block`, `FFI`,
dynamic loading, or GPU work. Function-value rows use the same six-bit
universe, so `@realtime`/`@pure` callback contracts exclude `Unsafe` as well
as allocation, I/O, and locking.
Effects compose by set union.  Capability annotations express exclusions, not
permissions: `@noalloc` excludes `Alloc`; `@realtime` excludes `Alloc`, `Block`,
`Lock`, and OS/FFI operations unless specifically approved; `@kernel` excludes
host-only effects.  Each rejection prints the annotated function, call edge
chain, and introducing operation.

Indirect calls are checked against effect-qualified function types.  The
implemented slice tracks direct function-valued locals, including reassignment
to a closure, so a later indirect call cannot retain a stale safe effect row.
Calls through an aggregate field, index, or computed callee are now rejected
inside constrained functions with the complete implemented effect universe
until the value carries a verified row.  This is a fail-closed boundary, not
aggregate effect inference: it prevents untracked Atomic/FFI/GPU-like work
from acquiring a harmless field spelling.  Generic instantiations, aggregate
row propagation, imports, extern declarations, and device helpers still need
the complete latent-effect coverage; an unknown indirect/FFI contract remains
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

The v2 suite now rejects effects introduced through direct calls, a reassigned
function-valued local, and an opaque aggregate function call, as well as the
existing callback and pure-contract witnesses.  It still needs adversarial
coverage for generic instantiation, methods, verified rows for stored function
values in aggregates, imported externs, device helpers, and runtime intrinsics.
An unsafe block must not erase `Alloc`, `Block`, `FFI`, or GPU effects; those
broader checks are not implemented yet.
