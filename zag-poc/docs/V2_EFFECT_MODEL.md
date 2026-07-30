# Zag v2 effect model (draft)

Effects are inferred across the typed call graph. The implemented lattice is
`Alloc`, `Panic`, `IO`, `Lock`, `Raises`, `Unsafe`, `Atomic`, `FFI`, `Device`,
and `GPUHost`. Atomic, foreign, and GPU work no longer collapse into generic
`Unsafe`, although currently unsafe operations retain both their specific
effect and `Unsafe`. Function-value rows use the same ten-bit universe, so
assignment and callback storage cannot truncate the newer high-bit effects.

Effects compose by set union. Capability annotations express exclusions, not
permissions: `@noalloc` excludes `Alloc`; `@realtime` and `@pure` exclude
allocation, I/O, locking, unsafe machine control, atomic, FFI, Device, and
GPUHost effects; `@kernel` excludes every implemented effect except `Device`.
Direct printing, raw atomics, C-ABI calls, and host GPU allocation/launch calls
therefore reject before GPU frontend emission, while device-index helpers
propagate through direct calls and remain legal in a kernel. This is a
conservative kernel-entry boundary, not a complete device capability system.

Indirect calls are checked against effect-qualified function types. The
implemented slice tracks direct function-valued locals, including reassignment,
so a later indirect call cannot retain a stale safe effect row. Calls through
an aggregate field, index, or computed callee are rejected inside constrained
functions with the complete ten-bit universe until the value carries a
verified row. Explicit aggregate rows are enforced at construction and field
mutation, retained for typed locals and parameters, and used at calls.
Concrete receiver methods resolve through their mangled declaration; generic
callback arguments retain their instantiated effects. Interface/unknown
dispatch remains conservatively fail-closed.

## Inference and witnesses

Effects are monotonic: a caller's set is the union of local operations and all
callable paths it may invoke. The compiler computes a fixed point over named
functions, then instantiates function values with actual effect rows. An
unknown function pointer cannot be assumed pure.

Effects describe behavior, not authority. `Unsafe` records unsafe machine
access; `Atomic` does not imply data-race freedom; `Lock` does not prove bounded
waiting; `FFI` does not provide a foreign ownership contract; `Device` does not
authorize host submission; and `GPUHost` does not prove physical GPU safety.

## Required adversarial checks

The v2 suite rejects effects introduced through direct calls, reassigned
function-valued locals (including a high-bit Device reassignment), unqualified
aggregate calls, effect-row construction and mutation violations, effectful
methods, generic callbacks, and direct I/O, atomic, C-ABI, or host-GPU
operations in `@kernel`. It proves verified aggregate rows and pure concrete
methods remain usable and a direct Device helper remains legal in a kernel.
New runtime or device operations must enter this lattice before support; an
unclassified indirect path receives the full universe.
