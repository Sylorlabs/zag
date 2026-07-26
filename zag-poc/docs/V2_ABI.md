# Zag v2 ABI and linking (draft)

ABI is versioned separately from the language edition.  `extern "C"` selects
the target C ABI and requires C-compatible scalar/layout declarations; ordinary
Zag declarations keep a Zag ABI.  `export` and `import` control symbols and
visibility.  A C declaration with raw pointers, variadics, callbacks, errno,
or unverified ownership is unsafe.  ABI lowering must validate layout,
alignment, register classification, stack alignment, sret, and callback
trampolines with executable C↔Zag tests.

The default path remains direct static ELF without external tools.  Relocatable
objects, static archives, shared libraries, dynamic loading, and symbol lookup
are optional selected modes; no mode may silently introduce a host C compiler
or linker dependency.  ABI stability is claimed only for a named ABI version
after conformance tests pass.

## Declaration contract

Each import names its library/symbol and calling convention; each export names
its public symbol and visibility.  The Zag ABI is never silently treated as C.
Every FFI boundary declares integer widths, pointer mutability, nullability,
ownership, and aggregate representation.  `repr(C)` does not make a language
enum, optional, slice, or error union C compatible unless that representation
is selected explicitly.

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

The only implemented v2 ABI slice is an unsafe, outbound scalar/pointer
`extern fn ... @cabi` import through the native x86-64 dynamic ELF writer.
Executable evidence covers both a no-argument integer import and a six-register
mixed integer/pointer `mmap` import followed by pointer-return `munmap`; this
does not extend the supported surface to aggregates, floats, callbacks,
variadics, exports, or imports with ownership/lifetime contracts.
It has no v2 export surface: the native x86-64 writer emits `ET_EXEC` with
program headers only, not an `ET_REL` object, section table, `.symtab`, or
public-symbol visibility. Accordingly, native `--emit-obj` and
`--emit-static` fail before artifact creation rather than silently producing an
executable. The separate i686 object/archive path is not v2 C ABI evidence and
rejects v2 `@cabi` declarations.

A native export/static-object increment requires codegen to return exact public
function offsets and sizes, plus a new x86-64 `ET_REL` writer with section,
symbol, and relocation authority. It must then establish a separately tested
calling convention (including aggregates, sret, and unwind/visibility policy).
Until that work exists, no stable v2 export or static C ABI is claimed.
