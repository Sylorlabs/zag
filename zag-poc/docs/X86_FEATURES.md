# Linux x86-64 features

Status: implemented target-permission foundation, 2026-07-18.

The native target is Linux ELF64 x86-64. The implemented profile resolver
defines `generic`, `x86-64`, and `x86-64-v1` as aliases for one canonical
`x86-64-v1` cache identity. That baseline advertises SSE2 only. Existing
scalar integer and scalar SSE2 floating-point encoding is the supported
foundation; this table is about target selection, not every instruction present
in the encoder.

| Feature/profile | Current status |
| --- | --- |
| `generic` | implemented; canonicalizes to `x86-64-v1` |
| `x86-64`, `x86-64-v1` | implemented aliases |
| SSE2 | advertised by the generic profile |
| SSE3, SSSE3, SSE4.1, SSE4.2 | not advertised |
| POPCNT | generic fallback; native-gated opcode; cached dispatch with `--cpu=runtime` |
| AVX, AVX2, FMA, BMI1, BMI2, AVX-512 | not advertised |
| `native` | CPUID/OS-gated SSE2 plus POPCNT when present and tested |
| runtime multiversioning | `popcount(i64)` and BMI1 `andn(i64,i64)` intrinsics |
| i686 / ELF32 | executable/relocatable i32 and SysV x87 f32/f64 subset |

Native resolution executes CPUID directly. AVX usability requires the CPU AVX
bit, OSXSAVE, and XGETBV confirmation that XCR0 enables both XMM and YMM state;
AVX2 additionally requires its leaf-7 bit. Deterministic negative tests prove
that hardware AVX alone and OSXSAVE without YMM state remain disabled. The
compiler then intersects detected features with its independently tested
encoder permission set. That permitted set is
currently SSE2 plus separately gated POPCNT lowering. Detecting AVX, AVX2, FMA,
BMI or AVX-512 never enables their emission.

The profile module emits a stable JSON report and a target-qualified cache key.
`znc --cpu generic` and `znc --cpu native` are CLI-integrated. The target-policy
gate executes integer and floating ABI paths under each and requires
equivalent observable output. `popcount(i64)` uses a baseline software sequence
for `generic`, a POPCNT opcode only when `native` detects and permits it, and a
cached CPUID-selected generic/POPCNT path for `runtime`. This narrow dispatch is
not general function multiversioning. `andn(a,b)` has the exact generic fallback
`(~a) & b`. Native emission requires CPUID leaf 7 EBX bit 3. Runtime mode caches
that decision independently from POPCNT and never executes the VEX-encoded ANDN
path when BMI1 is absent. BMI1 does not require extended OS register state;
AVX-family dispatch still requires OSXSAVE and XCR0 XMM/YMM qualification.
Linux x86-64 support must not be described as full x86-family support until the
separate i686 milestone passes.

`--target i686`, `--target x86`, and `--target linux-i686` select an isolated
ELF32 milestone backend. It accepts a non-generic `i32 main` with initialized
`i32` locals and parameters, assignment, integer constants, arithmetic,
comparisons, structured branches/loops, non-generic `i32` calls, and scalar
`f32`/`f64` locals, arithmetic, comparison, width-correct stack arguments, and
ST(0) returns. These nodes
lower through a validated integer IR into i386 frames with caller-cleaned stack
arguments and EAX returns; Linux startup exits through `int 0x80`. Unsupported
types and AST nodes reject before output. This
is executable i386-backend proof, not general i686 language support; 64-bit
integer signatures remain fail-closed.

The milestone defines `usize` and supported pointers as 32-bit ABI words.
Address-of is restricted to initialized stack locals; dereference and indirect
store support `*i32` and `*usize`. The subset also covers basic local scalar
structs, signed i32 output, scalar `!i32`, ELF32 symbols/debug-line metadata,
relocatable objects, deterministic archives, and pure-Zag linking of the
compiler-owned object/archive contract. It does not imply aggregate calls or
returns, heap, slices, general pointer arithmetic, foreign objects, or complete
i386 ABI/runtime support.
