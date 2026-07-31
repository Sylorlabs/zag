# Zag v1 language specification

Status: **frozen v1 core**, 2026-06-29.

This document is the normative boundary for Zag v1. A construct is part of v1
only when it appears in the supported sections below. Experimental compiler
features may exist outside this boundary, but programs that use them are not
portable v1 programs. Changing the meaning of a supported construct requires a
new language edition; adding a previously unsupported construct is compatible.

The v1 core deliberately targets Zag's native compiler and runtime. Generated C
is a bootstrap path, not part of the language semantics or the v1 portability
contract.

## 1. Program model

A program is a set of UTF-8 source files containing declarations. Execution
starts at `fn main() i32` or `fn main() void`. An `i32` result is the process
exit status. Declarations are order-independent within a merged module.

Comments begin with `//` and continue to the end of the line. Identifiers are
case-sensitive. String literals contain bytes and have type `[]u8`; v1 does not
define Unicode scalar or grapheme semantics.

`@import("path")` merges public declarations from another source file.
`@import("path") as name` imports them under `name`. Relative paths are resolved
from the importing file. A local binding shadows an imported declaration with
the same name.

## 2. Types

The portable scalar types are:

- `bool`, `void`
- `i8`, `i16`, `i32`, `i64`, `isize`
- `u8`, `u16`, `u32`, `u64`, `usize`
- `f32`, `f64`

Integer literals are decimal and take the type required by their context.
Floating-point literals contain a decimal point. Explicit conversion uses
`value as Type`. Implicit conversion between different named numeric types is
not part of v1.

Compound types are `*T` pointers, `[]T` slices, `?T` optionals, `!T` error
unions, named structs, enums, and tagged unions. A slice is a pointer-length
pair; `.len` returns its element count. Struct assignment and parameter passing
have value semantics. Pointer dereference is `p.*`, and `&place` takes the
address of an assignable place.

Zag also implements specialized numeric families (`p8`/`p16`/`p32`/`p64`,
saturating integers, fixed-point values, arbitrary-width integers, `rns_3`, and
`quire`). They are supported v1 extensions, but are not required for a v1-core
implementation.

## 3. Bindings and control flow

`let name: Type = expression;` introduces a mutable, lexically scoped local.
Portable v1 code includes the type annotation. Assignment uses `=`. Inner
bindings may shadow outer bindings; a binding is visible from its declaration
to the end of its block.

Supported statements are expression statements, assignment, `return`, `if` /
`else`, `while`, and `switch`. `&&` and `||` short-circuit. `break`, `continue`,
labelled control flow, and `defer` are outside the v1 core.

Enums use `Enum.Member`. Tagged unions are constructed with
`Union{ .member = value }` and inspected with `switch`; payload captures are
written `|value|`. A portable v1 switch over an enum or union is exhaustive.

## 4. Functions, methods, and generics

Functions have the form `fn name(parameters) ReturnType { ... }`. Recursion,
function values, and non-capturing or explicitly capturing closures are
supported. A capturing closure is stack-bound and may not escape its defining
scope.

Generic functions and structs declare type parameters in brackets:

```zag
struct Box[T] { value: T }
fn identity[T](value: T) T { return value; }
```

Struct type arguments are explicit (`Box[i32]`). Function type arguments may be
explicit (`identity[i32](1)`) or inferred from value arguments
(`identity(1)`). Generics are monomorphized. Variadics, default arguments,
higher-kinded types, generic specialization, and user-defined generic bounds
are unsupported.

Methods use an explicit `self` parameter. Structural interfaces and operator
contracts are shipped extensions, not part of the portable v1 core.

## 5. Optionals and errors

`null` constructs an empty `?T`. A value of `T` may initialize `?T`. Supported
unwrapping forms are `value orelse fallback`, `value.?`, and capture forms such
as `if (value) |payload|` and `while (value) |payload|`.

An error set is declared with `error { Name, ... }`. A function returning `!T`
may return either a `T` or `error.Name`. `try expression` propagates an error and
is legal only in a function returning an error union. `expression catch value`
recovers with a fallback; `catch |err| value` also exposes the error code.

Error-set inference, typed error-set composition, exception objects, and stack
unwinding are unsupported.

## 6. Memory model

Local values have automatic block lifetime. Struct values are copied by value.
`new(Struct{ ... })` allocates storage and returns `*Struct`. `delete(pointer)`
exists in the bootstrap backend but is **not** in the portable v1 core because
the native backend does not yet implement reclamation.

Zag v1 has no garbage collector, ownership or borrow checker, destructors,
RAII, or lifetime inference. Pointer validity is the programmer's
responsibility. Pointer arithmetic is unsupported. Bounds checking and null
force-unwrapping must not be relied on as a complete safety boundary until the
native backend's trap behavior is specified and tested on every target.

## 7. Effects and capabilities

Function annotations such as `@pure`, `@noalloc`, `@realtime`, and `@total`,
plus effect-variable function types, are supported language extensions. A
claimed capability is checked transitively and a violation aborts compilation.
These annotations do not change ordinary value semantics.

Target mapping, cache-control annotations, GPU emission, posit hardware targets,
and hot reloading are implementation extensions. They are intentionally outside
the portable v1 core.

## 8. Explicitly unsupported in v1 core

- compile-time execution, macros, and general reflection
- fixed-size array syntax and array-valued generics
- tuples and anonymous structs/unions
- classes, inheritance, and nominal interface declarations
- async/await, language-level threads, atomics, and a concurrency memory model
- exceptions or unwinding
- pointer arithmetic and C ABI semantics as a language requirement
- automatic memory reclamation, destructors, ownership, and borrowing
- hexadecimal, octal, and binary integer literals
- Unicode character/string semantics beyond raw UTF-8 bytes
- stable ABI, dynamic linking, and cross-edition binary compatibility
- package registry or dependency-resolution semantics

## 9. Conformance requirements

A conforming implementation must reject invalid programs without emitting an
executable; silently translating an unsupported construct is a conformance
failure. It must pass `tests/run_semantics.sh`.

The 2026-06-29 native compiler rejects known representation-category type
mismatches, including aggregate-to-scalar assignments, and preserves outer
bindings across nested same-name declarations. Its type recovery remains
conservative for expressions whose scalar type cannot yet be inferred; an empty
inferred type is not by itself a rejection. Every mismatch represented in the
normative semantic suite is a hard failure and no expected conformance gaps are
carried by that suite.
