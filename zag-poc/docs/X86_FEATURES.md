# Linux x86-64 features

Status: implemented target-permission foundation, 2026-07-18.

The native target is Linux ELF64 x86-64. The implemented profile resolver
defines `generic`, `x86-64`, and `x86-64-v1` as aliases for one canonical
`x86-64-v1` cache identity. Its advertised feature set is SSE2 only. Existing
scalar integer and scalar SSE2 floating-point encoding is the supported
foundation; this table is about target selection, not every instruction present
in the encoder.

| Feature/profile | Current status |
| --- | --- |
| `generic` | implemented; canonicalizes to `x86-64-v1` |
| `x86-64`, `x86-64-v1` | implemented aliases |
| SSE2 | advertised by the generic profile |
| SSE3, SSSE3, SSE4.1, SSE4.2, POPCNT | not advertised |
| AVX, AVX2, FMA, BMI1, BMI2, AVX-512 | not advertised |
| `native` | resolved with raw CPUID and OSXSAVE/XGETBV gating; permitted set is currently SSE2 |
| runtime multiversioning | not implemented |
| i686 / ELF32 | minimal literal-return milestone only |

Native resolution executes CPUID directly. AVX usability requires the CPU AVX
bit, OSXSAVE, and XGETBV confirmation that XCR0 enables both XMM and YMM state;
AVX2 additionally requires its leaf-7 bit. Deterministic negative tests prove
that hardware AVX alone and OSXSAVE without YMM state remain disabled. The
compiler then intersects detected features with its independently tested
encoder permission set. That permitted set is
currently SSE2 only; detecting AVX, AVX2, FMA, BMI or AVX-512 never enables
their emission.

The profile module emits a stable JSON report and a target-qualified cache key.
`znc --cpu generic` and `znc --cpu native` are CLI-integrated. The target-policy
gate executes integer and floating ABI paths under each and requires
byte-identical output while both profiles permit the same SSE2 feature set.
Linux x86-64 support must not be described as full x86-family support until the
separate i686 milestone passes.

`--target i686`, `--target x86`, and `--target linux-i686` select an isolated
ELF32 milestone backend. It accepts a non-generic `i32 main` with initialized
`i32` locals and parameters, assignment, integer constants, arithmetic,
comparisons, structured branches/loops, and non-generic `i32` calls. These nodes
lower through a validated integer IR into i386 frames with caller-cleaned stack
arguments and EAX returns; Linux startup exits through `int 0x80`. Unsupported
types and AST nodes reject before output. This
is executable integer-backend proof, not general i686 language support.

The milestone defines `usize` and supported pointers as 32-bit ABI words.
Address-of is restricted to initialized stack locals; dereference and indirect
store support `*i32` and `*usize`. This does not yet imply aggregate, heap, slice,
or general pointer-arithmetic support.
