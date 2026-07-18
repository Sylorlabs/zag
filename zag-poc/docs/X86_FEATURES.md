# Linux x86-64 features

Status: deterministic baseline profile foundation, 2026-07-18.

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
| `native` | recognized but fails closed |
| runtime multiversioning | not implemented |
| i686 / ELF32 | not implemented |

Native resolution intentionally reports that self-hosted CPUID,
OSXSAVE/XGETBV discovery is unavailable and directs callers to `generic`.
Hardware support is never guessed from the compiler host. AVX-family features
must remain unavailable until both CPU and operating-system state support can be
proven and corresponding encoder, ABI, fallback, and execution tests pass.

The profile module emits a stable JSON report and a target-qualified cache key.
At this foundation stage the resolver is tested directly; complete `znc --cpu`
CLI integration and generic/native differential execution are not claimed here.
Linux x86-64 support must not be described as full x86-family support until the
separate i686 milestone passes.

