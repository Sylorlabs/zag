# Zag v2 FFI guide (draft)

The complete v2 FFI contract is not implemented. A deliberately narrow
edition-2027 slice now accepts `extern fn ... @cabi` declarations for scalar
integers, `bool`, `void`, and raw pointers, and can resolve them through the
native x86-64 dynamic ELF loader under an explicit `unsafe` call site. This is
import-only evidence, not a general C ABI guarantee; existing v1 `extern`
usage remains outside the v2 ABI guarantee.

Every declaration records calling convention, exact integer widths, aggregate
representation, pointer mutability/nullability, ownership transfer, callback
lifetime, error convention, and whether the foreign side may block, allocate,
retain a pointer, or call concurrently.  A raw import is `unsafe` and carries
`FFI`; safe wrappers validate and convert at the boundary without erasing other
effects.  Never infer C layout from a language struct without an explicit ABI
representation and a bidirectional executable conformance test.

Dynamic loading is fallible and effectful.  A library handle outlives every
looked-up symbol and callback registered with that library.  Variadics and weak
symbols remain rejected until target-specific conformance tests exist.
