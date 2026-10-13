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

### Implemented native 64-bit C-layout struct slice

Edition 2027 accepts `@repr(C) struct Name { ... }` and
`pub @repr(C) struct Name { ... }` on Linux x86-64 and Apple Silicon macOS.
This is an explicit representation choice; an ordinary `struct` keeps Zag's
word-oriented layout. The implemented fields are `bool`, exact-width
8/16/32/64-bit integers, `isize`/`usize`, and raw pointers. Fields follow
declaration order and the target C ABI's natural scalar alignment, inter-field
padding, maximum-field struct alignment, and final tail padding. `@sizeOf[T]()`
and `*T` pointer stride use that exact size. Field reads sign- or zero-extend
from their declared width, and field writes touch only that width.

`tests/run_repr_c_layout.sh` executes a live-shaped Xlib `XButtonEvent`: it
proves offsets 64 (`x`), 68 (`y`), 84 (`button`), total size/stride 96, reads
known foreign byte patterns, and places sentinels around narrow writes to catch
accidental eight-byte stores. The same corpus executes as native Linux x86-64
and signed ARM64 Mach-O output; it also proves qualified imports preserve the
representation and ordinary Zag structs do not change.

This slice is a pointer-only layout bridge, not general by-value aggregate or C
calling-convention support. Direct aggregate literals, locals, assignments,
arguments, and results reject before lowering; access through `*T` is the
implemented contract. Nested/generic structs, floats, enums, unions, slices,
optionals, error unions, packed/bitfield/explicit-alignment forms, i686,
Linux AArch64, and targets other than the two qualified native paths fail closed
or remain unavailable. `@repr(C)` alone does not add `@cabi` to a function.

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

The implemented v2 ABI slice includes unsafe scalar/pointer plus `f64`
`extern fn ... @cabi` imports through the native x86-64 dynamic ELF writer and
the bounded Apple-Silicon Mach-O object/custom-link paths. Apple-Silicon Mach-O
additionally admits bounded `f32` imports and `f32`/`f64` `pub @cabi_export`
definitions. The x86-64 proven slice remains capped at four `f64` arguments in
`XMM0` through `XMM3`. Darwin AArch64 maps fixed `f32`/`f64` arguments through
the independent `V0` through `V7` bank (`S`/`D` views) beside integer/pointer
arguments in `X0` through `X7`, then uses Darwin's naturally packed stack
argument layout. Native C witnesses exercise ten `f32` and ten `f64` parameters
in both directions. The closed macOS executable writer exposes only
its audited libSystem names; custom Mach-O links resolve the declared symbol
from the selected dylib. Darwin FP exports receive parameters from that
independent register bank and return `f32` in `S0` or `f64` in `D0`; Zag keeps
both float types internally as f64 bits, so the f32 boundary performs explicit
single/double conversion. Apple Silicon also has two bounded aggregate transports.
The recursive 64-bit-leaf slice accepts
ordinary non-generic named structs containing only naturally aligned `i64`, `u64`,
or raw-pointer leaves, optionally nested through ordinary non-generic structs
within a bounded recursive classifier. One- and two-word values use Darwin's INTEGER aggregate
class: consecutive `X` registers when the complete value fits, otherwise the
whole aggregate on the stack, with `X0`/`X1` results. Larger values use a pointer
to a private caller copy and indirect results in `X8`. Native object and
dylib/custom-link witnesses execute both directions and force the small-value
stack-overflow path, including flat/nested small and large values.
The second slice accepts flat ordinary non-generic structs made only from
naturally aligned integer/`bool`/raw-pointer leaves when their Darwin C layout
is at most 16 bytes. Those values use the same small INTEGER-class complete-fit
register/stack rule, but the compiler explicitly packs/unpacks the C byte layout
because ordinary Zag keeps one eight-byte internal slot per field. Native object
and dylib/custom-link witnesses cover signed/unsigned subword fields, padding,
`bool`, raw pointers, one/two-register arguments/results, and whole-aggregate
stack spill. Nested narrow/mixed-width values, mixed-layout values larger than
16 bytes, HFA/HVA structs, unions, by-value `@repr(C)`, and aggregate callbacks
remain unsupported, so this is not a general aggregate ABI.
Apple Silicon shares the
tightly bounded direct callback form below: the callback crosses as one raw
function address rather than Zag's ordinary `{code, environment}` function value.
A foreign parameter written as `fn(P...) R` may receive only a direct, non-generic,
captureless named Zag function with the exact same supported signature. Scalar/pointer
callbacks may target an ordinary function. If any callback parameter or result is
`f32`/`f64`, the direct target must be `pub @cabi_export` so its entry and return use
the proven Darwin C FP adapter. Mixed `f32`/integer/`f64` callback entry, scalar FP
callback returns, and ten-`f32` callback arguments spanning V registers plus stack
are executed against C in the native object/dylib gates. Aliases,
closures/captures, aggregate callback signatures, variadics, callbacks returned from C, and callback
ownership/unload contracts remain rejected or unimplemented.
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
Linux x86-64 executable evidence covers a no-argument integer import, a six-register
mixed integer/pointer `mmap` import followed by pointer-return `munmap`, a
one/two/mixed-register `f64` libm import, and a
fixed seven-word scalar call whose seventh `mmap` offset is consumed from the
SysV stack, plus libc `qsort` calling a Zag comparator. Apple-Silicon evidence
covers fixed `f32`/`f64` imports in Mach-O objects linked by Apple's linker, Zag-owned
custom dylib linking, and the closed libSystem `cos`/`pow`/`ldexp` plus
`cosf`/`powf`/`ldexpf` paths, with both `ldexp(f64, i32)` and
`ldexpf(f32, i32)` proving independent FP/GPR assignment. The same Apple-Silicon
evidence includes mixed FP/X-register `f32`/`f64` exports called from C, a direct
Zag callback through libSystem `qsort`, bounded explicit-export f32/f64 callbacks,
and flat/nested small register/stack plus large indirect 64-bit-leaf struct imports/exports,
plus flat small integer/bool/raw-pointer struct byte-layout adaptation,
through object/custom-library interoperability. This does not extend the supported
surface to nested narrow/mixed-width aggregates, mixed-layout aggregates larger
than 16 bytes, HFA/HVA aggregates, unions, by-value `@repr(C)`, aggregate callbacks,
callback aliases/captures, callbacks returned from C, variadics,
or imports with ownership/lifetime contracts.

There is one deliberately narrow outbound v2 surface: an edition-2027
`pub fn` annotated `@cabi_export` with scalar integer, `bool`, raw-pointer, or
`void` parameters/result can be compiled with native x86-64 `--emit-obj`, Linux
`--target arm64 --emit-obj`, or Apple-Silicon `--target macos-arm64 --emit-obj`.
The Apple-Silicon form additionally permits fixed `f32`/`f64` parameters through
the Darwin FP register/stack convention and an `f32` or `f64` result, plus the
two bounded ordinary struct subsets above for parameters/results; other targets
still reject floating-point exports. These objects are callable collections and
do not require or emit a process `main`/`_start`.

The following minimal-object description applies specifically to the Linux
x86-64/AArch64 ET_REL slice. A self-contained Linux object is relocation-free
and contains `.text`, `.symtab`, `.strtab`, and `.shstrtab`; the annotated
function is a global `STT_FUNC` symbol. Its supported import form is a direct
call from an `unsafe` Zag body to a declared scalar/pointer/`bool`/`void`
`extern fn @cabi`. That object adds `.rela.text`, an undefined global
`STT_FUNC` symbol, and one target call relocation for each immediate:
`R_X86_64_PLT32` with addend `-4`, or `R_AARCH64_CALL26` with addend `0`.
The compiler still emits Zag machine code directly; a system linker resolves
only the named legacy boundary.
`tests/run_x86_64_cabi_object.sh` and `tests/run_arm64_cabi_object.sh` inspect
both forms and link C callers/implementations that execute Zag exports and
imports on their native architectures. The accepted object has no data
section, dynamic libraries, archive inputs, GOT/TLS/data relocations, or any
relocation form other than that target's direct call. ARM64 rejects both
literal bytes and allocator-runtime data-address references before creating an
artifact. For this Linux minimal-object slice, floating-point exports,
aggregates beyond the separately proven x86-64 MEMORY-class import, variadics,
floating callbacks, general shared-object/archive composition, and broader
relocation/static-object conformance remain outside the contract. The separate
i686 object/archive path is not v2 C ABI evidence and rejects v2 `@cabi`
declarations. Apple-Silicon Mach-O object/archive/dylib/custom-link capabilities
are the distinct bounded contract described above and in
`docs/MACOS_NATIVE_PARITY.md`.
Likewise, `--export`, `--export-dynamic`, and `--export-symbol` requests are
rejected: `pub fn` does not create a public C symbol in the current native
writer.

A complete native export/static-object ABI still requires relocation authority,
exact symbol-size policy, aggregates/sret, unwinding, visibility, and broad C
conformance tests. No stable general v2 export or static C ABI is claimed.
