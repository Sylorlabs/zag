# Zag v2 ABI and linking (draft)

ABI is versioned separately from the language edition.  `extern "C"` selects
the target C ABI and requires C-compatible scalar/layout declarations; ordinary
Zag declarations keep a Zag ABI.  `export` and `import` control symbols and
visibility.  A C declaration with raw pointers, variadics, callbacks, errno,
or unverified ownership is unsafe.  ABI lowering must validate layout,
alignment, register classification, stack alignment, sret, and callback
trampolines with executable C↔Zag tests.

## Direction and compatibility boundary

Zag is a native compiler: Zag source is compiled directly to its own target
machine code.  C ABI support is **not** a Zag-to-C translation mode, a C
backend, or a host-C-toolchain dependency.  Its only purpose is incremental
adoption: a Zag program may replace a legacy C component while still calling
the platform and library interfaces that have not yet been replaced, and
existing C programs may call a deliberately exported Zag boundary.  A
relocation-bearing object, when implemented, is likewise a linker input/output
format for that bridge—not a request to re-express Zag source as C.

The default path remains direct static ELF without external tools.  Relocatable
objects, static archives, shared libraries, dynamic loading, and symbol lookup
are optional selected modes; no mode may silently introduce a host C compiler
or linker dependency.  ABI stability is claimed only for a named ABI version
after conformance tests pass.

## Declaration contract

Each import names its library/symbol and calling convention; each export names
its public symbol and visibility.  The Zag ABI is never silently treated as C.
Every FFI boundary declares integer widths, pointer mutability, nullability,
ownership, and aggregate representation.  `@repr(C)` does not make a language
enum, optional, slice, or error union C compatible unless that representation
is selected explicitly.

### Implemented x86-64 C-layout struct slice

Edition 2027 accepts `@repr(C) struct Name { ... }` and
`pub @repr(C) struct Name { ... }` on Linux x86-64. This is an explicit
representation choice; an ordinary `struct` keeps Zag's word-oriented layout.
The implemented fields are `bool`, exact-width 8/16/32/64-bit integers,
`isize`/`usize`, and raw pointers. Fields follow declaration order, System V
AMD64 natural alignment, inter-field padding, maximum-field struct alignment,
and final tail padding. `@sizeOf[T]()` and `*T` pointer stride use that exact
size. Field reads sign- or zero-extend from their declared width, and field
writes touch only that width.

`tests/run_repr_c_layout.sh` executes a live-shaped Xlib `XButtonEvent`: it
proves offsets 64 (`x`), 68 (`y`), 84 (`button`), total size/stride 96, reads
known foreign byte patterns, and places sentinels around narrow writes to catch
accidental eight-byte stores. It also proves qualified imports preserve the
representation and ordinary Zag structs do not change.

This slice is a pointer-only layout bridge, not general by-value aggregate or C
calling-convention support. Direct aggregate literals, locals, assignments,
arguments, and results reject before lowering; access through `*T` is the
implemented contract. Nested/generic structs, floats, enums, unions, slices,
optionals, error unions, packed/bitfield/explicit-alignment forms, i686,
AArch64, and non-Linux targets fail closed or remain unavailable. `@repr(C)`
alone does not add `@cabi` to a function.

Callbacks carry a calling convention and an unsafe lifetime contract.  The
callback and any user-data pointer must remain valid while the foreign side may
retain them.  `errno` is accessed through a target runtime operation with an
`FFI`/OS effect, not as a normal mutable global.  Variadics remain rejected
until each supported ABI has executable register/stack conformance coverage.

## Linking and loading contract

Static executable, relocatable object, shared object, and dynamic-loader modes
are distinct outputs.  Dynamic lookup is fallible; a library handle owns the
symbols obtained from it, and unloading while an obtained function pointer or
callback remains reachable is forbidden.  Generated helpers are hidden unless
explicitly exported.  Weak symbols are absent until their platform-specific
resolution semantics have tests.

## Current status

The implemented v2 ABI slice is an unsafe scalar/pointer plus `f64` `extern fn ... @cabi`
import through the native x86-64 dynamic ELF writer. The `f64` form permits up
to four `f64` arguments, each mapped to `XMM0` through `XMM3`; it is not an
object-export, `f32`, aggregate, or callback-float ABI. The tree also has a tightly bounded
callback form: a foreign parameter written as `fn(P...) R` may receive only a
direct, non-generic, captureless named Zag function with the exact same
scalar/pointer signature. The lowering passes that function's raw SysV code
address, not Zag's ordinary `{code, environment}` function value. Aliases,
closures/captures, `f32`, aggregates, variadics, callbacks returned from C,
and callback ownership/unload contracts remain rejected or unimplemented.
Any pointer argument given to such an import still requires an explicit
`@borrows`/`@borrows_mut`/`@consumes` lifetime contract; the qsort witness uses
`@borrows_mut` for its in-place buffer.
Multi-pointer imports may put the contract on each pointer parameter, for
example `left: @borrows *u8` and `right: @borrows *u8`. Authorization is exact
per argument: a contract on one parameter never blesses a neighboring owner.
These qualifiers change source ownership checking and semantic identities but
do not change register assignment or the C ABI. They describe call-duration
borrowing or exact ownership transfer only; retained-pointer-to-returned-handle
relationships remain unsupported and must not be labeled as borrows.
Executable evidence covers both a no-argument integer import, a six-register
mixed integer/pointer `mmap` import followed by pointer-return `munmap`, a
one/two/mixed-register `f64` libm import, and a
fixed seven-word scalar call whose seventh `mmap` offset is consumed from the
SysV stack, plus libc `qsort` calling a Zag comparator; this does not extend
the supported surface to aggregates, `f32`, general callbacks, variadics,
exports, or imports with ownership/lifetime contracts.

There is one deliberately narrow outbound v2 surface: an edition-2027
`pub fn` annotated `@cabi_export` with only scalar integer, `bool`, raw-pointer,
or `void` parameters and result can be compiled with native x86-64
`--emit-obj`. A self-contained object is relocation-free and contains `.text`,
`.symtab`, `.strtab`, and `.shstrtab`; the annotated function is a global
`STT_FUNC` symbol. The one supported import form is a direct call from an
`unsafe` Zag body to a declared scalar/pointer/`bool`/`void` `extern fn @cabi`.
That object adds `.rela.text`, an undefined global `STT_FUNC` symbol, and one
`R_X86_64_PLT32` relocation with addend `-4` for each call immediate. The
compiler still emits Zag machine code directly; a system linker resolves only
the named legacy boundary. `tests/run_x86_64_cabi_object.sh` inspects both
forms and links C callers/implementations that execute Zag exports and imports.
The accepted object has no data section, dynamic libraries, archive inputs,
GOT/TLS/data relocations, or any relocation form other than that direct call.

This is not a general export or static-linking ABI. Floats, aggregates,
variadics, callbacks, generics, shared objects, archives, general
relocation/static-object conformance, ABI unwind/visibility policy, and
ownership/lifetime contracts remain unimplemented. `--emit-static`,
`--emit-shared`, object aliases, PIE,
loader-path, rpath/soname, archive-selection, and common shared/library-output
spellings continue to fail before artifact creation rather than silently
producing an executable. The separate i686 object/archive path is not v2 C ABI
evidence and rejects v2 `@cabi` declarations.
Likewise, `--export`, `--export-dynamic`, and `--export-symbol` requests are
rejected: `pub fn` does not create a public C symbol in the current native
writer.

A complete native export/static-object ABI still requires relocation authority,
exact symbol-size policy, aggregates/sret, unwinding, visibility, and broad C
conformance tests. No stable general v2 export or static C ABI is claimed.
