# Zag v2 FFI guide (draft)

Zag FFI is an adoption boundary, not a compilation strategy: the compiler
continues to lower Zag source directly to native code.  Use this surface only
to replace C incrementally or reach unavoidable platform/library interfaces;
it never converts Zag source to C or relies on C as a backend.

The complete v2 FFI contract is not implemented. A deliberately narrow
edition-2027 slice now accepts `extern fn ... @cabi` declarations for scalar
integers, `bool`, `void`, and raw pointers, and can resolve them through the
native x86-64 dynamic ELF loader under an explicit `unsafe` call site. This is
import-only evidence, not a general C ABI guarantee; existing v1 `extern`
usage remains outside the v2 ABI guarantee.

`@cabi` carries the implemented `Unsafe` effect. Direct calls require lexical
`unsafe`, and converting a C-ABI import to an ordinary `fn(...)` value is
rejected until function types carry an explicit ABI/effect contract. This keeps
`@pure` and `@realtime` callers from laundering foreign behavior through an
otherwise effect-free declaration.

The native x86-64 lowering also has executable coverage for fixed-arity calls
that exceed the six integer argument registers: additional scalar arguments
are placed on the SysV AMD64 stack with the required call-site alignment. The
release fixture calls libc's `syscall` symbol with seven `i64` arguments and
uses the seventh Linux `mmap` offset to distinguish an invalid unaligned call
from a successful mapping (libc reports the invalid call as `-1`). This proves the stack placement rule only; it does
not make variadic declarations, aggregate classification, or arbitrary foreign
prototypes supported. `syscall` is declared with a fixed seven-word signature
in that fixture so no variadic function-value or format contract is inferred.

`@cabi` is fail-closed for every other current target/output, including the
otherwise-supported i686 `--emit-obj` / `--emit-static` path: no v2 C ABI
object, archive, WASM, ARM64, or GPU artifact is emitted. Those target-specific
ABIs need their own calling-convention and executable conformance evidence.
Native x86-64 `--emit-obj` supports the documented scalar `@cabi_export`
boundary and direct scalar/pointer/`bool`/`void` `extern fn @cabi` calls. It
emits Zag machine code plus only `R_X86_64_PLT32` call relocations; the host
linker supplies the declared legacy implementation. `--emit-static` still
rejects before artifact creation.

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
