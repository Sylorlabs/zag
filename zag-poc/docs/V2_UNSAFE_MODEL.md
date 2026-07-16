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

## Current implementation boundary

The implemented vertical slice has a dedicated unsafe-block AST node, supports
direct `unsafe fn` declarations and calls, requires an unsafe lexical scope at
direct call sites, and propagates the `Unsafe` effect into `@pure` and
`@realtime` checking. Ordinary type checking remains active inside unsafe.
Native x86-64 executes the positive cases; AArch64, WASM, and GPU MLIR have
compile/lowering regression coverage.

This is not the complete model. The compiler does not yet retain the required
per-operation source-span audit records, propagate unsafe contracts through
indirect function values, closures, callbacks, generics, or FFI, or implement
the full unsafe-operation inventory. Pointer provenance, bounds, alignment,
aliasing, and lifetime enforcement also remain incomplete.

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

## Inline assembly and intrinsics

Inline assembly is an unsafe, target-specific expression/statement with named
input operands, output operands, early-clobber/read-write status, register or
immediate constraints, a complete clobber list, and an explicit `memory`
clobber when it accesses memory not represented by operands.  `volatile` means
the instruction is observable and may not be removed; it does not by itself
create atomic synchronization.  The compiler must reject impossible constraints
and preserve all declared register, flags, and memory effects in optimization.

Named target intrinsics declare their required target feature, operand type and
alignment, memory/address-space effects, and whether they are unsafe.  Feature
selection and runtime detection are separate: enabling an instruction is a
deployment promise, while portable code must dispatch only after a supported
detection path.  No backend may accept an asm/intrinsic spelling by emitting a
comment, placeholder, or unrelated instruction.
